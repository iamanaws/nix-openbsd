"""Assertions executed by an actual Nix builder, after sandbox setup."""
import ctypes
import errno
import json
import os
from pathlib import Path
import pwd
import signal
import socket
import stat
import subprocess
import time

fixtures = Path(os.environ['fixtures'])
kind = os.environ['kind']
out = Path(os.environ['out'])
library = ctypes.CDLL(None, use_errno=True)
library.getrtable.restype = ctypes.c_int
library.setrtable.argtypes = [ctypes.c_int]
library.setrtable.restype = ctypes.c_int
domain = library.getrtable()
assert os.getresuid() == (os.getuid(),) * 3 and os.getuid() != 0
assert os.getresgid() == (os.getgid(),) * 3 and os.getgid() != 0
assert os.getgroups() == []
assert pwd.getpwuid(os.getuid()).pw_name == 'nixbld'
assert pwd.getpwnam('nixbld').pw_uid == os.getuid()
assert pwd.getpwuid(os.getuid()).pw_gid == os.getgid()

if kind == 'replace-build-dir':
    directory = Path('/tmp/nix-build')
    assert Path.cwd() == directory
    spec = json.loads(os.environ['probeSpec'])
    os.chdir('/')
    directory.rename('/tmp/original')
    if spec['replacement'] == 'symlink':
        directory.symlink_to(spec['target'])
    elif spec['replacement'] == 'directory':
        directory.mkdir()
    else:
        assert spec['replacement'] == 'missing'
    print('FAILED_BUILD_DIRECTORY_REPLACED', flush=True)
    raise SystemExit(42)

assert os.getcwd() == '/build'

outside = os.environ['outside']
Path('/build/escape').symlink_to(outside)
for path in [outside, os.environ['undeclared'], '/build/escape', '/build/../../' + outside.lstrip('/')]:
    try:
        Path(path).read_bytes()
    except FileNotFoundError:
        pass
    else:
        raise AssertionError('read outside sandbox: ' + path)
try:
    Path(outside + '-write').write_text('escape')
except FileNotFoundError:
    pass
else:
    raise AssertionError('write outside sandbox')

dependency = (fixtures / 'input').resolve(strict=True)
assert dependency.read_text() == 'declared input\n'
for operation in [lambda: dependency.write_text('modified'),
                  lambda: dependency.chmod(0o666), lambda: dependency.unlink(),
                  lambda: os.chroot('/'), lambda: os.setresuid(0, 0, 0)]:
    try:
        operation()
    except PermissionError:
        pass
    else:
        raise AssertionError('builder changed a protected input or regained root')
if Path('/declared-host').exists():
    assert Path('/declared-host').read_text() == 'public isolation fixture\n'
    try:
        Path('/declared-host').write_text('modified')
    except PermissionError:
        pass
    else:
        raise AssertionError('mapped host snapshot is writable')
Path('/tmp/writable').write_text('private tmp\n')
Path('/build/writable').write_text('private build\n')
for device in ['/dev/random', '/dev/urandom']:
    with open(device, 'rb') as stream:
        assert len(stream.read(16)) == 16
subprocess.run([fixtures / 'bash/bin/bash', '-euc',
                'read -r line < <(printf "process substitution\\n"); test "$line" = "process substitution"'], check=True)
metadata = {'pid': os.getpid(), 'uid': os.getuid(), 'gid': os.getgid(), 'domain': domain, 'cwd': os.getcwd()}

if kind == 'fetch':
    assert domain == 0
    subprocess.run([fixtures / 'curl/bin/curl', '--noproxy', '*', '--connect-timeout', '3',
                    '--max-time', '10', '-fsS', os.environ['url'], '-o', out], check=True)
