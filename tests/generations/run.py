"""Boot A, boot B, roll back to A, and recover A through the boot console."""
import argparse
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import tempfile
import threading
import time


def closure(path):
    return set(subprocess.check_output(['nix-store', '-qR', path], text=True).splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--launcher', required=True, type=Path)
    parser.add_argument('--base-system', required=True)
    parser.add_argument('--system-a', required=True)
    parser.add_argument('--system-b', required=True)
    parser.add_argument('--live-fixtures', type=Path, help='fixture bundle with invalid, failed-start and failed-activation systems')
    parser.add_argument('--recovery-state', type=Path, help='rerun only console recovery on a preserved test disk')
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    args.launcher = args.launcher.resolve(strict=True)
    for name in ('base_system', 'system_a', 'system_b'):
        setattr(args, name, str(Path(getattr(args, name)).resolve(strict=True)))
    if args.live_fixtures:
        args.live_fixtures = args.live_fixtures.resolve(strict=True)
    if args.recovery_state:
        args.recovery_state = args.recovery_state.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix='nixopenbsd-generations.'))
    print(f'Test files: {work}', flush=True)
    public = work / 'public'
    token = secrets.token_hex(24)
    payload = public / token
    payload.mkdir(parents=True)
    needed = closure(args.system_a) | closure(args.system_b)
    if args.live_fixtures:
        needed |= closure(str(args.live_fixtures))
    paths = sorted(needed - closure(args.base_system))
    with (payload / 'systems.nar').open('wb') as stream:
        subprocess.run(['nix-store', '--export', *paths], stdout=stream, check=True)

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(public)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://10.0.2.2:{server.server_port}/{token}'
    a, b = map(shlex.quote, (args.system_a, args.system_b))
    (payload / 'setup.sh').write_text(f'''set -eu
curl --noproxy '*' -fsS {url}/systems.nar | nix-store --import
{a}/bin/switch-to-configuration boot
test "$(readlink -f /run/current-system)" = {shlex.quote(args.base_system)}
touch /root/generation-persistence
''')
    phases = {
        'install': f"curl --noproxy '*' -fsS {url}/setup.sh -o /tmp/install.sh && bash /tmp/install.sh",
        'a': f'''test "$(readlink -f /run/current-system)" = {a}
openbsd-system boot {b}
test "$(readlink -f /run/current-system)" = {a}''',
        'b': f'''test "$(readlink -f /run/current-system)" = {b}
openbsd-system rollback
test "$(readlink -f /nix/var/nix/profiles/system)" = {a}''',
        'rollback': f'''test "$(readlink -f /run/current-system)" = {a}
test -f /root/generation-persistence
nix-store --query --roots {a} | grep /nix/var/nix/profiles/
nix-store --query --roots {b} | grep /nix/var/nix/profiles/
nix-store --gc
nix-store --check-validity {a} {b}
openbsd-system boot {b}''',
        'recovery': f'''test "$(readlink -f /run/current-system)" = {a}
test "$(readlink -f /run/booted-system)" = {a}
test "$(readlink -f /nix/var/nix/profiles/system)" = {b}
openbsd-system rollback
test "$(readlink -f /nix/var/nix/profiles/system)" = {a}''',
    }
    if args.live_fixtures:
        fixtures = shlex.quote(str(args.live_fixtures))
        live_probe = f'''test "$(readlink -f /run/current-system)" = {a}
manager={a}/bin/openbsd-system
ssh_process() {{ ps -ax -o pid=,comm= | awk '$2 == "sshd" {{ print $1 }}'; }}
ssh_pid=$(ssh_process)
test -n "$ssh_pid"
default=$(cat /boot/nixos/default.conf)
{b}/bin/switch-to-configuration dry-activate
test "$(readlink -f /run/current-system)" = {a}
for failure in invalid failed-start failed-activation; do
    if $manager switch {fixtures}/$failure; then echo "Unexpected success: $failure"; exit 1; fi
    test "$(readlink -f /run/current-system)" = {a}
    test "$(readlink -f /nix/var/nix/profiles/system)" = {a}
    test "$(cat /boot/nixos/default.conf)" = "$default"
    /etc/rc.d/httpd check
    curl -fsS http://127.0.0.1:8080/ | grep NixBSD
done
{b}/bin/switch-to-configuration test
test "$(readlink -f /run/current-system)" = {b}
test "$(readlink -f /nix/var/nix/profiles/system)" = {a}
test "$(cat /boot/nixos/default.conf)" = "$default"
/etc/rc.d/generation_probe check
curl -fsS http://127.0.0.1:8080/ | grep 'generation B'
test "$(/run/current-system/sw/bin/hello)" = 'Hello, world!'
$manager test {a}
if {b}/etc/rc.d/generation_probe check; then echo 'Removed daemon still running'; exit 1; fi
{b}/bin/switch-to-configuration switch
test "$(readlink -f /run/current-system)" = {b}
test "$(readlink -f /nix/var/nix/profiles/system)" = {b}
$manager rollback --live
test "$(readlink -f /run/current-system)" = {a}
test "$(readlink -f /nix/var/nix/profiles/system)" = {a}
test "$(ssh_process)" = "$ssh_pid"
for root in /nix/var/nix/gcroots/openbsd-system.*; do test ! -d "$root"; done
echo LIVE_SWITCH_PASS
'''
        phases['a'] = live_probe + phases['a']
    if args.recovery_state:
        phases = {'recovery': phases['recovery']}
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

                        def expect(pattern, timeout=600):
                            nonlocal buffer
                            deadline = time.monotonic() + timeout
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
                        send(f"curl --noproxy '*' -fsS {url}/{phase}.sh -o /tmp/phase.sh && bash /tmp/phase.sh; status=$?; printf '\\nGENERATION_DONE:%s\\n' \"$status\"")
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
        print('RECOVERY_PASS' if args.recovery_state else 'GENERATIONS_PASS', flush=True)
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
