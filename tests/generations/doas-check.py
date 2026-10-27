"""Check native doas authentication, permissions and generation rollback."""
import argparse
import errno
import grp
import os
from pathlib import Path
import pty
import pwd
import re
import select
import shlex
import signal
import stat
import subprocess
import time


DOAS = '/run/wrappers/bin/doas'


def run(*args, success=True):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=120)
    print(result.stdout + result.stderr, end='', flush=True)
    assert (result.returncode == 0) == success, (args, result.returncode)
    return result.stdout.strip()


def user(name, *args, success=True):
    return run('su', '-l', name, '-c', shlex.join(list(map(str, args))), success=success)


def authenticate(password, success, tools):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp('su', ['su', '-l', 'bestie', '-c', shlex.join([DOAS, str(tools / 'id'), '-u'])])
    output = b''
    answered = 0
    status = None
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if select.select([fd], [], [], .2)[0]:
                try:
                    data = os.read(fd, 4096)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not data:
                    break
                output += data
                prompts = len(re.findall(rb'password: ', output))
                while answered < prompts:
                    os.write(fd, password.encode() + b'\n')
                    answered += 1
            done, child_status = os.waitpid(pid, os.WNOHANG)
            if done:
                status = child_status
                break
        else:
            raise TimeoutError('doas authentication did not finish')
        if status is None:
            _, status = os.waitpid(pid, 0)
        assert answered > 0, output
        assert (os.waitstatus_to_exitcode(status) == 0) == success, output
        if success:
            assert re.search(rb'(?:^|\r?\n)0\r?\n', output), output
    finally:
        os.close(fd)
        if status is None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
    print('PASS doas password accepted' if success else 'PASS doas wrong password rejected', flush=True)


def check_generation(name, tools):
    wrapper = Path(DOAS)
    info = wrapper.stat()
    assert info.st_uid == 0 and info.st_mode & stat.S_ISUID
    assert not info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    config = Path('/etc/doas.conf')
    assert config.stat().st_uid == 0
    assert stat.S_IMODE(config.stat().st_mode) == 0o440
    run(DOAS, '-C', config)
    assert not Path('/run/wrappers/bin/sudo').exists()
    assert user('bestie', DOAS, '-n', '-u', 'daemon', tools / 'id', '-u') == str(pwd.getpwnam('daemon').pw_uid)
    user('bestie', DOAS, '-n', tools / 'id', '-u', success=False)
    user('doas-test', DOAS, '-n', tools / 'id', '-u', success=False)
    assert user('bestie', DOAS, '-n', tools / 'echo', name) == name
    user('bestie', DOAS, '-n', tools / 'echo', 'b' if name == 'a' else 'a', success=False)
    user('bestie', DOAS, '-n', tools / 'echo', name, 'extra', success=False)
    environment = user('bestie', 'env', 'DOAS_TEST_UNTRUSTED=poison', DOAS, '-n', '-u', 'daemon', tools / 'env')
    values = dict(line.split('=', 1) for line in environment.splitlines() if '=' in line)
    assert 'DOAS_TEST_UNTRUSTED' not in values
    assert values['USER'] == 'daemon' and values['DOAS_USER'] == 'bestie'
    assert values['HOME'] == pwd.getpwnam('daemon').pw_dir
    assert 'wheel' not in [g.gr_name for g in grp.getgrall() if 'doas-test' in g.gr_mem]
    print('PASS doas generation ' + name, flush=True)


def live(a, b, tools, fixtures):
    current = Path('/run/current-system')
    profile = Path('/nix/var/nix/profiles/system')
    default = Path('/boot/nixos/default.conf')
    selected = default.read_bytes()
    assert current.resolve() == a and profile.resolve() == a
    check_generation('a', tools)
    authenticate('incorrect-test-password', False, tools)
    authenticate('toor', True, tools)
    before = Path('/etc/doas.conf').read_bytes()
    run('openbsd-rebuild', 'dry-activate', '--store-path', b)
    assert Path('/etc/doas.conf').read_bytes() == before
    for failure in ['invalid', 'failed-activation', 'without-doas']:
        run('openbsd-rebuild', 'switch', '--store-path', fixtures / failure, success=False)
        assert current.resolve() == a and profile.resolve() == a
        assert default.read_bytes() == selected
        check_generation('a', tools)
    run('openbsd-rebuild', 'test', '--store-path', fixtures / 'nopass-wheel')
    assert user('bestie', DOAS, '-n', tools / 'id', '-u') == '0'
    run('openbsd-rebuild', 'test', '--store-path', a)
    check_generation('a', tools)
    run('openbsd-rebuild', 'test', '--store-path', b)
    assert current.resolve() == b and profile.resolve() == a
    assert default.read_bytes() == selected
    check_generation('b', tools)
    run('openbsd-rebuild', 'test', '--store-path', a)
    check_generation('a', tools)
    run('openbsd-rebuild', 'switch', '--store-path', b)
    run('openbsd-rebuild', 'switch', '--rollback')
    assert current.resolve() == a and profile.resolve() == a
    check_generation('a', tools)
    print('DOAS_LIVE_PASS', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['live', 'a', 'b'])
    parser.add_argument('a', type=Path)
    parser.add_argument('b', type=Path)
    parser.add_argument('tools', type=Path)
    parser.add_argument('fixtures', nargs='?', type=Path)
    args = parser.parse_args()
    if args.phase == 'live':
        assert args.fixtures is not None
        live(args.a, args.b, args.tools, args.fixtures)
    else:
        check_generation(args.phase, args.tools)


if __name__ == '__main__':
    main()