else:
    assert domain in [201, 202, 203, 204]
    ctypes.set_errno(0)
    assert library.setrtable(0) == -1 and ctypes.get_errno() == errno.EPERM
    option = int(subprocess.check_output([fixtures / 'probe/bin/exec-probe', 'rtable-option']))
    for family, address, port in zip([socket.AF_INET, socket.AF_INET6], ['127.0.0.1', '::1'],
                                     json.loads(os.environ['ports'])):
        with socket.socket(family, socket.SOCK_STREAM) as connection:
            assert connection.getsockopt(socket.SOL_SOCKET, option) == domain
            try:
                connection.setsockopt(socket.SOL_SOCKET, option, 0)
            except PermissionError:
                pass
            else:
                raise AssertionError('socket left routing domain')
            connection.settimeout(1)
            try:
                connection.connect((address, port))
            except OSError as error:
                assert error.errno in [errno.ECONNREFUSED, errno.ENETUNREACH, errno.EHOSTUNREACH,
                                       errno.ETIMEDOUT], error
            else:
                raise AssertionError('connected to host-domain listener')
        # Binding the host listener's exact address/port proves a separate loopback.
        with socket.socket(family, socket.SOCK_STREAM) as listener, \
                socket.socket(family, socket.SOCK_STREAM) as client:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind((address, port))
            listener.listen()
            client.settimeout(2)
            client.connect((address, port))
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(2)
                connection.sendall(b'private loopback')
                assert client.recv(64) == b'private loopback'
                # Leave TIME_WAIT on the ephemeral client port. OpenBSD
                # rejects reuse of a fixed port by another UID while an old
                # connection owns it, even with SO_REUSEADDR.
                client.shutdown(socket.SHUT_WR)
                assert connection.recv(1) == b''
            assert client.recv(1) == b''
        with socket.socket(family, socket.SOCK_DGRAM) as receiver, \
                socket.socket(family, socket.SOCK_DGRAM) as sender:
            receiver.bind((address, 0))
            receiver.settimeout(2)
            sender.sendto(b'private datagram', receiver.getsockname())
            assert receiver.recv(64) == b'private datagram'
    if kind.startswith('limit-'):
        from limits import inspect_limits
        inspect_limits(fixtures, kind, metadata, json.loads(os.environ['probeSpec']))
    if kind == 'ipc':
        metadata['ipc'] = json.loads(subprocess.check_output([fixtures / 'probe/bin/exec-probe', 'ipc-create']))
    if kind == 'ipc-owner':
        metadata['ipc'] = json.loads(subprocess.check_output([
            fixtures / 'probe/bin/exec-probe', 'ipc-fixture', '660', str(os.getgid())]))
    if kind == 'ipc-peer':
        subprocess.run([fixtures / 'probe/bin/exec-probe', 'ipc-denied',
                        *map(str, json.loads(os.environ['probeSpec']))], check=True)
    if kind == 'boundaries':
        from boundaries import inspect_boundaries
        inspect_boundaries(fixtures, metadata, json.loads(os.environ['probeSpec']))
    if kind == 'storm':
        import resource
        resource.setrlimit(resource.RLIMIT_NPROC, (32, 32))
        metadata['ipc'] = json.loads(subprocess.check_output([fixtures / 'probe/bin/exec-probe', 'ipc-create']))
        read, write = os.pipe()
        metadata['children'] = []
        for _ in range(8):
            child = os.fork()
            if child == 0:
                os.close(read)
                os.setsid()
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                if os.fork() == 0:
                    os.setsid()
                os.write(write, b'x')
                os.close(write)
                for fd in [0, 1, 2]:
                    os.close(fd)
                while True:
                    time.sleep(1)
            metadata['children'].append(child)
        os.close(write)
        ready = b''
        while len(ready) < 16:
            data = os.read(read, 16 - len(ready))
            assert data, 'descendants did not start'
            ready += data
        os.close(read)
    if kind in ['detach', 'timeout']:
        child = os.fork()
        if child == 0:
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            os.close(1)
            os.close(2)
            while True:
                time.sleep(1)
        metadata['child'] = child
    print('SANDBOX_METADATA ' + json.dumps(metadata), flush=True)
    if kind in ['hold', 'timeout', 'storm', 'ipc-owner']:
        time.sleep(120)
    if kind == 'failure':
        Path('/build/kept').write_text('kept failure\n')
        raise SystemExit(42)
    if kind == 'file-flags':
        spec = json.loads(os.environ['probeSpec'])
        flag = getattr(stat, spec['flag'])
        target = Path('/build') if spec['fail'] else out
        target.mkdir(exist_ok=True)
        (target / 'flagged').write_text('flagged fixture\n')
        os.chflags(target / 'flagged', flag)
        os.chflags(target, flag)
        print('BUILD_FILE_FLAGS_SET', flush=True)
        raise SystemExit(42 if spec['fail'] else 0)
    out.write_text('stable output\n' if kind == 'stable' else json.dumps(metadata) + '\n')
