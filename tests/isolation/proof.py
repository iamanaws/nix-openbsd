"""Test-only OpenBSD isolation experiments; this is not a Nix sandbox backend."""
import ctypes
import errno
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pwd
import resource
import secrets
import selectors
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time


def libc():
    library = ctypes.CDLL(None, use_errno=True)
    library.setrtable.argtypes = [ctypes.c_int]
    library.setrtable.restype = ctypes.c_int
    library.getrtable.restype = ctypes.c_int
    return library


def enter():
    root, uid, gid, table, *command = sys.argv[2:]
    assert os.getuid() == 0
    library = libc()
    if int(table) >= 0:
        assert library.setrtable(int(table)) == 0, ctypes.get_errno()
    if root != '-':
        os.chroot(root)
        os.chdir('/')
    os.setgroups([])
    os.setresgid(int(gid), int(gid), int(gid))
    os.setresuid(int(uid), int(uid), int(uid))
    library.closefrom(3)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.execv(command[0], command)


def connect(address, port, domain=0):
    family = socket.AF_INET6 if ':' in address else socket.AF_INET
    with socket.socket(family, socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        connection.connect((address, port))
        connection.sendall(b'GET / HTTP/1.0\r\n\r\n')
        response = b''
        while b'\r\n\r\n' not in response:
            chunk = connection.recv(4096)
            assert chunk and len(response) < 8192
            response += chunk
        assert b'200' in response
        assert f'X-Isolation-Domain: {domain}\r\n'.encode() in response


def loopback():
    """Listen on the same addresses/ports as domain 0, inside domain 100."""
    ready, port4, port6 = sys.argv[2:]
    assert os.getuid() != 0 and libc().getrtable() == 100
    with selectors.DefaultSelector() as selector:
        for family, address, port in [(socket.AF_INET, '127.0.0.1', port4),
                                      (socket.AF_INET6, '::1', port6)]:
            listener = socket.socket(family, socket.SOCK_STREAM)
            if family == socket.AF_INET6:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            listener.bind((address, int(port)))
            listener.listen()
            selector.register(listener, selectors.EVENT_READ)
        Path(ready).write_text('ready\n')
        while True:
            for key, _ in selector.select():
                connection, _ = key.fileobj.accept()
                with connection:
                    connection.settimeout(2)
                    connection.recv(4096)
                    connection.sendall(b'HTTP/1.0 200 OK\r\nX-Isolation-Domain: 100\r\nContent-Length: 2\r\n\r\nOK')


def inner():
    fixtures, outside, port4, port6, blocked = sys.argv[2:]
    fixtures = Path(fixtures)
    isolated = blocked != 'no'
    network_blocked = blocked == 'yes'
    assert os.getuid() != 0 and os.geteuid() == os.getuid()
    assert not Path(outside).exists()
    for escape in [outside, '/build/escape', '/build/../../' + outside.lstrip('/')]:
        try:
            Path(escape).read_bytes()
        except FileNotFoundError:
            pass
        else:
            raise AssertionError('Readable outside path: ' + escape)
    try:
        Path(outside + '-write').write_text('escape')
    except FileNotFoundError:
        pass
    else:
        raise AssertionError('Write outside chroot succeeded')
    dependency = (fixtures / 'input').resolve(strict=True)
    assert dependency.read_text() == 'declared input\n'
    for operation in [lambda: dependency.write_text('modified'),
                      lambda: dependency.chmod(0o666), lambda: dependency.unlink()]:
        try:
            operation()
        except PermissionError:
            pass
        else:
            raise AssertionError('Read-only input was writable')
    Path('/build/writable').write_text('build output\n')
    for operation in [lambda: os.chroot('/'), lambda: os.setresuid(0, 0, 0)]:
        try:
            operation()
        except PermissionError:
            pass
        else:
            raise AssertionError('Builder regained privilege')
    library = libc()
    assert library.getrtable() == (100 if isolated else 0)
    if isolated:
        ctypes.set_errno(0)
        assert library.setrtable(0) == -1 and ctypes.get_errno() == errno.EPERM
        option = int(subprocess.check_output([fixtures / 'probe/bin/exec-probe', 'rtable-option']))
        for family in [socket.AF_INET, socket.AF_INET6]:
            with socket.socket(family, socket.SOCK_STREAM) as connection:
                assert connection.getsockopt(socket.SOL_SOCKET, option) == 100
                try:
                    connection.setsockopt(socket.SOL_SOCKET, option, 0)
                except PermissionError:
                    pass
                else:
                    raise AssertionError('Socket escaped routing domain')
    for address, port in [('127.0.0.1', int(port4)), ('::1', int(port6))]:
        try:
            connect(address, port, domain=100 if blocked == 'local' else 0)
        except OSError as error:
            assert network_blocked and error.errno in [errno.ECONNREFUSED, errno.ENETUNREACH,
                                               errno.EHOSTUNREACH, errno.ETIMEDOUT], error
        else:
            assert not network_blocked, 'Network isolation failed'
    print('CHROOT_AND_NETWORK_CHECK_PASS', flush=True)


def main():
    assert os.getuid() == 0
    fixtures = Path(sys.argv[1]).resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix='openbsd-isolation.', dir='/var/tmp'))
    work.chmod(0o755)
    print('Guest isolation logs: ' + str(work), flush=True)
    user = next(user for user in pwd.getpwall() if user.pw_name.startswith('nixbld') and user.pw_uid != 0)
    python = str(fixtures / 'python3/bin/python3')
    script = str(fixtures / 'tests/proof.py')
    outside = work / 'outside/readable'
    outside.parent.mkdir(mode=0o755)
    outside.write_text('public isolation fixture\n')
    outside.chmod(0o644)
    allowed = work / 'allowed'
    allowed.mkdir(mode=0o777)
    allowed.chmod(0o777)
    results = {}

    def record(name):
        results[name] = 'passed'
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print('PASS ' + name, flush=True)

    def command(argv, name, expected=0, timeout=240):
        with (work / (name + '.log')).open('w') as log:
            result = subprocess.run(list(map(str, argv)), stdin=subprocess.DEVNULL,
                                    stdout=log, stderr=subprocess.STDOUT,
                                    timeout=timeout, env=os.environ | {'NIX_REMOTE': 'daemon'})
        if result.returncode != expected:
            print((work / (name + '.log')).read_text(errors='replace')[-4000:], flush=True)
        assert result.returncode == expected, (name, result.returncode, str(work / (name + '.log')))

    def worker(root, table, command_args):
        return [python, '-B', script, '--enter', str(root), str(user.pw_uid), str(user.pw_gid),
                str(table), *map(str, command_args)]

    probe = str(fixtures / 'probe/bin/exec-probe')
    for mode in ['unveil', 'inherited']:
        command(worker('-', -1, [probe, mode, allowed, outside]), 'exec-' + mode)
    record('unveilResetAndPinnedExecpromisesInheritance')
    route = str(fixtures / 'route/bin/route')
    command(worker('-', -1, [route, '-n', 'show']), 'route-control')
    command(worker('-', -1, [probe, 'command', allowed, outside, route, '-n', 'show']),
            'route-inherited-pledge', expected=-signal.SIGABRT)
    assert 'assertion' not in (work / 'route-inherited-pledge.log').read_text().lower()
    record('inheritedPledgeBreaksNativeUtility')

    payload = b'fixed-output isolation fixture\n'

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('X-Isolation-Domain', '0')
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    class IPv6Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6

    servers = [ThreadingHTTPServer(('127.0.0.1', 0), Handler), IPv6Server(('::1', 0), Handler)]
    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in servers]
    for thread in threads:
        thread.start()
    ports = [server.server_port for server in servers]
    created_domain = False
    private_server = None
    try:
        for address, port in zip(['127.0.0.1', '::1'], ports):
            connect(address, port)
        nix = shutil.which('nix-build')
        assert nix

        def nix_command(kind, mode, name, url='', regular_user=False):
            settings = [] if regular_user else ['--option', 'sandbox', mode,
                                                '--option', 'sandbox-fallback', 'true']
            argv = [nix, str(fixtures / 'tests/build.nix'), '--argstr', 'fixtures', str(fixtures),
                    '--argstr', 'nonce', secrets.token_hex(8), '--argstr', 'kind', kind,
                    '--argstr', 'outside', str(outside), '--argstr', 'url', url,
                    '--argstr', 'hash', hashlib.sha256(payload).hexdigest(),
                    *settings,
                    '--no-out-link', '--no-substitute', '--max-jobs', '1', '--cores', '2']
            if regular_user:
                argv = ['su', '-l', 'bestie', '-c', 'env NIX_REMOTE=daemon ' + shlex.join(argv)]
            result = subprocess.run(argv, capture_output=True, text=True, timeout=600,
                                    env=os.environ | {'NIX_REMOTE': 'daemon'})
            (work / (name + '.log')).write_text(result.stdout + result.stderr)
            return result

        for kind, mode in [('control', 'true'), ('control', 'relaxed'), ('fetch', 'true')]:
            result = nix_command(kind, mode, 'unsupported-' + kind + '-' + mode)
            assert result.returncode != 0
            assert 'sandboxing builds is not supported on this platform' in result.stderr
            assert 'ISOLATION_BUILDER_STARTED' not in result.stderr
        record('nixUnsupportedSandboxRejectsBeforeBuilderEvenWithFallback')
        result = nix_command('control', 'false', 'ordinary-control')
        assert result.returncode == 0, result.stderr
        output = Path(result.stdout.strip().splitlines()[-1])
        lines = output.read_text().splitlines()
        assert lines[0] == 'public isolation fixture' and int(lines[1]) != 0
        record('unsandboxedBuildReadsPublicOutsideFixture')
        for address, port in zip(['127.0.0.1', '[::1]'], ports):
            result = nix_command('fetch', 'relaxed', 'fetch-' + str(port), f'http://{address}:{port}/')
            assert result.returncode == 0, result.stderr
            assert Path(result.stdout.strip().splitlines()[-1]).read_bytes() == payload
        record('fixedOutputFetchesBothIpVersions')
        result = nix_command('consumers', 'false', 'regular-user-consumers', regular_user=True)
        assert result.returncode == 0, result.stderr
        assert (Path(result.stdout.strip().splitlines()[-1]) / 'result').read_text() == 'NATIVE_CONSUMERS_PASS\n'
        record('regularUserDaemonCCppGoAndCgo')

        root = work / 'root'
        store = root / 'nix/store'
        store.mkdir(parents=True)
        store.chmod(0o1777)
        closure = subprocess.check_output(['nix-store', '-qR', str(fixtures)], text=True).splitlines()
        linked, copied = 0, 0

        def copy_file(source, destination):
            nonlocal linked, copied
            try:
                os.link(source, destination)
                linked += 1
            except OSError as error:
                assert error.errno in [errno.EXDEV, errno.EPERM], error
                shutil.copyfile(source, destination)
                os.chmod(destination, os.stat(source).st_mode & 0o777)
                copied += 1
            return destination

        for item in closure:
            source_path = Path(item)
            destination = root / source_path.relative_to('/')
            if source_path.is_dir() and not source_path.is_symlink():
                shutil.copytree(source_path, destination, symlinks=True, copy_function=copy_file)
            elif source_path.is_symlink():
                destination.symlink_to(os.readlink(source_path))
            else:
                copy_file(source_path, destination)
        print(f'Chroot inputs: {len(closure)} paths, {linked} linked files, {copied} copied files', flush=True)
        (root / 'usr/libexec').mkdir(parents=True)
        loader = (fixtures / 'cc/nix-support/dynamic-linker').read_text().strip()
        assert loader.startswith('/nix/store/') and (root / loader.lstrip('/')).is_file()
        (root / 'usr/libexec/ld.so').symlink_to(loader)
        (root / 'bin').mkdir()
        (root / 'bin/sh').symlink_to(fixtures / 'bash/bin/bash')
        (root / 'dev').mkdir()
        for name in ['null', 'zero', 'random', 'urandom']:
            os.mknod(root / ('dev/' + name), stat.S_IFCHR | 0o666, os.stat('/dev/' + name).st_rdev)
            (root / ('dev/' + name)).chmod(0o666)
        (root / 'tmp').mkdir(mode=0o1777)
        (root / 'tmp').chmod(0o1777)
        build = root / 'build'
        build.mkdir()
        os.chown(build, user.pw_uid, user.pw_gid)
        (build / 'escape').symlink_to(outside)
        inner_args = [python, '-B', script, '--inner', str(fixtures), str(outside),
                      str(ports[0]), str(ports[1])]
        command(worker(root, 0, inner_args + ['no']), 'chroot-with-network')
        assert not Path(str(outside) + '-write').exists()
        record('chrootFilesystemAndNetworkControlAcrossExec')
        ifconfig = str(fixtures / 'ifconfig/bin/ifconfig')
        check = subprocess.run([ifconfig, 'lo100'], capture_output=True)
        assert check.returncode != 0, 'The private test routing domain already exists'
        command([ifconfig, 'vether0', 'create'], 'create-vether')
        command([ifconfig, 'vether0', 'rdomain', '100'], 'create-domain')
        created_domain = True
        command([ifconfig, 'lo100', 'inet', '127.0.0.1/8', 'up'], 'loopback4')
        command([ifconfig, 'lo100', 'inet6', '::1/128', 'alias'], 'loopback6')
        command(worker(root, 100, inner_args + ['yes']), 'chroot-isolated-network')
        record('routingDomainBlocksBothIpVersionsAndCannotBeReset')
        with (work / 'private-loopback.log').open('w') as log:
            private_server = subprocess.Popen(worker(root, 100, [python, '-B', script, '--loopback',
                '/build/private-ready', str(ports[0]), str(ports[1])]),
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
        for _ in range(100):
            assert private_server.poll() is None, (work / 'private-loopback.log').read_text()
            if (build / 'private-ready').exists():
                break
            time.sleep(.1)
        assert (build / 'private-ready').read_text() == 'ready\n'
        command(worker(root, 100, inner_args + ['local']), 'private-loopback-control')
        for address, port in zip(['127.0.0.1', '::1'], ports):
            connect(address, port)
        record('privateLoopbackWorksWithSamePortsInBothDomains')
        command(worker(root, 100, [str(fixtures / 'bash/bin/bash'), str(fixtures / 'tests/consumers.sh'),
                                  str(fixtures), '/build/consumers']), 'isolated-consumers', timeout=600)
        assert (build / 'consumers/result').read_text() == 'NATIVE_CONSUMERS_PASS\n'
        assert (fixtures / 'input').read_text() == 'declared input\n'
        for address, port in zip(['127.0.0.1', '::1'], ports):
            connect(address, port)
        record('isolatedCCppGoAndCgoWithOutsideControlsIntact')
        record('result')
        print('ISOLATION_RESULT ' + json.dumps(results), flush=True)
        print('ISOLATION_RUNTIME_PASS', flush=True)
    finally:
        if private_server is not None:
            private_server.terminate()
            private_server.wait(timeout=10)
        if created_domain:
            subprocess.run([str(fixtures / 'ifconfig/bin/ifconfig'), 'vether0', 'destroy'], check=True)
            subprocess.run([str(fixtures / 'ifconfig/bin/ifconfig'), 'lo100', 'destroy'], check=True)
        for server in servers:
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join()


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--enter':
        enter()
    elif len(sys.argv) > 1 and sys.argv[1] == '--inner':
        inner()
    elif len(sys.argv) > 1 and sys.argv[1] == '--loopback':
        loopback()
    else:
        main()
