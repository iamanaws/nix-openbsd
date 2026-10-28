"""Serve fixture DNS over IPv6 using the existing test responses."""
from contextlib import ExitStack
import importlib.util
from pathlib import Path
import socket
import socketserver
import threading

spec = importlib.util.spec_from_file_location('dns_checks', Path(__file__).parents[1] / 'generations/dns-check.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
responder = module.TestDNS()


class Answer(socketserver.BaseRequestHandler):
    def handle(self):
        packet, sock = self.request
        sock.sendto(responder.answer(packet), self.client_address)


class IPv6Server(socketserver.UDPServer):
    address_family = socket.AF_INET6


with ExitStack() as stack:
    servers = [stack.enter_context(IPv6Server((address, 53), Answer))
               for address in ['2001:db8:100::53', '2001:db8:100::54']]
    threading.Thread(target=servers[0].serve_forever, daemon=True).start()
    servers[1].serve_forever()
