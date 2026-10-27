"""Check native local delivery, cron mail, queues and generation rollback."""
import argparse
import grp
from pathlib import Path
import pwd
import shlex
import socket
import stat
import subprocess
import time


def run(*args, success=True, input=None, exit_code=None):
    result = subprocess.run(list(map(str, args)), input=input, capture_output=True,
                            text=True, timeout=120)
    print(result.stdout + result.stderr, end='', flush=True)
    assert (result.returncode == exit_code if exit_code is not None else
            (result.returncode == 0) == success), (args, result.returncode)
    return result.stdout.strip()


def eventually(check, timeout=45):
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


def send(recipient='root', user='bestie', token=None, offline=False):
    token = token or 'mail-test-' + str(time.monotonic_ns())
    run('su', '-l', user, '-c', shlex.join(['/run/wrappers/bin/sendmail', '-i', recipient]),
        input=f'To: {recipient}\nSubject: {token}\n\n{token}\n',
        # OpenBSD deliberately reports EX_TEMPFAIL after successful offline queuing.
        exit_code=75 if offline else 0)
    return token


def delivered(user, token, timeout=45):
    mailbox = Path('/var/mail') / user

    def check():
        assert token in mailbox.read_text(), (user, token)
        info = mailbox.stat()
        account = pwd.getpwnam(user)
        assert not mailbox.is_symlink()
        assert info.st_uid == account.pw_uid and info.st_gid == account.pw_gid
        assert stat.S_IMODE(info.st_mode) == 0o600
    eventually(check, timeout)


def check_generation(name):
    user = 'bestie' if name == 'a' else 'mail-test'
    run('/etc/rc.d/smtpd', 'check')
    run('smtpd', '-n', '-f', '/etc/mail/smtpd.conf')
    assert 'root: ' + user in Path('/etc/mail/aliases').read_text()
    for path, mode, owner, group in [
        ('/var/spool/smtpd', 0o711, 'root', 'root'),
        ('/var/spool/smtpd/offline', 0o770, 'root', '_smtpq'),
        ('/var/spool/smtpd/queue', 0o700, '_smtpq', 'root'),
    ]:
        info = Path(path).stat()
        assert stat.S_IMODE(info.st_mode) == mode, path
        assert (info.st_uid, info.st_gid) == (pwd.getpwnam(owner).pw_uid, grp.getgrnam(group).gr_gid)
    wrapper = Path('/run/wrappers/bin/sendmail').stat()
    assert wrapper.st_mode & stat.S_ISGID and wrapper.st_gid == grp.getgrnam('_smtpq').gr_gid
    lock = Path('/run/wrappers/bin/lockspool').stat()
    assert lock.st_uid == 0 and lock.st_mode & stat.S_ISUID
    # The default service accepts only local submission through its Unix socket.
    for host in ['127.0.0.1', '::1']:
        try:
            connection = socket.create_connection((host, 25), timeout=1)
        except OSError:
            pass
        else:
            connection.close()
            raise AssertionError('Unexpected SMTP listener on ' + host)
    token = send('postmaster')
    delivered(user, token)
    run('su', '-l', user, '-c', shlex.join(['head', '-n', '1', '/var/mail/' + user]))
    persistence = Path('/root/mail-persistence')
    if persistence.exists():
        delivered('bestie', persistence.read_text())
    queued = Path('/root/mail-queued')
    if queued.exists():
        # The envelope was expanded under A before rebooting into B.
        delivered('bestie', queued.read_text())
    print('PASS mail generation ' + name, flush=True)


def live(a, b, fixtures):
    current = Path('/run/current-system')
    profile = Path('/nix/var/nix/profiles/system')
    default = Path('/boot/nixos/default.conf')
    selected = default.read_bytes()
    assert current.resolve() == a and profile.resolve() == a
    check_generation('a')
    run('su', '-l', 'bestie', '-c', '/run/wrappers/bin/sendmail nobody@example.invalid',
        input='Subject: relay rejection\n\nThis must stay local.\n', success=False)
    cron = process('cron')
    ssh = process('sshd')
    pid = process('smtpd')
    run('openbsd-rebuild', 'dry-activate', '--store-path', b)
    assert process('smtpd') == pid
    run('openbsd-rebuild', 'test', '--store-path', a)
    assert process('smtpd') == pid
    delivered('bestie', 'mail-cron-a', timeout=150)

    for failure in ['invalid', 'failed-start', 'failed-activation', 'without-mail']:
        pid = process('smtpd')
        run('openbsd-rebuild', 'switch', '--store-path', fixtures / failure, success=False)
        assert current.resolve() == a and profile.resolve() == a
        assert default.read_bytes() == selected
        check_generation('a')
        if failure in ['invalid', 'without-mail']:
            assert process('smtpd') == pid

    # A regular user must be able to queue mail while the service is stopped.
    run('/etc/rc.d/smtpd', 'stop')
    token = send(offline=True)
    assert any(Path('/var/spool/smtpd/offline').iterdir())
    run('openbsd-rebuild', 'test', '--store-path', b)
    run('/etc/rc.d/smtpd', 'check', success=False)
    run('/etc/rc.d/smtpd', 'start')
    delivered('mail-test', token)
    check_generation('b')
    assert current.resolve() == b and profile.resolve() == a
    assert default.read_bytes() == selected
    assert process('cron') == cron and process('sshd') == ssh
    pid = process('smtpd')
    run('openbsd-rebuild', 'test', '--store-path', b)
    assert process('smtpd') == pid
    delivered('mail-test', 'mail-cron-b', timeout=150)
    run('openbsd-rebuild', 'test', '--store-path', a)
    check_generation('a')
    run('openbsd-rebuild', 'switch', '--store-path', b)
    run('openbsd-rebuild', 'switch', '--rollback')
    assert current.resolve() == a and profile.resolve() == a
    check_generation('a')
    assert process('cron') == cron and process('sshd') == ssh
    token = send()
    delivered('bestie', token)
    Path('/root/mail-persistence').write_text(token)

    # Keep an accepted envelope on disk across the next reboot and ruleset change.
    run('smtpctl', 'pause', 'mda')
    queued = send()

    def queued_envelope():
        output = run('smtpctl', 'show', 'queue')
        assert output and 'bestie' in output
    eventually(queued_envelope)
    Path('/root/mail-queued').write_text(queued)
    print('MAIL_LIVE_PASS', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['live', 'a', 'b'])
    parser.add_argument('a', type=Path)
    parser.add_argument('b', type=Path)
    parser.add_argument('fixtures', nargs='?', type=Path)
    args = parser.parse_args()
    if args.phase == 'live':
        assert args.fixtures is not None
        live(args.a, args.b, args.fixtures)
    else:
        check_generation(args.phase)
    print('MAIL_' + args.phase.upper() + '_PASS', flush=True)


if __name__ == '__main__':
    main()
