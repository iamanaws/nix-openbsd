"""Two disposable OpenBSD guests; no host interfaces, routes or firewall changes."""

import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


class Guest:
    def __init__(self, runner, work, number, port, peer_port):
        self.directory = work / str(number)
        self.directory.mkdir()
        (self.directory / "runtime").mkdir()
        self.log = (self.directory / "console.log").open("wb", buffering=0)
        self.reader = (self.directory / "console.log").open("rb")
        self.buffer = b""
        self.process = subprocess.Popen(
            [runner], stdin=subprocess.PIPE, stdout=self.log, stderr=subprocess.STDOUT,
            env=os.environ | {
                "NIX_DISK_IMAGE": str(self.directory / "disk.qcow2"),
                "NIX_EFI_VARS": str(self.directory / "efi.fd"),
                "TMPDIR": str(self.directory / "runtime"), "USE_TMPDIR": "1",
                "QEMU_OPTS": (
                    f"-netdev socket,id=test,udp=127.0.0.1:{peer_port},localaddr=127.0.0.1:{port} "
                    f"-device virtio-net-pci,netdev=test,mac=52:54:00:12:34:0{number}"
                ),
            },
        )

    def expect(self, pattern, timeout=60):
        deadline = time.monotonic() + timeout
        regex = re.compile(pattern.encode())
        while time.monotonic() < deadline:
            self.buffer += self.reader.read()
            match = regex.search(self.buffer)
            if match:
                result, self.buffer = self.buffer[:match.end()], self.buffer[match.end():]
                return result.decode(errors="replace")
            if self.process.poll() is not None:
                raise RuntimeError(f"Guest exited: {self.directory}")
            time.sleep(0.1)
        raise RuntimeError(f"Timeout waiting for {pattern}: {self.directory}")

    def send(self, line):
        self.process.stdin.write((line + "\n").encode())
        self.process.stdin.flush()

    def command(self, line):
        self.send(line + "; printf '\\nCOMMAND_%s:%s\\n' DONE \"$?\"")
        result = self.expect(r"\r?\nCOMMAND_DONE:[0-9]+\r?\n")
        print(result, flush=True)
        if not result.rstrip().endswith("COMMAND_DONE:0"):
            raise RuntimeError(f"Guest command failed: {line}")
        return result

    def login(self):
        self.expect("login:", int(os.environ.get("OPENBSD_VM_TIMEOUT", "300")))
        self.send("root")
        self.expect("Password:")
        self.send("toor")
        self.expect(r"root@[^\r\n]*#")

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.reader.close()
        self.log.close()


def main():
    left, right = sys.argv[1:]
    work = Path(tempfile.mkdtemp(prefix="nixopenbsd-network."))
    guests = []
    success = False
    try:
        # Reserve distinct ephemeral UDP ports before launching either guest.
        with socket.socket(type=socket.SOCK_DGRAM) as a, socket.socket(type=socket.SOCK_DGRAM) as b:
            a.bind(("127.0.0.1", 0))
            b.bind(("127.0.0.1", 0))
            ports = [a.getsockname()[1], b.getsockname()[1]]
        for i, runner in enumerate([left, right]):
            guests.append(Guest(runner, work, i + 1, ports[i], ports[1 - i]))
        for i, guest in enumerate(guests):
            guest.login()
            guest.command(f'test "$(hostname)" = network-{i+1}.test')
            guest.command(f"ifconfig vio0 | grep -F 'inet 192.0.2.{i+1} netmask 0xffffff00'")
            guest.command("ifconfig lo0 | grep -F 'inet 127.0.0.1 '")
            guest.command(f"ifconfig lo0 | grep -F 'inet 198.51.100.{i+1} netmask 0xffffffff'")
            guest.command(f"route -n get default | grep -F 'gateway: 192.0.2.{2-i}'")
            if i == 0:
                guest.command("route -n get default | grep -E 'priority: *42'")
            guest.command("ifconfig vio0 && /etc/rc.d/bgpd check && /etc/rc.d/iked check")
            guest.command("pfctl -nf /etc/pf.conf && pfctl -si | grep 'Status: Enabled'")
            guest.command("key_before=$(sha256sum /etc/iked/private/local.key)")
            # OpenBSD otherwise rejects packets for an address on another interface.
            guest.command("sysctl net.inet.ip.forwarding=1")

        for i, guest in enumerate(guests):
            guest.command("/etc/rc.d/network_interfaces start")
            route = guest.command(f"route -n get 203.0.113.{2-i}")
            if not re.search(r"destination:\s+0\.0\.0\.0\s", route):
                raise RuntimeError("Expected traffic to use the default route")
            guest.command(f"ping -n -c 3 -w 5 -I 192.0.2.{i+1} 203.0.113.{2-i}")
        print("Declarative addresses, hostname and default-gateway traffic passed", flush=True)

        # First prove BGP installs usable routes without relying on IPsec flows.
        for guest in guests:
            guest.command("/etc/rc.d/iked stop && ipsecctl -F")
        for i, guest in enumerate(guests):
            peer = 2 - i
            guest.command(f"n=0; until bgpctl show rib | grep -q '198.51.100.{peer}/32'; do n=$((n+1)); test $n -lt 40 || break; sleep 1; done; bgpctl show rib | grep '198.51.100.{peer}/32'")
            guest.command(f"route -n get 198.51.100.{peer} | grep 'gateway: 192.0.2.{peer}'")
            guest.command(f"route -n get 198.51.100.{peer} | grep -F 'destination: 198.51.100.{peer}'")
            guest.command(f"ping -n -c 3 -w 5 -I 198.51.100.{i+1} 198.51.100.{peer}")
        print("BGP route exchange and bidirectional routed traffic passed", flush=True)

        for guest in guests:
            # Forbid cleartext payloads on the wire; permit decrypted traffic on enc0.
            guest.command("printf '%s\\n' 'set skip on lo' 'block return' 'block drop quick on vio0 inet from 198.51.100.0/24 to 198.51.100.0/24' 'pass on vio0 proto { tcp udp esp icmp }' 'pass on enc0' > /tmp/vpn-pf.conf; pfctl -f /tmp/vpn-pf.conf && pfctl -F states")
            guest.command("/etc/rc.d/iked start")
            guest.command('test "$key_before" = "$(sha256sum /etc/iked/private/local.key)"')
        for i, guest in enumerate(guests):
            guest.command("n=0; until ipsecctl -s sa | grep -q 'esp tunnel'; do n=$((n+1)); test $n -lt 40 || break; sleep 1; done; ipsecctl -s sa | grep 'esp tunnel'")
            guest.command(f"ping -n -c 3 -w 5 -I 198.51.100.{i+1} 198.51.100.{2-i}")
        print("IKEv2 negotiation and bidirectional IPsec traffic passed (cleartext blocked)", flush=True)

        for guest in guests:
            guest.command("/etc/rc.d/iked stop && ipsecctl -F && pfctl -F states")
        guests[0].command("route -n get 198.51.100.2 | grep 'gateway: 192.0.2.2'")
        guests[0].command("! ping -n -c 1 -w 3 -I 198.51.100.1 198.51.100.2")
        print("Traffic fails with IPsec removed: negative control passed", flush=True)
        success = True
    finally:
        for guest in guests:
            guest.close()
        if not success:
            for guest in guests:
                print((guest.directory / "console.log").read_text(errors="replace")[-4000:], file=sys.stderr)
        if not success or os.environ.get("OPENBSD_VM_KEEP_TMP") == "1":
            print(f"VM logs and disks: {work}", flush=True)
        else:
            shutil.rmtree(work)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
