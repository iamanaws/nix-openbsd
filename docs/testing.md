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
supported hosts. Suites run sequentially; networking uses two small guests.

| Suite | Coverage |
| --- | --- |
| `local` | Unit tests and configuration evaluation; no VM. Unit tests also run through `nix flake check`. |
| `base` | Base VM services, outbound HTTPS, MTU, IPv6 routes and network startup failures. |
| `packages` | Native C/C++, SQLite, tmux, Python, CFFI, libevent and sqlite-utils checks. |
| `vm` | Fresh native image, regular-user package commands, cache downloads and restart. |
| `workflow` | Native builds, a personal configuration, live switching and rollback. |
| `generations` | HTTP, cron, NTP, directories, failed-update recovery, rollback, GC and console recovery. |
| `dns` | Resolver updates, lookups, reload failures, cache preservation and boot recovery. |
| `logging` | Log delivery, rotation, failed-update recovery, rollback and boot recovery. |
| `doas` | Native password authentication, command restrictions, environment handling and permission rollback. |
| `mail` | Local submission, aliases, mailbox permissions, cron output, queues and rollback. |
| `cron-fallback` | Generation checks without `cronctl`. |
| `network` | Routing, BGP and IPsec between isolated guests. |

These are the default suites. `--all` also runs `native`, which combines the
native bootstrap, toolchain, C++ and Nix checks. Use `--suite bootstrap`,
`--suite toolchain`, `--suite cxx` or `--suite nix` to run those separately.
`--full` is an alias for `--all`.
For faster iteration, `--live-only` skips reboot, GC and console recovery in
explicitly selected `generations`, `dns`, `logging`, `doas`, `mail` or `cron-fallback` suites.

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
