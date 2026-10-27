# Run tests

Run VM tests from a project checkout on x86_64 Linux with KVM.

## Native VM workflow

```sh
nix run .#test-native-vm
```

On x86-64 Linux, also test the emulation path used by ARM hosts:

```sh
NIX_VM_ACCEL=tcg nix run .#test-native-vm
```

This checks regular-user package commands, services, HTTP, SSH and persistent
state across a restart. It supplies the checkout's sources to a fresh guest.
It also checks Python HTTPS and sqlite-utils cache downloads and data imports.

To include native builds, a personal configuration, live switching and rollback:

```sh
nix run .#test-native-vm -- --system-workflow
```

To test a published commit without preloading sources or build outputs:

```sh
nix run .#test-native-vm -- --public-ref github:iamanaws/nix-openbsd/REVISION
```

Replace `REVISION` with the commit hash. This also forces a native hello build,
builds a personal configuration, and checks live switching and rollback across
reboots. Dependencies can use the cache.

Both modes retain the VM's disk I/O limits. Set `NIX_VM_CORES=8` and
`NIX_VM_MEMORY=8192` for more resources. Add `--builders ''` after `--` to
assemble the image locally with one job and two cores.
Logs remain in the printed directory. Successful test disks are removed;
add `--keep` after `--` to retain them. Failed runs keep their disks.

## Native package checks

Inside OpenBSD, run the package consumer tests with:

```sh
nix build -L .#checks.x86_64-openbsd.packages
nix build -L .#checks.x86_64-openbsd.sqlite-utils
```

This builds C/C++ consumers with CMake and pkg-config, checks SQLite
transactions and locking, starts a private tmux server, and checks Python's
SQLite, TLS certificate verification and CFFI extension callbacks.
The sqlite-utils check covers JSON/CSV imports, queries, exports and persistence.
It requires a non-root Nix builder and rejects
runtime dependencies on the bootstrap seeds.

Run libevent's upstream suite and CFFI's upstream `extern "Python"` tests with:

```sh
nix build -L .#checks.x86_64-openbsd.libevent .#checks.x86_64-openbsd.cffi-callbacks
```

fmt's package build also runs its upstream tests.
The libevent check uses test-only patches for OpenBSD resolver behavior and
avoids public DNS in its blocking lookup failure test.

## Other suites

| Suite | Coverage |
| --- | --- |
| [Native packages](../tests/native/README.md) | Stdenv, toolchain, C/C++ runtimes and Nix daemon builds. |
| [System generations](../tests/generations/README.md) | Live updates, failure recovery, rollback, GC and boot-console recovery. |
| [Networking](../tests/network/README.md) | Declarative addresses, routing, BGP and IPsec between two VMs. |
| [Base VM](../tests/base/run.sh) | Service control, outbound HTTPS, MTU, IPv6 routes and network startup failures. |

Run the base checks with `bash tests/base/run.sh --max-jobs 1 --cores 8`.
See [validation results and limitations](status.md) for what has passed.

Check cache availability for native packages, cross-built package targets and
bootstrap outputs:

```sh
python3 tests/cache/check.py path:"$PWD" --bootstrap --cross
```

This checks metadata; the VM test verifies actual downloads.
