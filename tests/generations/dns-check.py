"""Check native DNS updates against a local test server; DNSSEC is not exercised."""
import argparse
import collections
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time


def run(*args, success=True):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True)
    print(result.stdout + result.stderr, end='', flush=True)
    assert (result.returncode == 0) == success, (args, result.returncode)
    return result.stdout.strip()


def wire_name(name):
    return b''.join(bytes([len(part)]) + part.encode() for part in name.split('.') if part) + b'\0'


def question(packet):
    offset, labels = 12, []
    while packet[offset]:
        length = packet[offset]
        labels.append(packet[offset + 1:offset + 1 + length].decode().lower())
        offset += length + 1
    offset += 1
    kind, family = struct.unpack_from('!HH', packet, offset)
    assert family == 1
    return '.'.join(labels), kind, offset + 4


class TestDNS:
    def __init__(self):
        self.queries = collections.Counter()

    def answer(self, packet):
        name, kind, end = question(packet)
        self.queries[name, kind] += 1
        answers, authority, additional, rcode = [], [], [], 0

        def rr(owner, kind, data):
            return owner + struct.pack('!HHIH', kind, 1, 300, len(data)) + data

        if kind == 1 and name.endswith('.dns.example.com'):
            address = ('192.0.2.10' if name.endswith('.a.dns.example.com') else
                       '192.0.2.20' if name.endswith('.b.dns.example.com') else '192.0.2.99')
            answers.append(rr(b'\xc0\x0c', 1, socket.inet_aton(address)))
        elif kind == 2:
            answers.append(rr(b'\xc0\x0c', 2, wire_name('ns.dns.example.com')))
            additional.append(rr(wire_name('ns.dns.example.com'), 1, socket.inet_aton('127.0.0.1')))
        else:
            rcode = 3 if kind == 1 else 0
            soa = wire_name('ns.dns.example.com') + wire_name('hostmaster.dns.example.com')
            soa += struct.pack('!IIIII', 1, 300, 300, 300, 300)
            authority.append(rr(b'\0', 6, soa))
        header = struct.pack('!HHHHHH', struct.unpack_from('!H', packet)[0], 0x8580 | rcode, 1,
                             len(answers), len(authority), len(additional))
        return header + packet[12:end] + b''.join(answers + authority + additional)

    def __enter__(self):
        responder = self

        class UDP(socketserver.BaseRequestHandler):
            def handle(self):
                packet, sock = self.request
                sock.sendto(responder.answer(packet), self.client_address)

        class TCP(socketserver.BaseRequestHandler):
            def handle(self):
                def receive(size):
                    packet = b''
                    while len(packet) < size:
                        chunk = self.request.recv(size - len(packet))
                        if not chunk:
                            raise EOFError('Incomplete DNS request')
                        packet += chunk
                    return packet
                self.request.settimeout(2)
                size = struct.unpack('!H', receive(2))[0]
                packet = receive(size)
                answer = responder.answer(packet)
                self.request.sendall(struct.pack('!H', len(answer)) + answer)

        class TCPServer(socketserver.TCPServer):
            allow_reuse_address = True

        self.servers = [socketserver.UDPServer(('127.0.0.1', 15353), UDP),
                        TCPServer(('127.0.0.1', 15353), TCP)]
        for server in self.servers:
            threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .05}, daemon=True).start()
        return self

    def __exit__(self, *_):
        for server in self.servers:
            server.shutdown()
            server.server_close()


