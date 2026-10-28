# Routing and VPN tests

Run from the project root on x86_64 Linux with KVM:

```sh
nix run .#test -- --suite network
nix run .#test -- --suite network --vm-state ./openbsd-native-vm --keep
```

The runner builds fixtures inside OpenBSD, then boots private copies of the
prepared native disk. Each guest defaults to two CPUs and 4 GiB RAM, with
40 MiB/s disk reads and 20 MiB/s writes. A private Ethernet link uses temporary
UDP ports on host loopback. The test changes no host interfaces, routes or
firewall rules, and stops only its own VMs.

Each VM is a router with an isolated LAN endpoint in routing domain 1.
OpenBSD `pair(4)` interfaces connect that endpoint to the router in domain 0.
The two LANs use `198.51.100.0/24`, `203.0.113.0/24` and separate IPv6 /64s.
Endpoint traffic must traverse both routers; disabling IPv4 or IPv6 forwarding
checks that this is actual transit traffic. The launcher's NAT interface remains
present for fixture installation; PF blocks it during runtime checks.

The test checks:

- Declarative hostnames, static IPv4/IPv6 addresses, forwarding sysctls and both
  supported default-gateway forms, including an explicit metric.
- BGP exchange and kernel installation of both LAN routes, with bidirectional
  ping and UDP echo traffic through the isolated endpoints.
- PF allows UDP port 9000 and drops port 9001, with rule counters and positive
  local checks that both endpoint listeners work.
- Repeating network startup preserves working interfaces and routes.
- Invalid BGP/IKE restart configurations preserve the running daemons; an invalid
  PF rule load preserves the installed rules and working traffic.
- Stopping BGP withdraws the learned routes and blocks transit traffic;
  restarting it restores routes and traffic without manual route insertion.
- IKEv2 protects both IPv4 and IPv6 LAN traffic. PF blocks LAN cleartext on the
  external interface and applies the UDP policy to decrypted traffic on `enc0`.
  A WAN packet capture requires ESP and rejects exposed LAN packets.
- Removing IPsec blocks traffic while the BGP routes remain. Restarting IKE
  restores protection and preserves its local private key.
- Rebooting each router while its peer stays running restores BGP, IPsec and
  PF policy, preserves the key and recreates the isolated endpoint interfaces.

The UDP responder is a test fixture in the endpoint routing domain. The service
modules use OpenBSD's `bgpd`, `iked`, `pfctl` and rc scripts. The public test PSK
is used only on the private guest link; read the
[service configuration precautions](../../modules/README.md#before-enabling-services)
before configuring real credentials.

The runner writes per-phase results and console logs beneath the test work
directory. Failed runs keep their disks; `--keep` retains successful disks too.
`--timeout` sets the suite limit, including native fixture preparation.
Reboot recovery allows OpenBSD's five-minute IKE exchange timeout and subsequent
automatic retry when a negotiation starts while the peer is offline.

Coverage does not include OSPF, RIP, IKEv1, certificate authentication, timed
rekeying or live network generation switching. See the
[roadmap](../../docs/roadmap.md) and [validation status](../../docs/status.md).
