"""Exercise OpenBSD's maintenance scripts and their local hooks."""
import argparse
import hashlib
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import time

STATE = Path('/var/lib/maintenance-test')
PERIODS = ('daily', 'weekly', 'monthly')


def run(*args, success=True, exit_code=None, env=None):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=180, env=env)
    print(result.stdout + result.stderr, end='', flush=True)
    assert (result.returncode == exit_code if exit_code is not None else
            (result.returncode == 0) == success), (args, result.returncode)
    return result.stdout


def eventually(check, timeout=60):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return check()
        except (AssertionError, OSError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(.2)


def token():
    value = str(time.monotonic_ns())
    (STATE / 'token').write_text(value)
    return value


def private(path):
    info = path.stat()
    assert not path.is_symlink()
    assert info.st_uid == info.st_gid == 0
    assert stat.S_IMODE(info.st_mode) == 0o600, path


def report(period, marker):
    path = Path('/var/log', period + '.out')
    private(path)
    text = path.read_text()
    assert marker in text, (marker, text)
    assert not re.search(r'not found|cannot execute|permission denied|illegal option|unknown option', text, re.I), text
    previous = path.with_suffix('.out.old')
    if previous.exists():
        private(previous)
    return text


def delivered(marker):
    eventually(lambda: assert_mail(marker))


def assert_mail(marker):
    assert marker in Path('/var/mail/bestie').read_text(), marker


def job(period, generation):
    marker = f'native-{generation}-{period}-{token()}'
    cron = Path('/etc/crontab').read_text()
    command = next(line.split(maxsplit=6)[6] for line in cron.splitlines() if line.endswith('/etc/' + period))
    # The weekly locate cleanup trap exits 1 even on success.
    run('/bin/sh', '-c', command, exit_code=1 if period == 'weekly' and Path('/var/db/locate.database').exists() else 0)
    report(period, marker)
    delivered(marker)
    return marker


def calendar(package):
    account = pwd.getpwnam('bestie')
    path = Path(account.pw_dir, 'calendar')
    assert not path.exists()
    marker = 'native-calendar-' + token()
    try:
        path.write_text(time.strftime('%b %d') + '\t' + marker + '\n')
        os.chown(path, account.pw_uid, account.pw_gid)
        run(package / 'bin/calendar', '-a')
        delivered(marker)
    finally:
        path.unlink(missing_ok=True)


def process(name):
    rows = subprocess.check_output(['ps', '-ax', '-o', 'pid=,ppid=,comm='], text=True)
    matches = [fields[0] for line in rows.splitlines()
               if len(fields := line.split()) == 3 and fields[1:] == ['1', name]]
    assert len(matches) == 1, (name, matches)
    return matches[0]


def check_generation(name):
    for period in PERIODS:
        private(Path('/etc', period + '.local'))
        assert '$OpenBSD:' in Path('/etc', period).read_text()
    scripts = Path('/etc/daily').resolve().parent.parent
    assert not (scripts / 'bin').exists()
    persistence = Path('/root/maintenance-persistence')
    if persistence.exists():
        marker = persistence.read_text()
        report('weekly', marker)
        delivered(marker)
    job('monthly', name)
    print('PASS native maintenance generation ' + name, flush=True)


def live(a, b, fixtures):
    man = STATE / 'man/man1'
    man.mkdir(parents=True, exist_ok=True)
    (man / 'maintenance.1').write_text('.Dd October 27, 2026\n.Dt MAINTENANCE 1\n.Os\n.Sh NAME\n.Nm maintenance\n.Nd native maintenance fixture\n')
    locate = STATE / 'locate'
    locate.mkdir(exist_ok=True)
    for number in range(128):
        (locate / hashlib.sha256(str(number).encode()).hexdigest()).touch()
    Path('/var/db/locate.database').touch()
    check_generation('a')
    cron, ssh = process('cron'), process('sshd')
    calendar(fixtures / 'calendar')
    marker = job('daily', 'a')
    assert (Path('/var/backups/master.passwd.current')).is_file()
    security = Path('/var/log/security.out').read_text()
    failure = re.search(r"Can't locate[^\n]*|cannot spawn[^\n]*|command not found[^\n]*|fdisk: [^\n]*|mtree: [^\n]*", security)
    assert not failure, failure.group(0) if failure else ''
    job('weekly', 'a')
    assert (STATE / 'man/mandoc.db').stat().st_size > 0
    output = run(fixtures / 'locate/bin/locate', '-d', '/var/db/locate.database', str(locate))
    assert hashlib.sha256(b'42').hexdigest() in output
    database = STATE / 'standalone.locate.database'
    run(fixtures / 'locate/libexec/locate.updatedb', '--fcodes=' + str(database),
        env=os.environ | {'PATH': '/bin:/usr/bin'})
    output = run(fixtures / 'locate/bin/locate', '-d', database, str(locate))
    assert hashlib.sha256(b'42').hexdigest() in output

    before = Path('/etc/monthly.local').read_bytes()
    run('openbsd-rebuild', 'dry-activate', '--store-path', b)
    assert Path('/etc/monthly.local').read_bytes() == before
    selected = Path('/boot/nixos/default.conf').read_bytes()
    for name in ('invalid', 'invalid-schedule', 'failed-activation'):
        run('openbsd-rebuild', 'switch', '--store-path', fixtures / name, success=False)
        assert Path('/run/current-system').resolve() == a
        assert Path('/boot/nixos/default.conf').read_bytes() == selected
        assert process('cron') == cron

    marker = 'native-a-monthly-' + token()
    eventually(lambda: report('monthly', marker), timeout=150)
    delivered(marker)
    run('openbsd-rebuild', 'test', '--store-path', b)
    marker = 'native-b-monthly-' + token()
    eventually(lambda: report('monthly', marker), timeout=150)
    delivered(marker)
    job('weekly', 'b')
    assert process('cron') == cron
    run('openbsd-rebuild', 'test', '--store-path', fixtures / 'without-monthly')
    assert not any(line.endswith('/etc/monthly') for line in Path('/etc/crontab').read_text().splitlines())
    saved = Path('/var/log/weekly.out').read_bytes()
    run('openbsd-rebuild', 'test', '--store-path', fixtures / 'disabled')
    assert not Path('/etc/daily').exists()
    assert Path('/var/log/weekly.out').read_bytes() == saved
    run('openbsd-rebuild', 'test', '--store-path', a)
    run('openbsd-rebuild', 'switch', '--store-path', b)
    run('openbsd-rebuild', 'switch', '--rollback')
    marker = job('weekly', 'a')
    Path('/root/maintenance-persistence').write_text(marker)
    assert process('cron') == cron and process('sshd') == ssh
    print('MAINTENANCE_LIVE_PASS', flush=True)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('phase', choices=['live', 'a', 'b'])
parser.add_argument('a', type=Path)
parser.add_argument('b', type=Path)
parser.add_argument('fixtures', nargs='?', type=Path)
args = parser.parse_args()
if args.phase == 'live':
    live(args.a, args.b, args.fixtures)
else:
    check_generation(args.phase)
print('MAINTENANCE_' + args.phase.upper() + '_PASS', flush=True)