def query(name):
    packet = struct.pack('!HHHHHH', 1234, 0x0100, 1, 0, 0, 0) + wire_name(name)
    packet += struct.pack('!HH', 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(2)
        sock.connect(('127.0.0.1', 53))
        sock.send(packet)
        answer = sock.recv(65535)
    assert answer[:2] == packet[:2]
    return struct.unpack_from('!H', answer, 2)[0] & 15


def eventually(check, timeout=30):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return check()
        except (AssertionError, OSError, subprocess.SubprocessError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(.2)


def process(name):
    rows = subprocess.check_output(['ps', '-ax', '-o', 'pid=,ppid=,comm='], text=True)
    parents = [int(fields[0]) for line in rows.splitlines()
               if len(fields := line.split()) == 3 and fields[1:] == ['1', name]]
    assert len(parents) == 1, (name, parents)
    return parents[0]


def stopped(name):
    run('/etc/rc.d/' + name, 'check', success=False)
    rows = subprocess.check_output(['ps', '-ax', '-o', 'comm='], text=True)
    assert name not in rows.split()


def lookup(name):
    # Each invocation uses a new libc resolver context, as a new application would.
    result = subprocess.run([
        sys.executable, '-B', '-c',
        'import socket,sys; print(socket.gethostbyname(sys.argv[1]))', name,
    ], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, (name, result.stderr)
    return result.stdout.strip()


def check_generation(name):
    for service in ['resolvd', 'unwind']:
        run('/etc/rc.d/' + service, 'check')
        process(service)

    def check():
        content = Path('/etc/resolv.conf').read_text()
        assert 'search ' + name + '.dns.example.com' in content, content
        assert not Path('/etc/resolv.conf').is_symlink()
        assert Path('/etc/resolv.conf').stat().st_mode & 0o777 == 0o644
        first = next(line for line in content.splitlines() if line.startswith('nameserver'))
        assert first.split('#', 1)[0].split() == ['nameserver', '127.0.0.1'], content
        assert query('blocked-' + name + '.dns.example.com') == 5
        address = '192.0.2.10' if name == 'a' else '192.0.2.20'
        hostname = 'fresh-' + str(time.monotonic_ns())
        actual = lookup(hostname)
        assert actual == address, (hostname, actual, content)
    eventually(check)


def live(a, b, fixtures, server):
    current = Path('/run/current-system')
    profile = Path('/nix/var/nix/profiles/system')
    default = Path('/boot/nixos/default.conf')
    selected = default.read_bytes()
    assert current.resolve() == a and profile.resolve() == a
    check_generation('a')
    pids = {name: process(name) for name in ['resolvd', 'unwind']}
    run('openbsd-rebuild', 'dry-activate', '--store-path', b)
    run('openbsd-rebuild', 'test', '--store-path', a)
    assert pids == {name: process(name) for name in pids}

    # A copy failure must leave the running resolver file intact.
    source = Path('/etc/resolv.conf.resolvd')
    original = source.readlink()
    content = Path('/etc/resolv.conf').read_bytes()
    source.unlink()
    source.symlink_to('/no-such-resolver-configuration')
    try:
        run('/etc/rc.d/resolvd', 'reload', success=False)
        assert Path('/etc/resolv.conf').read_bytes() == content
    finally:
        source.unlink()
        source.symlink_to(original)
    assert not list(Path('/etc').glob('.resolv.conf.*'))

    for failure in ['invalid', 'failed-activation', 'failed-resolvd-start', 'failed-unwind-start']:
        before = {name: process(name) for name in pids}
        run('openbsd-rebuild', 'switch', '--store-path', fixtures / failure, success=False)
        assert current.resolve() == a and profile.resolve() == a
        assert default.read_bytes() == selected
        check_generation('a')
        if failure == 'invalid':
            assert before == {name: process(name) for name in pids}

    for name in ['resolvd', 'unwind']:
        before = {name: process(name) for name in pids}
        Path('/run/dns-fail-' + name + '-reload').touch()
        run('openbsd-rebuild', 'switch', '--store-path', b, success=False)
        assert current.resolve() == a and profile.resolve() == a
        assert default.read_bytes() == selected
        check_generation('a')
        assert before == {name: process(name) for name in pids}

    pids = {name: process(name) for name in pids}
    assert lookup('cached.dns.example.com') == '192.0.2.99'
    requests = server.queries['cached.dns.example.com', 1]
    run('openbsd-rebuild', 'test', '--store-path', b)
    check_generation('b')
    assert query('blocked-a.dns.example.com') == 0
    assert pids == {name: process(name) for name in pids}
    assert lookup('cached.dns.example.com') == '192.0.2.99'
    assert server.queries['cached.dns.example.com', 1] == requests
    assert current.resolve() == b and profile.resolve() == a
    assert default.read_bytes() == selected
    run('openbsd-rebuild', 'test', '--store-path', b)
    assert pids == {name: process(name) for name in pids}

    for name in ['resolvd', 'unwind']:
        run('/etc/rc.d/' + name, 'stop')
        eventually(lambda: stopped(name))
    run('openbsd-rebuild', 'test', '--store-path', a)
    for name in pids:
        stopped(name)
    for name in ['unwind', 'resolvd']:
        run('/etc/rc.d/' + name, 'start')
    check_generation('a')
    run('openbsd-rebuild', 'switch', '--store-path', b)
    check_generation('b')
    run('openbsd-rebuild', 'switch', '--rollback')
    assert current.resolve() == a and profile.resolve() == a
    check_generation('a')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['live', 'a', 'b'])
    parser.add_argument('system_a', type=Path)
    parser.add_argument('system_b', type=Path)
    parser.add_argument('fixtures', type=Path, nargs='?')
    args = parser.parse_args()
    if args.phase == 'live' and not args.fixtures:
        parser.error('live checks require the fixture bundle')
    with TestDNS() as server:
        if args.phase == 'live':
            live(args.system_a, args.system_b, args.fixtures, server)
        else:
            check_generation(args.phase)
    print('DNS_' + args.phase.upper() + '_PASS', flush=True)


if __name__ == '__main__':
    main()
