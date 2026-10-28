# Run tests

Run the regular regression suites from a project checkout:

```sh
nix run .#test
```

Run one suite, select several, or include the long native toolchain checks:

```sh
nix run .#test -- --suite dns
nix run .#test -- --suite dns --live-only
nix run .#test -- --suite local --suite generations
nix run .#test -- --all
nix run .#test -- --list
```

VM suites run on x86_64 Linux with KVM. Local tests also run on the other
supported hosts. Suites run sequentially; DHCP, SLAAC and routing use two guests.

| Suite | Coverage |
| --- | --- |
| `local` | Unit tests and configuration evaluation; no VM. Unit tests also run through `nix flake check`. |
| `base` | Base VM services, outbound HTTPS, MTU, IPv6 routes and network startup failures. |
| `packages` | Native package checks for C/C++, SQLite, tmux, Python, CFFI, libevent, sqlite-utils and Go. |
| `go` | Go standard-library tests in short mode, pure Go, SQLite through cgo, shfmt and regular-user builds. |
| `dhcp` | Native DHCP boot, automatic renewal, DNS changes, carrier recovery, configuration checks and reboot persistence. |
| `slaac` | Native IPv6 autoconfiguration, preferred/valid address lifetimes, router/DNS expiry, prefix and DNS changes, interface exclusions, carrier recovery, service lifecycle and reboot. |
| `vm` | Fresh native image, regular-user package commands, cache downloads and restart. |
| `workflow` | Native builds, a personal configuration, live switching and rollback. |
| `generations` | HTTP, cron, NTP, directories, failed-update recovery, rollback, GC and console recovery. |
| `dns` | Resolver updates, lookups, reload failures, cache preservation and boot recovery. |
| `logging` | Log delivery, rotation, failed-update recovery, rollback and boot recovery. |
| `doas` | Native password authentication, command restrictions, environment handling and permission rollback. |
| `mail` | Local submission, aliases, mailbox permissions, cron output, queues and rollback. |
| `maintenance` | OpenBSD maintenance scripts, local hooks, reports, locate/manual databases and rollback. |
| `cron-fallback` | Generation checks without `cronctl`. |
| `network` | Native IPv4/IPv6 transit forwarding, PF allow/drop policies, BGP withdrawal and IPsec recovery across restarts and reboots. |
| `isolation` | Native isolation feasibility: exec inheritance, chroot, routing domains, C/C++/Go/cgo consumers, fixed-output fetches and rejection of unsupported Nix sandbox requests. |

These are the default suites. `--all` also runs `native`, which combines the
native bootstrap, toolchain, C++ and Nix checks. Use `--suite bootstrap`,
`--suite toolchain`, `--suite cxx` or `--suite nix` to run those separately.
`--full` is an alias for `--all`.
For faster iteration, `--live-only` skips reboot, GC and console recovery in
explicitly selected `generations`, `dns`, `logging`, `doas`, `mail`, `maintenance` or `cron-fallback` suites.

## Development runs

The runner builds native fixtures inside OpenBSD and transfers their outputs
automatically. It starts with the published `openbsd-8.0` VM, then builds and
selects the checkout's native system. `--baseline` can select another published
VM. Update the default baseline when publishing a newer validated release.

To reuse installed build inputs, provide a stopped native VM directory containing
`disk.qcow2` and `efi.fd`:

```sh
nix run .#test -- --suite dns --vm-state ./openbsd-native-vm
```

Tests use private copies and leave that VM unchanged. Focused runs stop if they
would rebuild LLVM or the C++ runtimes; prepare those with the native suites or
use a VM that already has the build inputs.
Go checks supply a localhost hosts file in the private VM when `/etc/hosts`
is absent, so libc forward and reverse lookup tests have their expected fixture.
DHCP checks use two native guests connected through a private Ethernet link,
with OpenBSD dhcpd issuing short leases and a local DNS fixture. Each guest
also retains its QEMU NAT interface. The checks include static-interface
exclusion and verify resolver lookups as a regular user.
Renewal checks inspect the updated lease. DNS proposal changes are checked
after carrier recovery, following [OpenBSD 8.0 behavior](configuration.md#networking).
SLAAC checks use OpenBSD `rad` on two private Ethernet links. They verify
automatic discovery independently of static IPv4, static IPv6 exclusion and
explicit opt-in, regular-user DNS lookups over IPv6, and temporary-address
configuration across reboots. Pausing the advertisement daemon checks natural
address, router and DNS expiry without a graceful withdrawal advertisement.
Routing checks use native `pair(4)` interfaces and routing domains to isolate
a LAN endpoint behind each router. They verify actual transit forwarding,
PF policy for routed and encrypted traffic, route withdrawal, invalid
configuration handling, service restart and independent router reboots.
See the [network suite](../tests/network/README.md) for the topology and limits.
Isolation probes run in one disposable native VM. They test OpenBSD primitives
and the current Nix capability boundary; they do not enable production sandboxing.
See [build isolation](build-isolation.md) for the proof and remaining backend work.

Native guests use `NIX_VM_CORES` and `NIX_VM_MEMORY` (MiB) when set. Regular guests
default to two CPUs and 4 GiB; the bootstrap suites default to eight CPUs and
16 GiB. Guest disk limits remain 40 MiB/s for reads and 20 MiB/s for writes.
Host Nix builds use one job and two cores. `--timeout` overrides the per-suite
limit: one hour normally, 24 hours for the native bootstrap suites.

## CI and results

Use an empty output directory and archive it after the run:

```sh
nix run --accept-flake-config .#test -- --all --work-dir test-results
```

The runner writes `results.json`, `junit.xml` and per-suite logs. A failed suite
does not stop the remaining suites. After they finish, the command returns exit
code `1` if any suite failed, or `0` if all passed. Failed runs retain their VM
disks; add `--keep` to retain successful disks too.
Nix can reuse successful package and unit-test derivations from the cache.

## Additional checks

Test a published commit without preloading project sources or build outputs:

```sh
nix run .#test-native-vm -- --public-ref github:iamanaws/nix-openbsd/REVISION
```

On x86-64 Linux, run `NIX_VM_ACCEL=tcg nix run .#test -- --suite vm` to check
software emulation. These modes are separate from the default regression run.

After publishing, check cache metadata with:

```sh
python3 tests/cache/check.py path:"$PWD" --bootstrap --cross
```

Source-specific reproducers under `tests/upstream` remain manual. See
[native checks](../tests/native/README.md), [generation checks](../tests/generations/README.md),
[network checks](../tests/network/README.md) and [validation coverage](status.md).
