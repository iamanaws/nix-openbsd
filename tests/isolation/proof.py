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
import resource
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

    def start_daemon(domains='201 202 203 204', features='', inherited_limits=None):
        nonlocal daemon, daemon_log
        stop_daemon()
        Path(env['NIX_DAEMON_SOCKET_PATH']).unlink(missing_ok=True)
        daemon_log = (work / ('daemon-' + secrets.token_hex(4) + '.log')).open('w')
        def set_limits():
            for number, value in inherited_limits.items():
                resource.setrlimit(number, value)
        daemon = subprocess.Popen([daemon_binary, '--option', 'sandbox', 'true',
                                   '--option', 'sandbox-fallback', 'false',
                                   '--option', 'sandbox-rdomains', domains,
                                   '--option', 'system-features', features,
                                   '--option', 'trusted-users', 'root',
                                   '--option', 'hashed-mirrors', '',
                                   '--option', 'max-jobs', '2', '--option', 'cores', '2'],
                                  env=env | {'NIX_REMOTE': 'local'}, stdin=subprocess.DEVNULL,
                                  stdout=daemon_log, stderr=subprocess.STDOUT,
                                  preexec_fn=set_limits if inherited_limits else None)
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
        inputs = fixtures if kind in ['consumers', 'exec-policies'] else (fixtures / 'builder').resolve(strict=True)
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

    @contextmanager
    def build_class(capabilities):
        stop_daemon()
        config = Path('/etc/login.conf')
        original = config.read_text()
        def install(text):
            config.write_text(text)
            command([fixtures / 'cap_mkdb/bin/cap_mkdb', config], check=True)
        lines = [line for line in original.splitlines()
                 if 'nixbld' not in line.split(':', 1)[0].split('|')]
        assert len(lines) < len(original.splitlines()), 'missing nixbld login class'
        if capabilities is not None:
            lines.insert(0, 'nixbld:' + capabilities)
        try:
            install('\n'.join(lines) + '\n')
            yield
        finally:
            stop_daemon()
            install(original)

    @contextmanager
    def primary_group(name, gid):
        # Rebuild both native password databases; changing the text file alone
        # would leave getpwnam(3) using the old credentials.
        stop_daemon()
        passwd = Path('/etc/master.passwd')
        original = passwd.read_text()

        def install(text):
            temporary = Path('/etc/nix-isolation-passwd-' + secrets.token_hex(8))
            try:
                with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as stream:
                    stream.write(text)
                command([fixtures / 'pwd_mkdb/bin/pwd_mkdb', '-p', temporary], check=True)
            finally:
                temporary.unlink(missing_ok=True)

        entries = [line.split(':') for line in original.splitlines()]
        for entry in entries:
            if entry[0] == name:
                entry[3] = str(gid)
        try:
            install(''.join(':'.join(entry) + '\n' for entry in entries))
            yield
        finally:
            stop_daemon()
            install(original)

    clean_domains()
    for thread in threads:
        thread.start()
    subprocess.run(['/etc/rc.d/nix_daemon', 'stop'], check=True)
    try:
        library = str(fixtures / 'libcxx/lib')
        subprocess.run([sys.executable, '-B', fixtures / 'tests/helper-policies.py',
                        '--cxx', fixtures / 'cc/bin/c++',
                        '--shell', fixtures / 'bash/bin/bash',
                        '--template', fixtures / 'tests/helper-policies.cc',
                        '--descriptor-source', fixtures / 'descriptorSource',
                        '--sandbox-patch', fixtures / 'sandboxPatch',
                        '--pty-patch', fixtures / 'ptyPatch'], check=True,
                       env=os.environ | {'LDFLAGS': '-L' + library + ' -Wl,-rpath,' + library})
        record('focusedHelperUnveilAndPledgeCompatibility')
        subprocess.run([sys.executable, '-B', fixtures / 'tests/build-dir-cleanup.py',
                        '--cxx', fixtures / 'cc/bin/c++',
                        '--template', fixtures / 'tests/build-dir-cleanup.cc',
                        '--builder-source', fixtures / 'builderSource',
                        '--patch', fixtures / 'sandboxPatch'], check=True,
                       env=os.environ | {'LDFLAGS': '-L' + library + ' -Wl,-rpath,' + library})
        record('focusedFailedBuildDirectoryCleanup')
        subprocess.run([sys.executable, '-B', fixtures / 'tests/file-flags.py',
                        '--cxx', fixtures / 'cc/bin/c++',
                        '--template', fixtures / 'tests/file-flags.cc',
                        '--patch', fixtures / 'sandboxPatch'], check=True,
                       env=os.environ | {'LDFLAGS': '-L' + library + ' -Wl,-rpath,' + library})
        record('focusedBuildFileFlags')
        subprocess.run([sys.executable, '-B', fixtures / 'tests/kill-user.py',
                        '--cxx', fixtures / 'cc/bin/c++',
                        '--template', fixtures / 'tests/kill-user.cc',
                        '--process-source', fixtures / 'processSource'], check=True,
                       env=os.environ | {'LDFLAGS': '-L' + library + ' -Wl,-rpath,' + library})
        record('focusedProcessKillHelper')
        start_daemon()
        output = build('unsandboxed-control', kind='control', mode='false')
        lines = output.read_text().splitlines()
        assert lines[0] == 'public isolation fixture' and int(lines[1]) != 0
        assert int(lines[2]) == grp.getgrnam('nixbld').gr_gid
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

        output = build('inherited-exec-policies', kind='exec-policies', regular=True)
        policy_results = json.loads((output / 'results.json').read_text())
        assert len(policy_results) == 22, policy_results
        clean_domains()
        record('inheritedPledgeUnveilAndNativeToolCompatibility')

        limits = json.loads(build('default-resource-limits', kind='limits', regular=True).read_text())
        assert limits['nproc'] == [512, 1024] and limits['nofile'] == [512, 1024], limits
        for caps, expected in [
                ('maxproc-cur=24:maxproc-max=32:openfiles-cur=48:openfiles-max=64:'
                 'datasize-cur=1G:datasize-max=2G:tc=default',
                 {'nproc': [24, 32], 'nofile': [48, 64], 'data': [1 << 30, 2 << 30]}),
                ('maxproc=32:maxproc-cur=24:maxproc-max=24:'
                 'openfiles=64:openfiles-cur=48:openfiles-max=48:'
                 'datasize=2G:datasize-cur=1G:datasize-max=1G:tc=default',
                 {'nproc': [32, 32], 'nofile': [64, 64], 'data': [2 << 30, 2 << 30]})]:
            with build_class(caps):
                start_daemon()
                actual = json.loads(build('class-precedence', kind='limits', regular=True).read_text())
                assert actual == expected, actual
        record('nativeLoginClassLimitsAndCapabilityPrecedence')

        caps = ('maxproc-cur=24:maxproc-max=32:openfiles-cur=48:openfiles-max=64:'
                'datasize-cur=1G:datasize-max=2G:tc=default')
        expected = {'nproc': [24, 32], 'nofile': [48, 64], 'data': [1 << 30, 2 << 30]}
        extra = ['--argstr', 'probeSpec', json.dumps(expected)]
        with build_class(caps):
            start_daemon()
            for kind, field, error in [('limit-processes', 'processExhaustion', 'EAGAIN'),
                                       ('limit-fds', 'descriptorExhaustion', 'EMFILE'),
                                       ('limit-data', 'dataExhaustion', 'ENOMEM')]:
                metadata = json.loads(build(kind, kind=kind, regular=True, extra=extra).read_text())
                assert metadata[field] == error and not user_processes(metadata['uid']), metadata
                clean_domains()
            with held_build(kind='limit-hold', extra=extra) as (_, metadata, _):
                assert metadata['processExhaustion'] == 'EAGAIN'
                assert metadata['descriptorExhaustion'] == 'EMFILE'
            clean_domains()
            assert not user_processes(metadata['uid'])
            command([fixtures / 'probe/bin/exec-probe', 'ipc-removed', *map(str, metadata['ipc'])], check=True)
        record('hardResourceCeilingsExhaustionAndCancellationCleanup')

        start_daemon(inherited_limits={resource.RLIMIT_NPROC: (64, 64),
                                       resource.RLIMIT_NOFILE: (128, 128),
                                       resource.RLIMIT_DATA: (1 << 30, 1 << 30)})
        actual = json.loads(build('inherited-hard-limits', kind='limits', regular=True).read_text())
        assert actual == {'nproc': [64, 64], 'nofile': [128, 128], 'data': [1 << 30, 1 << 30]}, actual
        record('buildUserClassCannotRelaxInheritedHardLimits')

        for caps, message in [('maxproc=invalid:tc=default', 'invalid resource limit'),
                              ('openfiles-cur=64:openfiles-max=32:tc=default', 'exceeds its maximum'),
                              ('datasize=invalid:tc=default', 'invalid resource limit'),
                              (None, 'cannot load login class')]:
            with build_class(caps):
                start_daemon()
                error = build('invalid-resource-class', expected=1)
                assert message in error and 'ISOLATION_BUILDER_STARTED' not in error, error
        record('invalidOrMissingResourceClassRejectsBeforeBuilder')

        with build_class('maxproc-cur=512:maxproc-max=1024:openfiles-cur=512:openfiles-max=1024:'
                         'datasize=2G:tc=default'):
            start_daemon()
            output = build('memory-limited-native-consumers', kind='consumers', regular=True)
            assert (output / 'result').read_text() == 'NATIVE_CONSUMERS_PASS\n'
            clean_domains()
        start_daemon()
        record('sandboxedNativeConsumersWithFiniteDataLimit')

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
        source_parent = work / 'source-parent'
        source_parent.symlink_to(outside.parent)
        error = build('mapping-source-parent-symlink', expected=1,
                      extra=['--option', 'extra-sandbox-paths',
                             '/declared-host=' + str(source_parent / outside.name)])
        assert 'symlink' in error and 'ISOLATION_BUILDER_STARTED' not in error, error
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
        victim = work / 'keep-failed-private'
        victim.write_text('private cleanup fixture\n')
        victim.chmod(0o600)
        for replacement in ['symlink', 'directory', 'missing']:
            spec = json.dumps({'replacement': replacement, 'target': str(victim)})
            error = build('replaced-build-dir-' + replacement, kind='replace-build-dir', expected=1,
                          extra=['--keep-failed', '--option', 'sandbox-build-dir', '/tmp/nix-build',
                                 '--argstr', 'probeSpec', spec])
            assert 'FAILED_BUILD_DIRECTORY_REPLACED' in error, error
            assert 'it was removed or replaced' in error, error
            assert victim.stat().st_mode & 0o7777 == 0o600
            assert victim.read_text() == 'private cleanup fixture\n'
            assert 'note: keeping build directory' not in error, error
            clean_domains()
        record('replacedFailedBuildDirectoriesAreDiscarded')
        for flag in ['UF_IMMUTABLE', 'UF_APPEND']:
            spec = json.dumps({'flag': flag, 'fail': False})
            output = build('flagged-output-' + flag, kind='file-flags',
                           extra=['--argstr', 'probeSpec', spec])
            assert output.stat().st_flags == 0 and (output / 'flagged').stat().st_flags == 0
            assert (output / 'flagged').read_text() == 'flagged fixture\n'
            spec = json.dumps({'flag': flag, 'fail': True})
            for keep in [False, True]:
                error = build('flagged-failure-' + flag + str(keep), kind='file-flags', expected=1,
                              extra=['--argstr', 'probeSpec', spec] + (['--keep-failed'] if keep else []))
                assert 'BUILD_FILE_FLAGS_SET' in error and 'exit code 42' in error, error
                drv = re.search(r"building '([^']+\.drv)'", error)
                assert drv and not Path(drv.group(1) + '.chroot').exists(), error
                if keep:
                    kept = re.search(r"keeping build directory ([\"'])(.*?)\1", error)
                    assert kept, error
                    directory = Path(kept.group(2))
                    assert directory.stat().st_flags == 0 and (directory / 'flagged').stat().st_flags == 0
                    assert (directory / 'flagged').read_text() == 'flagged fixture\n'
                clean_domains()
        record('BuildFileFlagsDoNotPreventOutputOrFailureCleanup')
        error = build('timeout', kind='timeout', expected=1, extra=['--timeout', '5'])
        assert 'timed out' in error
        metadata = json.loads(re.search(r'SANDBOX_METADATA (.+)', error).group(1))
        assert not user_processes(metadata['uid'])
        clean_domains()
        record('DetachedChildFailureKeepFailedAndTimeoutCleanup')

        output = build('inherited-descriptor-audit', kind='fd-audit', regular=True)
        assert output.read_text() == 'FD_AUDIT_PASS\n'
        probe = fixtures / 'probe/bin/exec-probe'
        ipc = {}
        try:
            for name, mode, gid in [('private', '600', 0), ('public', '666', 0),
                                    ('group', '660', grp.getgrnam('nixbld').gr_gid)]:
                ipc[name] = json.loads(command([probe, 'ipc-fixture', mode, str(gid)], check=True).stdout)
            token = secrets.token_hex(16)
            spec = ipc | {'hostPid': os.getpid(), 'token': token}
            with held_build(kind='boundaries', extra=['--argstr', 'probeSpec', json.dumps(spec)]) as (_, metadata, _):
                code = f'''import ctypes, errno, os, socket
library = ctypes.CDLL(None, use_errno=True)
assert os.getuid() != 0 and library.getrtable() == 0
assert library.setrtable({metadata['domain']}) == 0
for family, address, port in zip([socket.AF_INET, socket.AF_INET6], ['127.0.0.1', '::1'], {metadata['listenerPorts']!r}):
    with socket.socket(family, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect((address, port))
        connection.sendall({token.encode()!r})
        assert connection.recv(128) == {token.encode()!r}
assert library.setrtable(0) == -1 and ctypes.get_errno() == errno.EPERM
print('DOMAIN_ZERO_JOIN_PASS')
'''
                joined = command(['su', '-l', 'bestie', '-c', shlex.join([
                    str(fixtures / 'python3/bin/python3'), '-B', '-c', code])])
                (work / 'domain-zero-join.log').write_text(joined.stdout + joined.stderr)
                assert joined.returncode == 0 and 'DOMAIN_ZERO_JOIN_PASS' in joined.stdout, joined.stderr
                results['boundaryLimits'] = metadata['boundaries'] | {
                    'domainZeroHostCanJoin': True, 'inheritedFds': []}
            clean_domains()
            command([probe, 'ipc-removed', *map(str, metadata['ipc'])], check=True)
            for name, identifiers in ipc.items():
                command([probe, 'ipc-verify', 'builder' if name == 'public' else 'host',
                         *map(str, identifiers)], check=True)
            record('sharedProcessAndIpcPermissionsAndNoInheritedDescriptors')
            record('domainZeroUnprivilegedHostCanReachPrivateLoopback')
        finally:
            for identifiers in ipc.values():
                command([probe, 'ipc-destroy', *map(str, identifiers)], check=True)

        with held_build(kind='ipc-owner') as (_, owner, _):
            peer = json.loads(build('cross-build-group-ipc', kind='ipc-peer', regular=True,
                                   extra=['--argstr', 'probeSpec', json.dumps(owner['ipc'])]).read_text())
            assert peer['uid'] != owner['uid'] and peer['gid'] != owner['gid']
            assert peer['gid'] == pwd.getpwuid(peer['uid']).pw_gid
            assert owner['gid'] == pwd.getpwuid(owner['uid']).pw_gid
            assert peer['gid'] != grp.getgrnam('nixbld').gr_gid
            command([probe, 'ipc-verify', 'host', *map(str, owner['ipc'])], check=True)
        clean_domains()
        command([probe, 'ipc-removed', *map(str, owner['ipc'])], check=True)
        record('concurrentBuildsCannotAccessEachOthersGroupIpc')

        with one_build_user() as uid:
            account = pwd.getpwuid(uid)
            other = next(pwd.getpwnam(name) for name in grp.getgrnam('nixbld').gr_mem
                         if pwd.getpwnam(name).pw_uid != uid)
            for gid, message in [(0, 'needs a non-root primary group'),
                                 (grp.getgrnam('nixbld').gr_gid, 'needs a non-root primary group'),
                                 (other.pw_gid, 'share primary group')]:
                with primary_group(account.pw_name, gid):
                    start_daemon()
                    error = build('invalid-primary-group-' + str(gid), expected=1)
                    assert message in error and 'ISOLATION_BUILDER_STARTED' not in error, error
        start_daemon()
        record('rootSharedAndDuplicatePrimaryGroupsRejectBeforeBuilder')

        start_daemon('201')
        with one_build_user() as uid:
            for attempt in range(4):
                with held_build(kind='storm', extra=['--debug'] if attempt % 2 else []) as (_, metadata, _):
                    assert metadata['uid'] == uid and metadata['domain'] == 201
                    assert len(metadata['children']) == 8
                clean_domains()
                assert not user_processes(uid)
                command([probe, 'ipc-removed', *map(str, metadata['ipc'])], check=True)
        record('repeatedCancellationOfDetachedDescendantsAndIpc')
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
