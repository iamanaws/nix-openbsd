# Run tests

From a checkout:

```sh
nix run .#test
```

Run one suite, select several, or include the long native toolchain checks:

```sh
nix run .#test -- --suite dns
nix run .#test -- --suite local --suite generations
nix run .#test -- --all
nix run .#test -- --list
```

VM suites run on x86_64 Linux, normally with KVM. Local checks also run on other
supported hosts. Suites run sequentially.

## Suites

| Suite | Coverage |
| --- | --- |
| `local` | Unit tests and configuration evaluation without a VM. Unit tests also run through `nix flake check`. |
| `base` | Services, HTTPS, MTU, IPv6 routes and network startup failures. |
| `packages` | C/C++, SQLite, tmux, Python/CFFI, libevent, sqlite-utils and Go consumers. |
| `go` | Short standard-library tests, pure Go, SQLite cgo, shfmt and regular-user builds. |
| `dhcp`, `slaac` | Boot, leases/lifetimes, DNS, static exclusions, carrier recovery and reboot. |
| `vm` | Fresh image, package commands, cache downloads and restart. |
| `workflow` | Personal configuration template, native builds, live switching and rollback. |
| `generations`, `dns`, `logging`, `doas`, `mail`, `maintenance`, `cron-fallback` | [Generation checks](../tests/generations/README.md), including failure recovery, rollback, GC and boot recovery. |
| `network` | [Two-router transit, BGP, PF and IPsec](../tests/network/README.md). |
| `isolation` | [Nix sandbox](build-isolation.md): filesystem/network isolation, compiler consumers, daemon policy and lifecycle cleanup. |
| `sandbox-packages` | Fresh Hello, fmt, inih, MarkupSafe, shfmt and dbmate builds through a sandboxed daemon, with parallel builds and regular-user consumers. |
| `native` | [Bootstrap, toolchain, C++ and Nix](../tests/native/README.md). Also selectable as `bootstrap`, `toolchain`, `cxx` or `nix`. |

The default run excludes `native` and `sandbox-packages`; `--all` adds both.
`--full` aliases `--all`. For selected generation suites, `--live-only` skips
reboot, GC and console recovery:

```sh
nix run .#test -- --suite dns --live-only
```

## Development runs

The runner starts with the published `openbsd-8.0` VM, builds fixtures inside
OpenBSD, transfers outputs and selects the checkout's native system.
`--baseline` chooses another published VM.

To reuse inputs, supply a stopped VM directory containing `disk.qcow2` and
`efi.fd`:

```sh
nix run .#test -- --suite dns --vm-state ./openbsd-native-vm
```

Tests use private copies. Focused runs stop if they would rebuild LLVM or the
C++ runtimes; prepare those with native suites or an existing VM.

Isolation checks enable the OpenBSD sandbox in a temporary daemon inside one
disposable VM. They cover regular-user builds, concurrent domains, cancellation,
timeouts, abandoned workers and cleanup. The reference system keeps sandboxing
disabled by default.

To build the package recipes with fresh outputs and their existing checks:

```sh
nix run .#test -- --suite sandbox-packages --vm-state ./openbsd-native-vm --keep
```

The suite preloads build inputs, adds a unique nonce, and rejects substituted
outputs. Build hooks verify the UID, routing domain, hidden host files and
blocked host listeners. Installed consumers check C/C++ linkage, the Python
C extension, shell formatting and SQLite migrations through cgo.

DHCP uses a private two-guest link, short leases and a local DNS fixture.
It checks renewed leases, then DNS refresh after carrier recovery, matching
[OpenBSD 8.0 behavior](networking.md#ipv4-dhcp).
SLAAC uses two links with `rad`; pausing advertisements tests natural expiry.
Routing topology is documented with its suite. Go supplies a localhost hosts
file when absent for libc lookup tests.

| Resource | Default |
| --- | --- |
| Regular guest | 2 CPUs, 4096 MiB RAM. |
| Native bootstrap guest | 8 CPUs, 16384 MiB RAM. |
| Guest disk limits | 40 MiB/s reads, 20 MiB/s writes. |
| Host Nix build | One job, two cores. |
| Suite timeout | One hour; 24 hours for native bootstrap suites. |

`NIX_VM_CORES` and `NIX_VM_MEMORY` override guest resources.
`--timeout SECONDS` overrides the suite limit, including fixture preparation.

## Reports

Use an empty output directory:

```sh
nix run .#test -- --all --work-dir test-results
```

The runner writes `results.json`, `junit.xml` and per-suite logs.
Failures do not stop later suites; the final exit code is 1 if any fail, otherwise
0. Failed disks remain for diagnosis; `--keep` retains successful disks too.
Nix may reuse successful package and unit-test derivations from cache.

## Additional checks

For a published commit without preloading project sources or outputs:

```sh
nix run .#test-native-vm -- --public-ref github:iamanaws/nix-openbsd/REVISION
```

On x86_64 Linux, use `NIX_VM_ACCEL=tcg nix run .#test -- --suite vm` to test
emulation. Inspect cache metadata with:

```sh
python3 tests/cache/check.py path:"$PWD" --bootstrap --cross
```

Source-specific reproducers in `tests/upstream` remain manual.
[Status](status.md) records results and coverage limits.
