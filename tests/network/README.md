# Routing and VPN tests

Run from the project root on x86_64 Linux with KVM:

```sh
nix run --impure --max-jobs 1 --cores 1 --expr '
  (import ./tests/network {
    flake = builtins.getFlake (toString ./.);
  }).test
'
```

The test boots two headless OpenBSD guests with fresh disks, one CPU and
768 MiB RAM each. They communicate through temporary UDP ports on host
loopback, with no other network connection. The test does not change host
bridges, TAP devices, routes, firewall rules or existing VM disks.

The driver enables IPv4 forwarding in each guest so packets arriving on the
link can reach its advertised loopback address.

The test checks that:

- The guests use their configured hostnames, including the domain.
- `networking.interfaces.*.ipv4.addresses` sets the link addresses and loopback aliases.
- `networking.defaultGateway` accepts both a string and an attribute set with
  an interface and metric. Traffic to an address not advertised by BGP uses it.
- Running the network startup service again preserves working addresses and routes.
- BGP starts at boot, exchanges two host routes and installs them in the kernel.
- Traffic passes in both directions using the learned routes, without IPsec.
- IKEv2 establishes IPsec security associations and traffic passes while PF
  blocks unencrypted traffic on the external interface.
- Restarting `iked` preserves its local private key.
- Removing IPsec blocks the protected traffic even though the BGP route remains.

The pre-shared key is public test data. Read the
[service configuration precautions](../../modules/README.md#before-enabling-services)
before using these options outside the test.

## Logs and timeouts

If the test fails, it keeps the logs and guest disks and prints their location.
Set `OPENBSD_VM_KEEP_TMP=1` to keep them after a successful run too.
`OPENBSD_VM_TIMEOUT` sets the login timeout, which defaults to 300 seconds
per guest. Each check has a 60-second timeout. The test stops only its own VMs.

## Known gaps

The test does not cover forwarding between separate client networks, IPv6,
OSPF, RIP, IKEv1, certificate authentication, rekeying or reboot persistence.
See the [integration gaps](../../docs/roadmap.md) for live
configuration switching.

## Implementation notes

The fixtures use the [OpenBSD integration module](../../modules/system/openbsd.nix)
for interface setup. The tests also exercise protocol/service databases,
private key persistence and daemon process-title matching.

The iked module follows OpenBSD's
[directory permissions](https://github.com/openbsd/src/blob/master/etc/mtree/4.4BSD.dist)
and [rc process pattern](https://github.com/openbsd/src/blob/master/etc/rc.d/iked).
