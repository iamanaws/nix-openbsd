# OpenBSD modules

These modules use NixBSD's `init.services` interface to generate OpenBSD
`rc.d` services. Import the modules you need and apply the
[OpenBSD package overlay](../overlays/openbsd.nix). See [flake.nix](../flake.nix)
for a complete demo configuration.

[Service modules](services) cover HTTP, DHCP, DNS, NTP, PF, routing, VPNs,
logging, SNMP and sensors. [ACME renewal](security/acme-client.nix) uses cron.
The modules declare options, service users and runtime directories. They
check configuration before startup where the daemon supports it.
Configuration text follows the corresponding OpenBSD configuration format.

## Before enabling services

- Configuration text goes into the readable Nix store. Do not put real
  passwords or VPN pre-shared keys in these options. Runtime file permissions
  do not protect the store copy.
- PF loads kernel rules through `pfctl`; it is not a daemon. Use explicit
  rules before exposing services or enabling forwarding.
- Routing modules do not enable IP forwarding. Enable it separately with
  `boot.kernel.sysctl."net.inet.ip.forwarding" = 1` when needed.
- `services.iked` provides IKEv2; `services.isakmpd` provides legacy IKEv1.
  `isakmpd -n` is not a configuration check, so its module does not use it
  for pre-start validation. See the [two-VM tests](../tests/network/README.md)
  for BGP and IPsec examples.
- `services.newsyslog` runs log rotation through cron and prepares log files
  for syslogd. It does not start a separate daemon.
- The demo's SNMP service listens only on localhost with a public test
  community. Its client is `snmp`, not the removed `snmpctl`.
- QEMU may expose no hardware sensors, so a running `sensorsd` alone does not
  validate sensor readings.
- ACME issuance needs public HTTP-01 reachability. Test against a staging
  authority before requesting real certificates.

Boot and service tests do not establish that live configuration switching
works. See the [integration notes](../notes/nixbsd-integration.md).
