# Run tests

Run VM tests from a project checkout on x86_64 Linux with KVM.

## Native VM workflow

```sh
nix run .#test-native-vm
```

This checks regular-user package commands, services, HTTP, SSH and persistent
state across a restart. It supplies the checkout's sources to a fresh guest.

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

## Other suites

| Suite | Coverage |
| --- | --- |
| [Native packages](../tests/native/README.md) | Stdenv, toolchain, C/C++ runtimes and Nix daemon builds. |
| [System generations](../tests/generations/README.md) | Live updates, failure recovery, rollback, GC and boot-console recovery. |
| [Networking](../tests/network/README.md) | Declarative addresses, routing, BGP and IPsec between two VMs. |
| [Base VM](../tests/base/run.sh) | Service control, outbound HTTPS, MTU, IPv6 routes and network startup failures. |

Run the base checks with `bash tests/base/run.sh --max-jobs 1 --cores 8`.
See [validation results and limitations](status.md) for what has passed.
