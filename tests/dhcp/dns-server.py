"""Answer the DHCP fixture's resolver queries using the existing DNS test data."""
import importlib.util
from contextlib import ExitStack
from pathlib import Path
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


# Binding each address keeps replies sourced from the queried DNS server.
with ExitStack() as stack:
    servers = [stack.enter_context(socketserver.UDPServer((address, 53), Answer))
               for address in ['192.0.2.1', '192.0.2.254']]
    threading.Thread(target=servers[0].serve_forever, daemon=True).start()
    servers[1].serve_forever()
