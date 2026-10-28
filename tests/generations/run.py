"""Boot A, boot B, roll back to A, and recover A through the boot console."""
import argparse
import functools
import json
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guest import clone_state


def closure(path):
    return set(subprocess.check_output(['nix-store', '-qR', path], text=True).splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--launcher', required=True, type=Path)
    parser.add_argument('--base-system', required=True)
    parser.add_argument('--system-a', required=True)
    parser.add_argument('--system-b', required=True)
    fixtures = parser.add_mutually_exclusive_group()
    fixtures.add_argument('--live-fixtures', type=Path, help='fixture bundle with invalid configurations and activation failures')
    fixtures.add_argument('--dns-fixtures', type=Path, help='DNS configuration and failure fixtures')
    fixtures.add_argument('--logging-fixtures', type=Path, help='Logging configuration and failure fixtures')
    fixtures.add_argument('--doas-fixtures', type=Path, help='Privilege management and failure fixtures')
    fixtures.add_argument('--mail-fixtures', type=Path, help='Local mail and failure fixtures')
    fixtures.add_argument('--maintenance-fixtures', type=Path, help='OpenBSD maintenance configurations')
    parser.add_argument('--live-only', action='store_true', help='test only installation and live updates')
    parser.add_argument('--timeout', type=int, default=600, help='seconds allowed for each guest operation')
    parser.add_argument('--personal-system', type=Path, help='also boot the native configuration template')
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2],
                        help='project source for the personal configuration test')
    parser.add_argument('--recovery-state', type=Path, help='rerun only console recovery on a preserved test disk')
    parser.add_argument('--keep', action='store_true')
    parser.add_argument('--vm-state', type=Path, help='copy a prepared VM as the initial test state')
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    if args.vm_state and args.recovery_state:
        parser.error('--vm-state and --recovery-state cannot be combined')
    if args.live_only and (not (args.live_fixtures or args.dns_fixtures or args.logging_fixtures or args.doas_fixtures or args.mail_fixtures or args.maintenance_fixtures) or args.personal_system or args.recovery_state):
        parser.error('--live-only requires service fixtures and excludes personal/recovery tests')
    args.launcher = args.launcher.resolve(strict=True)
    for name in ('base_system', 'system_a', 'system_b'):
        setattr(args, name, str(Path(getattr(args, name)).resolve(strict=True)))
    if args.live_fixtures:
        args.live_fixtures = args.live_fixtures.resolve(strict=True)
    if args.dns_fixtures:
        args.dns_fixtures = args.dns_fixtures.resolve(strict=True)
    if args.logging_fixtures:
        args.logging_fixtures = args.logging_fixtures.resolve(strict=True)
    if args.doas_fixtures:
        args.doas_fixtures = args.doas_fixtures.resolve(strict=True)
    if args.mail_fixtures:
        args.mail_fixtures = args.mail_fixtures.resolve(strict=True)
    if args.maintenance_fixtures:
        args.maintenance_fixtures = args.maintenance_fixtures.resolve(strict=True)
    if args.personal_system:
        args.personal_system = args.personal_system.resolve(strict=True)
    if args.recovery_state:
        args.recovery_state = args.recovery_state.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix='nixopenbsd-generations.'))
    print(f'Test files: {work}', flush=True)
    if args.vm_state:
        clone_state(args.vm_state, work / 'state')
    public = work / 'public'
    token = secrets.token_hex(24)
    payload = public / token
    payload.mkdir(parents=True)
    needed = closure(args.system_a) | closure(args.system_b)
    if args.live_fixtures:
        needed |= closure(str(args.live_fixtures))
    if args.dns_fixtures:
        needed |= closure(str(args.dns_fixtures))
    if args.logging_fixtures:
        needed |= closure(str(args.logging_fixtures))
    if args.doas_fixtures:
        needed |= closure(str(args.doas_fixtures))
    if args.mail_fixtures:
        needed |= closure(str(args.mail_fixtures))
    if args.maintenance_fixtures:
        needed |= closure(str(args.maintenance_fixtures))
    if args.personal_system:
        needed |= closure(str(args.personal_system))
        source = 'path:' + str(args.source.resolve(strict=True))
        source_roots = json.loads(subprocess.check_output([
            'nix', 'eval', '--impure', '--json', '--expr',
            f'let f = builtins.getFlake {json.dumps(source)}; in '
            '[ f.outPath f.inputs.nixbsd.outPath ] ++ '
            'builtins.map (input: input.outPath) (builtins.attrValues f.inputs.nixbsd.inputs)'
        ], text=True))
        for root in source_roots:
            needed |= closure(root)
    paths = sorted(needed - closure(args.base_system))
    with (payload / 'systems.nar').open('wb') as stream:
        subprocess.run(['nix-store', '--export', *paths], stdout=stream, check=True)

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(public)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://10.0.2.2:{server.server_port}/{token}'
    # Guest networking can still settle after login; retry fixture downloads.
    fetch = "curl --noproxy '*' --retry 10 --retry-all-errors --retry-delay 1 --connect-timeout 5 -fsS"
    a, b = map(shlex.quote, (args.system_a, args.system_b))
    (payload / 'setup.sh').write_text(f'''set -eu
{fetch} {url}/systems.nar -o /tmp/generation-systems.nar
nix-store --import < /tmp/generation-systems.nar
rm /tmp/generation-systems.nar
# Reused disks may contain data from an earlier generation test.
/etc/rc.d/cron stop
rm -rf /var/lib/cron-test /var/lib/directory-test
{('rm -f /var/log/logging-* /root/logging-persistence' if args.logging_fixtures else '')}
{('rm -f /var/mail/bestie /var/mail/mail-test /root/mail-persistence /root/mail-queued' if args.mail_fixtures else '')}
{('rm -rf /var/lib/maintenance-test; rm -f /root/maintenance-persistence /var/log/daily.out* /var/log/weekly.out* /var/log/monthly.out* /var/log/security.out*' if args.maintenance_fixtures else '')}
{a}/bin/switch-to-configuration boot
test "$(readlink -f /run/current-system)" = {shlex.quote(args.base_system)}
touch /root/generation-persistence
''')
    phases = {
        'install': f"{fetch} {url}/setup.sh -o /tmp/install.sh && bash /tmp/install.sh",
        'a': f'''test "$(readlink -f /run/current-system)" = {a}
openbsd-rebuild boot --store-path {b}
test "$(readlink -f /run/current-system)" = {a}''',
        'b': f'''test "$(readlink -f /run/current-system)" = {b}
openbsd-rebuild boot --rollback
test "$(readlink -f /nix/var/nix/profiles/system)" = {a}''',
        'rollback': f'''test "$(readlink -f /run/current-system)" = {a}
test -f /root/generation-persistence
nix-store --query --roots {a} | grep /nix/var/nix/profiles/
nix-store --query --roots {b} | grep /nix/var/nix/profiles/
nix-store --gc
nix-store --check-validity {a} {b}
openbsd-rebuild boot --store-path {b}''',
        'recovery': f'''test "$(readlink -f /run/current-system)" = {a}
test "$(readlink -f /run/booted-system)" = {a}
test "$(readlink -f /nix/var/nix/profiles/system)" = {b}
openbsd-rebuild boot --rollback
test "$(readlink -f /nix/var/nix/profiles/system)" = {a}''',
    }
    if args.live_fixtures:
        fixtures = shlex.quote(str(args.live_fixtures))
        shutil.copyfile(Path(__file__).with_name('cron-check.sh'), payload / 'cron-check.sh')
        shutil.copyfile(Path(__file__).with_name('ntpd-check.sh'), payload / 'ntpd-check.sh')
        ntpd_check = f'''{fetch} {url}/ntpd-check.sh -o /tmp/ntpd-check.sh
source /tmp/ntpd-check.sh'''
        metadata = json.loads((Path(args.system_a) / 'openbsd-system.json').read_text())
        with_cronctl = 'cronctl check' in metadata['services']['cron']['check']
        cron_check = (f'''{fetch} {url}/cron-check.sh -o /tmp/cron-check.sh
bash /tmp/cron-check.sh''' if with_cronctl else
                      'if command -v cronctl; then echo "Unexpected cronctl"; exit 1; fi')
        reload_failure = f'''touch /run/cron-fail-reload
if {b}/bin/switch-to-configuration test; then echo 'Unexpected reload success'; exit 1; fi
test "$(readlink -f /run/current-system)" = {a}
test "$(readlink -f /nix/var/nix/profiles/system)" = {a}
test "$(cat /boot/nixos/default.conf)" = "$default"
test "$(cron_process)" = "$cron_pid"
test "$(cat /var/lib/cron-test/boots)" = "$cron_boots"
''' if with_cronctl else ''
        live_probe = f'''test "$(readlink -f /run/current-system)" = {a}
set -E
trap 'status=$?; trap - ERR; tail -n 20 /var/cron/log >&2 || true; ls -ld /var/lib/cron-test >&2 || true; exit "$status"' ERR
rebuild={a}/sw/bin/openbsd-rebuild
ssh_process() {{ ps -ax -o pid=,comm= | awk '$2 == "sshd" {{ print $1 }}'; }}
ssh_pid=$(ssh_process)
test -n "$ssh_pid"
{ntpd_check}
ntpd_check 127.0.0.2
ntpd_pid=$(ntpd_process)
cron_process() {{ ps -ax -o pid=,ppid=,comm= | awk '$2 == 1 && $3 == "cron" {{ print $1 }}'; }}
cron_pid=$(cron_process)
test -n "$cron_pid"
cron_boots=$(cat /var/lib/cron-test/boots)
test "$cron_boots" = boot
test ! -L /etc/crontab
test "$(stat -c %a /etc/crontab)" = 600
{cron_check}
cron_wait() {{
    # Automatic reload happens after scheduling, so the first job can need another tick.
    deadline=$((SECONDS + {90 if with_cronctl else 150}))
    while ! sqlite3 -readonly /var/lib/cron-test/jobs.db "select generation from runs where generation = '$1';" 2>/dev/null | grep -q "$1"; do
        test "$SECONDS" -lt "$deadline" || {{ echo "Cron job $1 did not run"; return 1; }}
        sleep 1
    done
    test "$(cron_process)" = "$cron_pid"
    test "$(cat /var/lib/cron-test/boots)" = "$cron_boots"
    test "$(sqlite3 /var/lib/cron-test/jobs.db 'select distinct uid from runs;')" = "$(id -u daemon)"
}}
cron_wait a
for service in nix_daemon sshd dhcpcd httpd relayd cron syslogd ntpd sensorsd snmpd resolvd; do
    /etc/rc.d/$service check
done
directory=/var/lib/directory-test
daemon_owner=$(id -u daemon):$(id -g daemon)
root_owner=$(id -u root):$(awk -F: '$1 == "wheel" {{ print $3 }}' /etc/group)
directory_check() {{
    test "$(stat -c '%a:%u:%g' "$directory")" = "$1"
    test "$(cat "$directory/state")" = preserved
    test "$(stat -c '%a:%u:%g' "$directory/state")" = "600:$daemon_owner"
}}
printf 'preserved\\n' > "$directory/state"
chown daemon:daemon "$directory/state"
chmod 0600 "$directory/state"
printf 'blocker\\n' > "$directory/blocker"
directory_check "700:$daemon_owner"
# Reapply the current generation to repair drift without touching its contents.
chmod 0777 "$directory"
chown root:wheel "$directory"
{a}/bin/switch-to-configuration test
test "$(ntpd_process)" = "$ntpd_pid"
directory_check "700:$daemon_owner"
default=$(cat /boot/nixos/default.conf)
{b}/bin/switch-to-configuration dry-activate
test "$(readlink -f /run/current-system)" = {a}
directory_check "700:$daemon_owner"
test ! -e "$directory/new"
test "$(ntpd_process)" = "$ntpd_pid"
for failure in invalid invalid-ntpd {'invalid-cron' if with_cronctl else ''} failed-start failed-ntpd-start failed-activation failed-directories; do
    ntpd_pid=$(ntpd_process)
    if $rebuild switch --store-path {fixtures}/$failure; then echo "Unexpected success: $failure"; exit 1; fi
    test "$(readlink -f /run/current-system)" = {a}
    test "$(readlink -f /nix/var/nix/profiles/system)" = {a}
    test "$(cat /boot/nixos/default.conf)" = "$default"
    directory_check "700:$daemon_owner"
    test "$(cat "$directory/blocker")" = blocker
    /etc/rc.d/httpd check
    curl -fsS http://127.0.0.1:8080/ | grep NixBSD
    ntpd_check 127.0.0.2
    case "$failure" in
        invalid*) test "$(ntpd_process)" = "$ntpd_pid" ;;
        failed-ntpd-start) test "$(ntpd_process)" != "$ntpd_pid" ;;
    esac
done
{reload_failure}
ntpd_pid=$(ntpd_process)
{b}/bin/switch-to-configuration test
ntpd_check 127.0.0.3
test "$(ntpd_process)" != "$ntpd_pid"
ntpd_pid=$(ntpd_process)
{b}/bin/switch-to-configuration test
test "$(ntpd_process)" = "$ntpd_pid"
directory_check "750:$root_owner"
test -d "$directory/new"
test "$(readlink -f /run/current-system)" = {b}
test "$(readlink -f /nix/var/nix/profiles/system)" = {a}
test "$(cat /boot/nixos/default.conf)" = "$default"
/etc/rc.d/generation_probe check
curl -fsS http://127.0.0.1:8080/ | grep 'generation B'
test "$(/run/current-system/sw/bin/hello)" = 'Hello, world!'
cron_wait b
/etc/rc.d/ntpd stop
ntpd_stopped
$rebuild test --store-path {a}
ntpd_stopped
grep -Fx 'server 127.0.0.2' /etc/ntpd.conf
/etc/rc.d/ntpd start
ntpd_check 127.0.0.2
directory_check "700:$daemon_owner"
test -d "$directory/new"
if {b}/etc/rc.d/generation_probe check; then echo 'Removed daemon still running'; exit 1; fi
{b}/bin/switch-to-configuration switch
test "$(readlink -f /run/current-system)" = {b}
test "$(readlink -f /nix/var/nix/profiles/system)" = {b}
$rebuild switch --rollback
ntpd_check 127.0.0.2
directory_check "700:$daemon_owner"
test "$(readlink -f /run/current-system)" = {a}
test "$(readlink -f /nix/var/nix/profiles/system)" = {a}
test "$(ssh_process)" = "$ssh_pid"
sqlite3 /var/lib/cron-test/jobs.db "delete from runs where generation = 'a';"
cron_wait a
test "$(sqlite3 /var/lib/cron-test/jobs.db \"select count(*) from runs where generation = 'b';\")" -gt 0
for root in /nix/var/nix/gcroots/openbsd-system.*; do test ! -d "$root"; done
echo LIVE_SWITCH_PASS
'''
        phases['a'] = live_probe + phases['a']
        for phase, mode, user, group in [('b', '750', 'root', 'wheel'),
                                        ('rollback', '700', 'daemon', 'daemon'),
                                        ('recovery', '700', 'daemon', 'daemon')]:
            phases[phase] += f'''
{ntpd_check}
ntpd_check {'127.0.0.3' if phase == 'b' else '127.0.0.2'}
owner=$(id -u {user}):$(awk -F: '$1 == "{group}" {{ print $3 }}' /etc/group)
test "$(stat -c '%a:%u:%g' /var/lib/directory-test)" = "{mode}:$owner"
test "$(cat /var/lib/directory-test/state)" = preserved
test "$(stat -c '%a:%u:%g' /var/lib/directory-test/state)" = "600:$(id -u daemon):$(id -g daemon)"
'''
        if args.live_only:
            phases = {'install': phases['install'], 'a': live_probe}
    if args.dns_fixtures:
        shutil.copyfile(Path(__file__).with_name('dns-check.py'), payload / 'dns-check.py')

        def dns_probe(phase):
            fixtures = ' ' + shlex.quote(str(args.dns_fixtures)) if phase == 'live' else ''
            return f'''{fetch} {url}/dns-check.py -o /tmp/dns-check.py
python3 -B /tmp/dns-check.py {phase} {a} {b}{fixtures}
'''

        phases['a'] = dns_probe('live') + phases['a']
        for phase in ['b', 'rollback', 'recovery']:
            phases[phase] += '\n' + dns_probe('b' if phase == 'b' else 'a')
        if args.live_only:
            phases = {'install': phases['install'], 'a': dns_probe('live')}
    if args.logging_fixtures:
        shutil.copyfile(Path(__file__).with_name('logging-check.py'), payload / 'logging-check.py')

        def logging_probe(phase):
            fixtures = ' ' + shlex.quote(str(args.logging_fixtures)) if phase == 'live' else ''
            return f'''{fetch} {url}/logging-check.py -o /tmp/logging-check.py
python3 -B /tmp/logging-check.py {phase} {a} {b}{fixtures}
'''

        phases['a'] = logging_probe('live') + phases['a']
        for phase in ['b', 'rollback', 'recovery']:
            phases[phase] += '\n' + logging_probe('b' if phase == 'b' else 'a')
        if args.live_only:
            phases = {'install': phases['install'], 'a': logging_probe('live')}
    if args.doas_fixtures:
        shutil.copyfile(Path(__file__).with_name('doas-check.py'), payload / 'doas-check.py')
        # GC can remove the fixture bundle before the rollback/recovery probes.
        doas_tools = shlex.quote(str((args.doas_fixtures / 'coreutils').resolve() / 'bin'))

        def doas_probe(phase):
            fixtures = ' ' + shlex.quote(str(args.doas_fixtures)) if phase == 'live' else ''
            return f'''{fetch} {url}/doas-check.py -o /tmp/doas-check.py
python3 -B /tmp/doas-check.py {phase} {a} {b} {doas_tools}{fixtures}
'''

        phases['a'] = doas_probe('live') + phases['a']
        for phase in ['b', 'rollback', 'recovery']:
            phases[phase] += '\n' + doas_probe('b' if phase == 'b' else 'a')
        if args.live_only:
            phases = {'install': phases['install'], 'a': doas_probe('live')}
    if args.mail_fixtures:
        shutil.copyfile(Path(__file__).with_name('mail-check.py'), payload / 'mail-check.py')

        def mail_probe(phase):
            fixtures = ' ' + shlex.quote(str(args.mail_fixtures)) if phase == 'live' else ''
            return f'''{fetch} {url}/mail-check.py -o /tmp/mail-check.py
python3 -B /tmp/mail-check.py {phase} {a} {b}{fixtures}
'''

        phases['a'] = mail_probe('live') + phases['a']
        for phase in ['b', 'rollback', 'recovery']:
            phases[phase] += '\n' + mail_probe('b' if phase == 'b' else 'a')
        if args.live_only:
            phases = {'install': phases['install'], 'a': mail_probe('live')}
    if args.maintenance_fixtures:
        shutil.copyfile(Path(__file__).with_name('maintenance-check.py'), payload / 'maintenance-check.py')

        def maintenance_probe(phase):
            fixtures = ' ' + shlex.quote(str(args.maintenance_fixtures)) if phase == 'live' else ''
            return f'''{fetch} {url}/maintenance-check.py -o /tmp/maintenance-check.py
python3 -B /tmp/maintenance-check.py {phase} {a} {b}{fixtures}
'''

        phases['a'] = maintenance_probe('live') + phases['a']
        for phase in ['b', 'rollback', 'recovery']:
            phases[phase] += '\n' + maintenance_probe('b' if phase == 'b' else 'a')
        if args.live_only:
            phases = {'install': phases['install'], 'a': maintenance_probe('live')}
    if args.recovery_state:
        phases = {'recovery': phases['recovery']}
    if args.personal_system:
        personal = shlex.quote(str(args.personal_system))
        # Retain the template while the rollback phase exercises garbage collection.
        with (payload / 'setup.sh').open('a') as stream:
            stream.write(f'nix-store --add-root /root/personal-system --realise {personal}\n')
            for index, root in enumerate(source_roots):
                stream.write(f'nix-store --add-root /root/native-input-{index} --realise {shlex.quote(root)}\n')
        source = shlex.quote(source_roots[0])
        phases['recovery'] += f'''
mkdir -p /root/my-openbsd
cp {source}/templates/native-system/*.nix /root/my-openbsd/
chmod u+w /root/my-openbsd/*.nix
cd /root/my-openbsd
nix flake lock --override-input nix-openbsd path:{source}
openbsd-rebuild boot --flake .#my-openbsd
test "$(readlink -f /nix/var/nix/profiles/system)" = {personal}
'''
        phases['personal'] = f'''
test "$(readlink -f /run/current-system)" = {personal}
test "$(hostname)" = my-openbsd
test "$(hello)" = 'Hello, world!'
/etc/rc.d/resolvd check
test ! -e /etc/rc.d/httpd
test ! -e /etc/rc.d/relayd
mkdir -p /home/bestie/system-test
cp /root/my-openbsd/*.nix /root/my-openbsd/flake.lock /home/bestie/system-test/
chown -R bestie /home/bestie/system-test
su -l bestie -c 'cd system-test && openbsd-rebuild build --flake .#my-openbsd'
test "$(readlink -f /home/bestie/system-test/result-system)" = {personal}
cd /root/my-openbsd
openbsd-rebuild build --flake .#my-openbsd
openbsd-rebuild dry-activate --flake .#my-openbsd
openbsd-rebuild switch --flake .#my-openbsd
echo PERSONAL_SYSTEM_PASS
'''
    for name, body in phases.items():
        (payload / f'{name}.sh').write_text('set -eu\n' + body + '\n/etc/rc.d/nix_daemon check\n/etc/rc.d/sshd check\n')

    def port():
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            return str(sock.getsockname()[1])

    env = os.environ | {'NIX_VM_STATE_DIR': str(args.recovery_state or work / 'state'),
                        'NIX_VM_HTTP_PORT': port(), 'NIX_VM_SSH_PORT': port()}
    success = False
    try:
        for phase in phases:
            with (work / f'{phase}.log').open('wb', buffering=0) as log:
                process = subprocess.Popen([str(args.launcher / 'bin/run-openbsd-native-vm')],
                    env=env, stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT)
                try:
                    with (work / f'{phase}.log').open('rb') as reader:
                        buffer = b''

                        def expect(pattern, timeout=None):
                            nonlocal buffer
                            deadline = time.monotonic() + (args.timeout if timeout is None else timeout)
                            while time.monotonic() < deadline:
                                buffer += reader.read()
                                match = re.search(pattern, buffer)
                                if match:
                                    buffer = buffer[match.end():]
                                    return match
                                if process.poll() is not None:
                                    raise RuntimeError(f'{phase}: VM exited')
                                time.sleep(0.2)
                            raise TimeoutError(f'{phase}: waiting for {pattern!r}')

                        def send(line):
                            process.stdin.write((line + '\n').encode())
                            process.stdin.flush()

                        def boot_send(line):
                            # The EFI console can drop input even with a fixed delay.
                            # Wait for each character's echo before sending the next.
                            for byte in line.encode():
                                process.stdin.write(bytes([byte]))
                                process.stdin.flush()
                                expect(re.escape(bytes([byte])), timeout=5)
                            process.stdin.write(b'\n')
                            process.stdin.flush()

                        if phase == 'recovery':
                            expect(rb'boot>')
                            boot_send(f'set init {args.system_a}/bin/activate-init-native')
                            expect(rb'boot>')
                            boot_send(f'boot {args.system_a}/kernel')
                        expect(rb'login:')
                        send('root')
                        expect(rb'Password:')
                        send('toor')
                        expect(rb'root@')
                        send(f"{fetch} {url}/{phase}.sh -o /tmp/phase.sh && bash /tmp/phase.sh; status=$?; printf '\\nGENERATION_DONE:%s\\n' \"$status\"")
                        status = expect(rb'\nGENERATION_DONE:(\d+)\r?\n').group(1)
                        if status != b'0':
                            raise RuntimeError(f'{phase} failed: {status.decode()}')
                        send('shutdown -p now')
                        process.wait(timeout=60)
                        if process.returncode != 0:
                            raise RuntimeError('VM shutdown failed')
                        print(f'PASS {phase}', flush=True)
                finally:
                    if process.poll() is None:
                        try:
                            process.stdin.write(b'\x03shutdown -p now\n')
                            process.stdin.flush()
                            process.wait(timeout=60)
                        except (BrokenPipeError, subprocess.TimeoutExpired):
                            process.terminate()
                            process.wait(timeout=30)
        success = True
        result = ('RECOVERY_PASS' if args.recovery_state else
                  'LIVE_GENERATIONS_PASS' if args.live_only else 'GENERATIONS_PASS')
        print(result, flush=True)
    finally:
        server.shutdown()
        server.server_close()
        if success and not args.keep:
            if not args.recovery_state:
                shutil.rmtree(work / 'state')
            shutil.rmtree(public)
        print(f'Logs: {work}', flush=True)


if __name__ == '__main__':
    main()
