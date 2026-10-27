"""Check native log delivery, rotation and recovery during configuration changes."""
import argparse
import grp
from pathlib import Path
import pwd
import stat
import subprocess
import syslog
import time


def run(*args, success=True):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=120)
    print(result.stdout + result.stderr, end='', flush=True)
    assert (result.returncode == 0) == success, (args, result.returncode)
    return result.stdout.strip()


def eventually(check, timeout=30):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return check()
        except (AssertionError, OSError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(.2)


def process(name):
    rows = subprocess.check_output(['ps', '-ax', '-o', 'pid=,ppid=,comm='], text=True)
    parents = [int(fields[0]) for line in rows.splitlines()
               if len(fields := line.split()) == 3 and fields[1:] == ['1', name]]
    assert len(parents) == 1, (name, parents)
    return parents[0]


def emit(name):
    message = 'logging-' + name + '-' + str(time.monotonic_ns())
    syslog.openlog('generation-test')
    syslog.syslog(syslog.LOG_LOCAL0 | syslog.LOG_NOTICE, message)
    path = Path('/var/log/logging-' + name)

    def delivered():
        assert message in path.read_text()
    eventually(delivered)
    return message


def check_permissions(path):
    info = path.stat()
    assert not path.is_symlink()
    assert stat.S_IMODE(info.st_mode) == 0o640
    assert (info.st_uid, info.st_gid) == (pwd.getpwnam('root').pw_uid, grp.getgrnam('wheel').gr_gid)


def check_generation(name):
    run('/etc/rc.d/syslogd', 'check')
    assert 'local0.notice /var/log/logging-' + name in Path('/etc/syslog.conf').read_text()
    count = '1' if name == 'a' else '2'
    assert '640 ' + count + ' 1 *' in Path('/etc/newsyslog.conf').read_text()
    run('newsyslog', '-n', '-f', '/etc/newsyslog.conf')
    path = Path('/var/log/logging-' + name)
    check_permissions(path)
    emit(name)
    persistence = Path('/root/logging-persistence')
    if persistence.exists():
        assert any(persistence.read_text() in p.read_text() for p in Path('/var/log').glob('logging-a*'))


def rotate(name):
    path = Path('/var/log/logging-' + name)
    before = emit(name)
    contents = path.read_bytes()
    run('newsyslog', '-nF', '-f', '/etc/newsyslog.conf', path)
    assert path.read_bytes() == contents
    run('newsyslog', '-F', '-f', '/etc/newsyslog.conf', path)
    archive = Path(str(path) + '.0')
    assert before in archive.read_text()
    check_permissions(archive)
    after = emit(name)
    assert before not in path.read_text() and after not in archive.read_text()


def live(a, b, fixtures):
    current = Path('/run/current-system')
    profile = Path('/nix/var/nix/profiles/system')
    default = Path('/boot/nixos/default.conf')
    selected = default.read_bytes()
    assert current.resolve() == a and profile.resolve() == a
    check_generation('a')
    # Equal-size immutable configs also have equal mtimes; a HUP can miss this change.
    assert (a / 'etc/syslog.conf').stat().st_size == (b / 'etc/syslog.conf').stat().st_size
    assert (a / 'etc/syslog.conf').stat().st_mtime_ns == (b / 'etc/syslog.conf').stat().st_mtime_ns
    pid = process('syslogd-parent')
    cron = process('cron')
    run('openbsd-rebuild', 'dry-activate', '--store-path', b)
    assert not Path('/var/log/logging-b').exists()
    run('openbsd-rebuild', 'test', '--store-path', a)
    assert process('syslogd-parent') == pid
    rotate('a')

    for failure in ['invalid', 'failed-start', 'failed-activation']:
        pid = process('syslogd-parent')
        run('openbsd-rebuild', 'switch', '--store-path', fixtures / failure, success=False)
        assert current.resolve() == a and profile.resolve() == a
        assert default.read_bytes() == selected
        check_generation('a')
        if failure == 'invalid':
            assert process('syslogd-parent') == pid

    pid = process('syslogd-parent')
    preserved = Path('/var/log/logging-a').read_bytes()
    run('openbsd-rebuild', 'test', '--store-path', fixtures / 'rotation')
    assert process('syslogd-parent') == pid
    assert Path('/var/log/logging-a').read_bytes() == preserved
    created = Path('/var/log/logging-new')
    check_permissions(created)
    created.write_text('preserved across activation\n')
    run('openbsd-rebuild', 'test', '--store-path', a)
    assert created.read_text() == 'preserved across activation\n'
    assert process('syslogd-parent') == pid

    run('openbsd-rebuild', 'test', '--store-path', fixtures / 'without-rotation')
    assert not Path('/etc/newsyslog.conf').exists()
    assert not Path('/etc/rc.d/newsyslog_check').exists()
    emit('a')
    assert process('cron') == cron
    run('openbsd-rebuild', 'test', '--store-path', a)
    check_generation('a')
    assert process('cron') == cron
    pid = process('syslogd-parent')

    run('openbsd-rebuild', 'test', '--store-path', b)
    check_generation('b')
    assert process('syslogd-parent') != pid
    assert process('cron') == cron
    assert profile.resolve() == a and default.read_bytes() == selected
    pid = process('syslogd-parent')
    run('openbsd-rebuild', 'test', '--store-path', b)
    assert process('syslogd-parent') == pid
    rotate('b')
    rotate('b')
    assert Path('/var/log/logging-b.1').exists()

    run('/etc/rc.d/syslogd', 'stop')
    run('openbsd-rebuild', 'test', '--store-path', a)
    run('/etc/rc.d/syslogd', 'check', success=False)
    rows = subprocess.check_output(['ps', '-ax', '-o', 'comm='], text=True).split()
    assert 'syslogd' not in rows and 'syslogd-parent' not in rows
    run('/etc/rc.d/syslogd', 'start')
    check_generation('a')
    run('openbsd-rebuild', 'switch', '--store-path', b)
    check_generation('b')
    run('openbsd-rebuild', 'switch', '--rollback')
    assert current.resolve() == a and profile.resolve() == a
    check_generation('a')
    assert process('cron') == cron
    Path('/root/logging-persistence').write_text(emit('a'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['live', 'a', 'b'])
    parser.add_argument('system_a', type=Path)
    parser.add_argument('system_b', type=Path)
    parser.add_argument('fixtures', type=Path, nargs='?')
    args = parser.parse_args()
    if args.phase == 'live':
        if not args.fixtures:
            parser.error('live checks require the fixture bundle')
        live(args.system_a, args.system_b, args.fixtures)
    else:
        check_generation(args.phase)
    print('LOGGING_' + args.phase.upper() + '_PASS', flush=True)


if __name__ == '__main__':
    main()
