"""Native APIs needed by build tools, exercised within a regular build UID."""
import array
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
import ctypes
import fcntl
import json
import mmap
import multiprocessing
import os
from pathlib import Path
import pwd
import socket
import sqlite3
import subprocess
import tempfile


def square(value):
    return value * value


def main():
    assert os.getuid() != 0 and os.getgroups() == []
    assert pwd.getpwuid(os.getuid()).pw_name == 'nixbld'
    library = ctypes.CDLL(None)
    assert library.getrtable() in [201, 202, 203, 204]
    results = {}
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert list(pool.map(square, range(4))) == [0, 1, 4, 9]
    for method in ['fork', 'spawn', 'forkserver']:
        context = multiprocessing.get_context(method)
        with ProcessPoolExecutor(max_workers=2, mp_context=context) as pool:
            assert list(pool.map(square, range(4))) == [0, 1, 4, 9]
        results['multiprocessing-' + method] = 'passed'
    with tempfile.TemporaryFile() as file:
        file.write(b'mapped fixture')
        file.flush()
        with mmap.mmap(file.fileno(), 0) as mapped:
            assert mapped[:] == b'mapped fixture'
        fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # A different open description must observe the parent's lock.
        path = Path('locked')
        path.write_text('locked fixture')
        with path.open('r') as locked:
            fcntl.flock(locked, fcntl.LOCK_EX)
            child = subprocess.run(['python3', '-c',
                'import fcntl; f=open("locked"); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)'],
                capture_output=True, text=True)
            assert child.returncode != 0 and 'BlockingIOError' in child.stderr, child.stderr
        left, right = socket.socketpair()
        with left, right:
            left.sendmsg([b'fd'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                    array.array('i', [file.fileno()]))])
            data, messages, _, _ = right.recvmsg(2, socket.CMSG_SPACE(array.array('i').itemsize))
            assert data == b'fd' and len(messages) == 1
            level, kind, payload = messages[0]
            assert level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS
            received = array.array('i')
            received.frombytes(payload[:array.array('i').itemsize])
            with os.fdopen(received[0], 'rb') as transferred:
                transferred.seek(0)
                assert transferred.read() == b'mapped fixture'
    results['threads-mmap-flock'] = 'passed'
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind('workflow.sock')
        listener.listen()
        with socket.socket(socket.AF_UNIX) as client:
            client.connect('workflow.sock')
            with listener.accept()[0] as server:
                client.sendall(b'unix')
                assert server.recv(4) == b'unix'
    results['unix-sockets-and-descriptor-passing'] = 'passed'
    for family, address in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
        with socket.socket(family) as listener:
            listener.bind((address, 0))
            listener.listen()
            with socket.create_connection(listener.getsockname()[:2], timeout=5) as client:
                with listener.accept()[0] as server:
                    client.sendall(b'loopback')
                    assert server.recv(8) == b'loopback'
    results['private-ipv4-ipv6-loopback'] = 'passed'
    with sqlite3.connect('workflow.sqlite') as connection:
        assert connection.execute('PRAGMA journal_mode=WAL').fetchone() == ('wal',)
        connection.execute('CREATE TABLE answers (value INTEGER)')
        connection.execute('INSERT INTO answers VALUES (42)')
        assert connection.execute('SELECT value FROM answers').fetchone() == (42,)
    results['sqlite-wal'] = 'passed'
    Path('results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('NATIVE_API_WORKFLOWS_PASS', flush=True)


if __name__ == '__main__':
    main()
