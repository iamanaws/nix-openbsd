"""Exercise the system Nix daemon across boot, restart and generation recovery."""
import argparse
import grp
import json
import os
from pathlib import Path
import pwd
import secrets
import shlex
import shutil
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixtures', type=Path)
    parser.add_argument('phase', choices=['live', 'boot-b', 'boot-rollback'])
    args = parser.parse_args()
    assert os.getuid() == 0
    fixtures = args.fixtures.resolve(strict=True)
    systems = {name: (fixtures / 'managedSystems' / name).resolve(strict=True)
               for name in ['a', 'b', 'changed-nix']}
    nix = (fixtures / 'nix/bin').resolve(strict=True)
    assert Path(shutil.which('nix')).resolve() == nix / 'nix'
    work = Path(tempfile.mkdtemp(prefix='openbsd-managed-sandbox.', dir='/var/tmp'))
    work.chmod(0o755)
    print('Managed sandbox logs: ' + str(work), flush=True)
    env = os.environ | {'NIX_REMOTE': 'daemon', 'NIX_DAEMON_SOCKET_PATH': '/nix/var/nix/daemon-socket/socket'}
    results = {'binary': str(nix / 'nix'), 'phase': args.phase}
    pool = [201, 202, 203, 204]
    config = Path('/etc/nix/nix.conf').read_text()
    settings = dict(line.split(' = ', 1) for line in config.splitlines() if ' = ' in line)
    assert settings['sandbox'] == 'true' and settings['sandbox-fallback'] == 'false', settings
    assert settings['sandbox-rdomains'].split() == list(map(str, pool)), settings
    assert settings['trusted-users'].split() == ['root'], settings
    outside = work / 'outside'
    outside.write_text('public managed sandbox fixture\n')
    outside.chmod(0o644)

    def run(*argv, check=True):
        result = subprocess.run(list(map(str, argv)), env=env, capture_output=True, text=True, timeout=180)
        assert not check or result.returncode == 0, (argv, result.stdout, result.stderr)
        return result

    def record(name):
        results[name] = 'passed'
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print('PASS managed-' + name, flush=True)

    def current():
        return Path('/run/current-system').resolve(strict=True)

    def selected():
        return Path('/nix/var/nix/profiles/system').resolve(strict=True)

    def daemon():
        run('/etc/rc.d/nix_daemon', 'check')
        processes = run('ps', '-axww', '-o', 'pid=,ppid=,args=').stdout.splitlines()
        pids = [int(pid) for line in processes if len(fields := line.split(None, 2)) == 3
                for pid, parent, command in [fields]
                if parent == '1' and command.split()[0] == str(nix / 'nix-daemon')]
        assert len(pids) == 1, pids
        assert Path('/etc/nix/nix.conf').read_text() == config
        status = run(fixtures / 'pfctl/bin/pfctl', '-si').stdout
        assert 'Status: Disabled' in status, status
        return pids[0]

    def clean():
        deadline = time.monotonic() + 30
        while True:
            remaining = [domain for domain in pool
                         if run(fixtures / 'ifconfig/bin/ifconfig', 'lo' + str(domain), check=False).returncode == 0]
            if not remaining:
                return
            assert time.monotonic() < deadline, remaining
            time.sleep(.1)

    unknown = work / 'undeclared'
    unknown.write_text('undeclared managed sandbox input\n')
    undeclared = run(nix / 'nix-store', '--add', unknown).stdout.strip()
    listeners = []
    for family, address in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
        listener = socket.socket(family, socket.SOCK_STREAM)
        listener.bind((address, 0))
        listener.listen(8)
        listeners.append(listener)
    ports = json.dumps([listener.getsockname()[1] for listener in listeners])

    def build(name, *, override=False):
        argv = [str(nix / 'nix-build'), str(fixtures / 'tests/build.nix'),
                '--argstr', 'fixtures', str((fixtures / 'builder').resolve(strict=True)),
                '--argstr', 'nonce', secrets.token_hex(8), '--argstr', 'outside', str(outside),
                '--argstr', 'undeclared', undeclared, '--argstr', 'ports', ports,
                '--no-substitute', '--no-out-link', '--max-jobs', '2', '--cores', '1']
        if override:
            argv += ['--option', 'sandbox', 'false']
        command = shlex.join(['env', 'NIX_REMOTE=daemon',
                              'NIX_DAEMON_SOCKET_PATH=' + env['NIX_DAEMON_SOCKET_PATH'], *argv])
        result = run('su', '-l', 'bestie', '-c', command, check=False)
        (work / (name + '.log')).write_text(result.stdout + result.stderr)
        assert result.returncode == 0, (name, result.stdout, result.stderr)
        output = Path(result.stdout.strip().splitlines()[-1])
        metadata = json.loads(output.read_text())
        assert metadata['domain'] in pool and metadata['uid'] != 0, metadata
        user = pwd.getpwuid(metadata['uid'])
        assert user.pw_name in grp.getgrnam('nixbld').gr_mem, metadata
        assert metadata['gid'] == user.pw_gid != grp.getgrnam('nixbld').gr_gid, metadata
        run(nix / 'nix-store', '--verify-path', output)
        clean()

    try:
        expected = systems['b' if args.phase == 'boot-b' else 'a']
        assert current() == selected() == expected
        pid = daemon()
        build('boot')
        record('boot-' + ('b' if args.phase == 'boot-b' else 'rollback' if args.phase == 'boot-rollback' else 'a'))
        if args.phase == 'live':
            build('untrusted-override', override=True)
            record('untrusted-client-policy')
            previous_pid = pid
            run('/etc/rc.d/nix_daemon', 'restart')
            pid = daemon()
            assert pid != previous_pid
            build('restart')
            record('restart')

            rejected = run(systems['changed-nix'] / 'bin/switch-to-configuration', 'test', check=False)
            (work / 'changed-nix.log').write_text(rejected.stdout + rejected.stderr)
            assert rejected.returncode != 0 and '/etc/nix/nix.conf has no live update handler' in rejected.stderr, rejected
            assert current() == selected() == systems['a'] and daemon() == pid
            record('nix-config-requires-reboot')

            Path('/run/nix-managed-fail-activation').touch()
            failed = run(systems['b'] / 'bin/switch-to-configuration', 'test', check=False)
            (work / 'failed-activation.log').write_text(failed.stdout + failed.stderr)
            assert failed.returncode != 0 and 'managed sandbox activation failure' in failed.stderr, failed
            assert not Path('/run/nix-managed-fail-activation').exists()
            assert current() == selected() == systems['a'] and daemon() == pid
            build('failed-activation-recovery')
            record('failed-activation-recovery')

            switched = run(systems['b'] / 'bin/switch-to-configuration', 'switch')
            (work / 'switch.log').write_text(switched.stdout + switched.stderr)
            assert current() == selected() == systems['b'] and daemon() == pid
            build('live-switch')
            record('live-switch')
            rolled_back = run('openbsd-rebuild', 'switch', '--rollback')
            (work / 'rollback.log').write_text(rolled_back.stdout + rolled_back.stderr)
            assert current() == selected() == systems['a'] and daemon() == pid
            build('rollback')
            record('rollback')
            run(systems['b'] / 'bin/switch-to-configuration', 'switch')
        elif args.phase == 'boot-b':
            run('openbsd-rebuild', 'switch', '--rollback')
            assert current() == selected() == systems['a'] and daemon() == pid
            build('rollback-before-reboot')
        results['result'] = 'passed'
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print('MANAGED_SANDBOX_RESULT ' + json.dumps(results), flush=True)
    finally:
        for listener in listeners:
            listener.close()


if __name__ == '__main__':
    main()
