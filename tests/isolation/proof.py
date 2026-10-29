"""Exercise the OpenBSD sandbox through Nix's real daemon and builder lifecycle."""
from contextlib import contextmanager, ExitStack
import fcntl
import grp
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time


def main():
    assert os.getuid() == 0
    fixtures = Path(sys.argv[1]).resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix='openbsd-isolation.', dir='/var/tmp'))
    work.chmod(0o755)
    print('Guest isolation logs: ' + str(work), flush=True)
    # Keep the legacy command name: Nix dispatches these symlinks by argv[0].
    nix = Path(shutil.which('nix-build')).resolve().with_name('nix-build')
    daemon_binary = nix.parent / 'nix-daemon'
    version = subprocess.check_output([nix.parent / 'nix', '--version'], text=True).strip()
    assert '2.35.' in version, version
    outside = work / 'outside/readable'
    outside.parent.mkdir(mode=0o755)
    outside.write_text('public isolation fixture\n')
    outside.chmod(0o644)
    unknown = work / 'undeclared'
    unknown.write_text('undeclared store input\n')
    undeclared = subprocess.check_output(['nix-store', '--add', unknown], text=True).strip()
    ifconfig = str(fixtures / 'ifconfig/bin/ifconfig')
    pool = [201, 202, 203, 204]
    results = {'nix': version, 'binary': str(nix.parent / 'nix'), 'defaultSandbox': False}
    payload = b'fixed-output isolation fixture\n'
    daemon = None
    daemon_log = None
    clients = []
    env = os.environ | {'NIX_REMOTE': 'daemon', 'NIX_DAEMON_SOCKET_PATH': str(work / 'socket')}

    def command(argv, **kwargs):
        return subprocess.run(list(map(str, argv)), env=env, capture_output=True,
                              text=True, timeout=kwargs.pop('timeout', 600), **kwargs)

    def record(name):
        results[name] = 'passed'
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print('PASS ' + name, flush=True)

    def clean_domains():
        # A disconnected client can exit before its daemon worker cleans up.
        deadline = time.monotonic() + 30
        while True:
            remaining = [result.stdout for domain in pool
                         if (result := command([ifconfig, 'lo' + str(domain)])).returncode == 0]
            if not remaining:
                return
            assert time.monotonic() < deadline, '\n'.join(remaining)
            time.sleep(.1)

    def stop_daemon():
        nonlocal daemon, daemon_log
        if daemon is not None:
            daemon.terminate()
            daemon.wait(timeout=30)
            daemon = None
            daemon_log.close()
            daemon_log = None

    def start_daemon(domains='201 202 203 204', features=''):
        nonlocal daemon, daemon_log
        stop_daemon()
        Path(env['NIX_DAEMON_SOCKET_PATH']).unlink(missing_ok=True)
        daemon_log = (work / ('daemon-' + secrets.token_hex(4) + '.log')).open('w')
        daemon = subprocess.Popen([daemon_binary, '--option', 'sandbox', 'true',
                                   '--option', 'sandbox-fallback', 'false',
                                   '--option', 'sandbox-rdomains', domains,
                                   '--option', 'system-features', features,
                                   '--option', 'trusted-users', 'root',
                                   '--option', 'hashed-mirrors', '',
                                   '--option', 'max-jobs', '2', '--option', 'cores', '2'],
                                  env=env | {'NIX_REMOTE': 'local'}, stdin=subprocess.DEVNULL,
                                  stdout=daemon_log, stderr=subprocess.STDOUT)
        for _ in range(100):
            assert daemon.poll() is None, 'test daemon exited'
            if Path(env['NIX_DAEMON_SOCKET_PATH']).is_socket():
                return
            time.sleep(.1)
        raise AssertionError('test daemon did not create its socket')

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    class IPv6Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6

    servers = [ThreadingHTTPServer(('127.0.0.1', 0), Handler), IPv6Server(('::1', 0), Handler)]
    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in servers]
    ports = [server.server_port for server in servers]

    def build_args(kind='checks', mode=None, regular=False, no_chroot=False, url='', extra=()):
        inputs = fixtures if kind == 'consumers' else (fixtures / 'builder').resolve(strict=True)
        argv = [str(nix), str(fixtures / 'tests/build.nix'), '--argstr', 'fixtures', str(inputs),
                '--argstr', 'nonce', secrets.token_hex(8), '--argstr', 'kind', kind,
                '--argstr', 'outside', str(outside), '--argstr', 'undeclared', undeclared,
                '--argstr', 'ports', json.dumps(ports), '--argstr', 'url', url,
                '--argstr', 'hash', hashlib.sha256(payload).hexdigest(),
                '--arg', 'noChroot', 'true' if no_chroot else 'false',
                '--no-out-link', '--no-substitute', '--max-jobs', '2', '--cores', '2', *extra]
        if mode is not None:
            argv += ['--option', 'sandbox', mode]
        if regular:
            argv = ['su', '-l', 'bestie', '-c', shlex.join([
                'env', 'NIX_REMOTE=daemon', 'NIX_DAEMON_SOCKET_PATH=' + env['NIX_DAEMON_SOCKET_PATH'], *argv])]
        return argv

    def build(name, *, expected=0, **kwargs):
        result = command(build_args(**kwargs))
        (work / (name + '.log')).write_text(result.stdout + result.stderr)
        assert (result.returncode == 0) == (expected == 0), (name, result.returncode, result.stderr[-6000:])
        if expected == 0:
            output = Path(result.stdout.strip().splitlines()[-1])
            assert command(['nix-store', '--check-validity', output]).returncode == 0
            return output
        return result.stderr

    @contextmanager
    def held_build(kind='hold', extra=()):
        log = (work / ('held-' + secrets.token_hex(4) + '.log'))
        with log.open('w') as stream:
            client = subprocess.Popen(build_args(kind=kind, extra=extra), stdout=stream, stderr=subprocess.STDOUT, env=env)
        clients.append(client)
        try:
            for _ in range(1200):
                text = log.read_text()
                match = re.search(r'SANDBOX_METADATA (.+)', text)
                if match:
                    yield client, json.loads(match.group(1)), log
                    break
                assert client.poll() is None, text[-6000:]
                time.sleep(.1)
            else:
                raise AssertionError('builder did not start: ' + log.read_text()[-6000:])
        finally:
            if client.poll() is None:
                client.send_signal(signal.SIGINT)
            client.wait(timeout=30)
            clients.remove(client)

    def user_processes(uid):
        result = command(['ps', '-U', str(uid), '-o', 'pid=,stat='])
        return [line for line in result.stdout.splitlines() if 'Z' not in line]

    @contextmanager
    def one_build_user():
        # Recovery belongs to the next holder of the abandoned UID's lock,
        # not necessarily the next build. Reserve the other users using the
        # same flock protocol as Nix's SimpleUserLock.
        users = grp.getgrnam('nixbld').gr_mem
        assert users
        with ExitStack() as locks:
            selected = None
            for name in users:
                uid = pwd.getpwnam(name).pw_uid
                path = Path(os.environ.get('NIX_STATE_DIR', '/nix/var/nix')) / 'userpool' / str(uid)
                lock = locks.enter_context(path.open('a+b'))
                deadline = time.monotonic() + 30
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        assert time.monotonic() < deadline, 'build-user lock still held: ' + name
                        time.sleep(.1)
                if selected is None:
                    selected = uid, lock
            uid, lock = selected
            fcntl.flock(lock, fcntl.LOCK_UN)
            yield uid

    clean_domains()
    for thread in threads:
        thread.start()
    subprocess.run(['/etc/rc.d/nix_daemon', 'stop'], check=True)
    try:
        start_daemon()
        output = build('unsandboxed-control', kind='control', mode='false')
        lines = output.read_text().splitlines()
        assert lines[0] == 'public isolation fixture' and int(lines[1]) != 0
        record('unsandboxedControlReadsOutside')
        for mode in ['true', 'relaxed']:
            output = build('sandbox-' + mode, mode=mode)
            metadata = json.loads(output.read_text())
            assert metadata['domain'] in pool and not user_processes(metadata['uid'])
            clean_domains()
        build('regular-user-sandbox', regular=True)
        error = build('untrusted-disable-sandbox', kind='control', mode='false', regular=True, expected=1)
        assert 'sandbox' in error and 'ISOLATION_BUILDER_STARTED' in error
        record('daemonFilesystemNetworkIdentityAndPrivateLoopback')
        record('untrustedClientCannotDisableSandbox')
        output = build('native-consumers', kind='consumers', regular=True)
        assert (output / 'result').read_text() == 'NATIVE_CONSUMERS_PASS\n'
        clean_domains()
        record('sandboxedCCppGoAndCgoThroughRegularUserDaemon')

        for address, port in zip(['127.0.0.1', '[::1]'], ports):
            url = f'http://{address}:{port}/'
            for kind in ['fetch', 'builtin-fetch']:
                output = build(kind + '-' + str(port), kind=kind, url=url)
                assert output.read_bytes() == payload
        clean_domains()
        record('fixedOutputFilesystemIsolationAndBothIpVersions')
        error = build('strict-noChroot', kind='control', no_chroot=True, expected=1)
        assert "'__noChroot' set" in error and 'ISOLATION_BUILDER_STARTED' not in error
        build('relaxed-noChroot', kind='control', no_chroot=True, mode='relaxed')
        record('existingStrictAndRelaxedPolicy')

        arguments = build_args(kind='stable')
        initial = command(arguments)
        assert initial.returncode == 0, initial.stderr
        checked = command(arguments + ['--check'])
        (work / 'check-mode.log').write_text(checked.stdout + checked.stderr)
        assert checked.returncode == 0, checked.stderr
        clean_domains()
        record('outputRegistrationAndCheckMode')
        build('mapped-host-snapshot', extra=['--option', 'extra-sandbox-paths',
                                            '/declared-host=' + str(outside)])
        build('optional-missing-mapping', extra=['--option', 'extra-sandbox-paths',
                                                 '/optional=/no-such-sandbox-fixture?'])
        escaped = work / 'mapped-link'
        escaped.symlink_to(outside.parent)
        error = build('mapping-symlink-escape', expected=1, extra=['--option', 'extra-sandbox-paths',
                      '/mapped=' + str(escaped) + ' /mapped/file=' + str(outside)])
        assert 'sandbox mapping parent' in error and 'ISOLATION_BUILDER_STARTED' not in error
        clean_domains()
        record('readOnlyHostMappingsAndSymlinkTraversalRejection')
        for feature in ['recursive-nix', 'uid-range']:
            # Admit the request at the scheduler so the backend rejects it.
            start_daemon(features=feature)
            error = build('unsupported-' + feature, expected=1,
                          extra=['--arg', 'requiredFeatures', json.dumps([feature])])
            assert feature + ' is not supported by the OpenBSD sandbox' in error, error
            assert 'ISOLATION_BUILDER_STARTED' not in error
        record('unsupportedRecursiveNixAndUidRangeRejectBeforeBuilder')

        for domains in ['', '0201', '0', '256', '201 invalid']:
            start_daemon(domains)
            error = build('bad-pool-' + domains.replace(' ', '-'), expected=1,
                          extra=['--option', 'sandbox-fallback', 'true'])
            assert 'sandbox-rdomains' in error and 'ISOLATION_BUILDER_STARTED' not in error
            clean_domains()
        record('invalidOrMissingPoolFailsClosedEvenWithFallback')
        start_daemon('201')
        subprocess.run([ifconfig, 'lo201', 'create'], check=True)
        try:
            error = build('administrator-interface', expected=1)
            assert 'no reserved routing domain available' in error
            assert 'ISOLATION_BUILDER_STARTED' not in error
            assert command([ifconfig, 'lo201']).returncode == 0
        finally:
            subprocess.run([ifconfig, 'lo201', 'destroy'], check=True)
        record('administratorInterfacesArePreserved')
        with held_build() as (_, first, _):
            error = build('pool-exhausted', expected=1)
            assert 'no reserved routing domain available' in error
            assert 'ISOLATION_BUILDER_STARTED' not in error
        clean_domains()
        assert not user_processes(first['uid'])
        with held_build(extra=['--debug']) as (_, first, _):
            pass
        clean_domains()
        assert not user_processes(first['uid'])
        record('poolExhaustionAndCancellationCleanup')
        start_daemon()
        with held_build() as (_, first, _):
            second = json.loads(build('concurrent').read_text())
            assert first['domain'] != second['domain'] and first['uid'] != second['uid']
        clean_domains()
        record('concurrentBuildsHaveSeparateUsersAndDomains')

        # Killing a daemon worker bypasses normal cleanup. The next holder of
        # its build-user lock must kill all old processes before reclaiming loN.
        with one_build_user() as uid, held_build() as (client, abandoned, _):
            assert abandoned['uid'] == uid
            worker = abandoned['pid']
            while True:
                parent, uid = map(int, command(['ps', '-p', str(worker), '-o', 'ppid=,uid=']).stdout.split())
                if uid == 0:
                    break
                worker = parent
            assert worker != daemon.pid
            os.kill(worker, signal.SIGKILL)
            assert client.wait(timeout=30) != 0
            assert command([ifconfig, 'lo' + str(abandoned['domain'])]).returncode == 0
            recovered = json.loads(build('abandoned-worker-recovery').read_text())
            assert recovered['uid'] == abandoned['uid']
            assert recovered['domain'] == abandoned['domain']
            assert not user_processes(abandoned['uid'])
        clean_domains()
        record('abruptWorkerDeathRetainsDomainUntilUserRecovery')
        metadata = json.loads(build('ipc-cleanup', kind='ipc').read_text())
        subprocess.run([str(fixtures / 'probe/bin/exec-probe'), 'ipc-removed',
                        *map(str, metadata['ipc'])], check=True)
        clean_domains()
        record('buildUserSysVIPCCleanup')

        metadata = json.loads(build('detached-child', kind='detach').read_text())
        assert not user_processes(metadata['uid'])
        clean_domains()
        error = build('failed-build', kind='failure', expected=1, extra=['--keep-failed'])
        assert 'exit code 42' in error
        kept = re.search(r"keeping build directory ([\"'])(.*?)\1", error)
        assert kept and (Path(kept.group(2)) / 'kept').read_text() == 'kept failure\n', error
        clean_domains()
        error = build('timeout', kind='timeout', expected=1, extra=['--timeout', '5'])
        assert 'timed out' in error
        metadata = json.loads(re.search(r'SANDBOX_METADATA (.+)', error).group(1))
        assert not user_processes(metadata['uid'])
        clean_domains()
        record('DetachedChildFailureKeepFailedAndTimeoutCleanup')
        start_daemon()
        build('daemon-restart', regular=True)
        clean_domains()
        record('daemonRestart')
        assert outside.read_text() == 'public isolation fixture\n'
        assert not Path(str(outside) + '-write').exists()
        assert Path(undeclared).read_text() == 'undeclared store input\n'
        assert (fixtures / 'input').read_text() == 'declared input\n'
        results['result'] = 'passed'
        print('ISOLATION_RESULT ' + json.dumps(results), flush=True)
        print('ISOLATION_RUNTIME_PASS', flush=True)
    finally:
        for client in clients:
            client.send_signal(signal.SIGINT)
            client.wait(timeout=30)
        stop_daemon()
        subprocess.run(['/etc/rc.d/nix_daemon', 'start'], check=True)
        for server in servers:
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join()


if __name__ == '__main__':
    main()
