# Networking

These settings belong in a [system configuration](configuration.md).
Network changes require `openbsd-rebuild boot` followed by reboot.

## IPv4 DHCP

OpenBSD uses `dhcpleased` for DHCP and `resolvd` for DNS proposals.
The default `networking.useDHCP = true` selects Ethernet interfaces without
static IPv4 addresses. To mix DHCP and static configuration:

```nix
networking.useDHCP = false;
networking.interfaces.vio0.useDHCP = true;
networking.interfaces.vio1 = {
  useDHCP = false;
  ipv4.addresses = [ { address = "192.0.2.1"; prefixLength = 24; } ];
};
```

The module sets `inet autoconf`. Leases persist in `/var/db/dhcpleased`.
Inspect one with `dhcpleasectl -l vio0`; request a new lease and wait up to
30 seconds with `dhcpleasectl -w 30 vio0`.

`networking.dhcpleased.config` accepts
[dhcpleased.conf](https://man.openbsd.org/dhcpleased.conf) syntax, such as
`interface vio1 { ignore dns }`; it defaults to empty. Add resolver settings
through `services.resolvd.config`, or disable `services.resolvd.enable` to manage
the resolver file yourself.

OpenBSD 8.0 records changed DNS servers during renewal but publishes a new
resolver proposal on lease reacquisition, such as after a link change.
`dhcpleasectl -w 30 vio0` requests that refresh immediately.

## IPv6 SLAAC

`networking.useSLAAC = true` is the default. It selects Ethernet interfaces
without static IPv6 addresses, independently of IPv4 settings:

```nix
networking.useSLAAC = false;
networking.interfaces.vio0.useSLAAC = true;
networking.interfaces.vio1 = {
  useSLAAC = false;
  ipv6.addresses = [ { address = "2001:db8::1"; prefixLength = 64; } ];
};
```

The module sets `inet6 autoconf`. `slaacd` manages addresses, routers,
lifetimes, link changes and DNS proposals without a configuration file.
Use `slaacctl show interface vio0` to inspect state and
`slaacctl send solicitation vio0` to request an advertisement.

Explicit per-interface `useSLAAC = true` permits SLAAC alongside static IPv6.
Excluded interfaces have stable and temporary autoconfiguration disabled.
`networking.tempAddresses = "disabled"` stops temporary address generation;
other values retain OpenBSD's source-address selection.
`networking.enableIPv6 = false` or `networking.slaacd.enable = false` disables
SLAAC. OpenBSD 8.0 ignores advertised DNS search domains; set them through resolvd.

Static IPv6 startup waits up to ten seconds for Duplicate Address Detection
before starting dependent services.

## Daemon lifecycle

DHCP validates configuration before startup and restart; it has no reload.
SLAAC supports start, stop and restart without reload.
`networking.dhcpcd.enable = true` selects dhcpcd instead of the native DHCP
and SLAAC daemons; they cannot run together.

## Routing and VPNs

Routing modules do not enable forwarding. Set
`boot.kernel.sysctl."net.inet.ip.forwarding" = 1` for IPv4 and
`boot.kernel.sysctl."net.inet6.ip6.forwarding" = 1` for IPv6 as needed.
Define PF rules before exposing services or forwarding traffic.

BGP and IKEv2 validate configuration before stopping a running daemon for restart.
PF validates before loading kernel rules with `pfctl`; its rc command exits
after loading. `services.iked` provides IKEv2; `services.isakmpd` provides IKEv1.
The latter has no pre-start configuration check; `isakmpd -n` is not one.

See [two-router tests](../tests/network/README.md) for BGP/IPsec examples and
[service precautions](services.md) before configuring real credentials.
