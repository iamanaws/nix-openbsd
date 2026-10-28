# Routing and VPN tests

From x86_64 Linux with KVM:

```sh
nix run .#test -- --suite network
nix run .#test -- --suite network --vm-state ./openbsd-native-vm --keep
```

The runner builds fixtures in OpenBSD and boots private copies of the prepared
disk. Each guest uses the [regular test resources](../../docs/testing.md#development-runs).
A private Ethernet link uses temporary host-loopback UDP ports without changing
host interfaces, routes or firewall rules.

## Topology

Each VM is a router with a LAN endpoint isolated in routing domain 1.
`pair(4)` connects it to the router in domain 0. LANs use `198.51.100.0/24`,
`203.0.113.0/24` and separate IPv6 /64s. Transit must cross both routers;
disabling forwarding proves this path. NAT remains for fixture installation,
then PF blocks it during runtime checks.

## Checks

- Declarative hostnames, static IPv4/IPv6, forwarding and both default-gateway
  forms, including metrics.
- BGP route installation and bidirectional ping/UDP transit. Stopping BGP
  withdraws routes and blocks traffic; restarting restores both without manual routes.
- PF permits UDP 9000 and drops 9001, with counters and controls proving both
  endpoint listeners work.
- Repeated startup preserves interfaces/routes. Invalid BGP/IKE restarts and
  PF loads preserve running daemons, installed rules and traffic.
- IKEv2 protects both LAN protocols. PF rejects external cleartext and applies
  UDP policy on `enc0`. WAN captures require ESP and reject exposed LAN packets.
- Removing IPsec blocks traffic while BGP routes remain. IKE restart restores
  protection without replacing its private key.
- Independent router reboots restore BGP, IPsec, PF and endpoint interfaces.

The UDP responder is a fixture; modules use native bgpd, iked, pfctl and rc scripts.
The public PSK is only for the private link. See
[credential precautions](../../docs/services.md) before using real keys.

Results and consoles live under the test work directory.
`--timeout` includes fixture preparation. Peer reboot recovery allows the
five-minute IKE exchange timeout and automatic retry.

Coverage excludes OSPF, RIP, IKEv1, certificates, timed rekeying and live network
generation switching. See [status](../../docs/status.md).
