"""UDP echo endpoints and timeout checks for the isolated routing test."""
import argparse
import errno
import selectors
import socket


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    server = sub.add_parser('serve')
    server.add_argument('ipv4')
    server.add_argument('ipv6')
    client = sub.add_parser('probe')
    client.add_argument('address')
    client.add_argument('port', type=int)
    client.add_argument('--blocked', action='store_true')
    args = parser.parse_args()
    if args.command == 'serve':
        with selectors.DefaultSelector() as selector:
            for address, family in [(args.ipv4, socket.AF_INET), (args.ipv6, socket.AF_INET6)]:
                for port in [9000, 9001]:
                    connection = socket.socket(family, socket.SOCK_DGRAM)
                    if family == socket.AF_INET6:
                        connection.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    connection.bind((address, port))
                    selector.register(connection, selectors.EVENT_READ)
            print('ENDPOINT_READY', flush=True)
            while True:
                for key, _ in selector.select():
                    data, address = key.fileobj.recvfrom(1024)
                    key.fileobj.sendto(data, address)
    else:
        family = socket.AF_INET6 if ':' in args.address else socket.AF_INET
        with socket.socket(family, socket.SOCK_DGRAM) as connection:
            connection.settimeout(2)
            connection.connect((args.address, args.port))
            connection.send(b'openbsd-routing-test')
            try:
                reply = connection.recv(1024)
            except TimeoutError:
                if args.blocked:
                    return
                raise
            except OSError as error:
                # OpenBSD may report an IPv6 forwarding drop to the sender.
                # The driver also requires the matching PF counter to increase.
                if args.blocked and error.errno == errno.EHOSTUNREACH:
                    return
                raise
            assert reply == b'openbsd-routing-test'
            assert not args.blocked, 'PF allowed a packet that should have been dropped'


if __name__ == '__main__':
    main()
