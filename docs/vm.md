# Run the native VM

Start with the [quick start](../README.md#quick-start). The launcher runs on
x86_64 Linux with KVM and assembles the image from cached packages.
The first package build inside the guest also fetches sources and build inputs,
which can take a few minutes.

## Access and shutdown

Both `bestie` and `root` use password `toor`. These are public test accounts.
From the Linux host, connect over SSH with:

```sh
ssh -p 2222 bestie@127.0.0.1
```

The reference web demo is at http://127.0.0.1:8080/, through relayd to httpd.
The VM also enables PF, DNS configuration, NTP, cron, logging and monitoring.

Inside the VM, shut down with:

```sh
shutdown -p now
```

If it is unresponsive, press **Ctrl+A**, release, then **X** to force QEMU to exit.

## Resources

The defaults are 2 CPUs and 4 GiB RAM. For 8 CPUs and 8 GiB RAM:

```sh
NIX_VM_CORES=8 NIX_VM_MEMORY=8192 nix run github:iamanaws/nix-openbsd#native-vm
```

Set these before starting the VM. Guest builds use the available CPUs,
one package at a time.

| Variable | Default |
| --- | --- |
| `NIX_VM_CORES` | `2` |
| `NIX_VM_MEMORY` | `4096` MiB |
| `NIX_VM_HTTP_PORT` | `8080` |
| `NIX_VM_SSH_PORT` | `2222` |
| `NIX_VM_STATE_DIR` | `openbsd-native-vm/` |
| `NIX_VM_DISK_READ_BPS` | 40 MiB/s, expressed in bytes/s |
| `NIX_VM_DISK_WRITE_BPS` | 20 MiB/s, expressed in bytes/s |

Disk limits apply to the running VM. Image builds run through the host Nix daemon.

## Persistent state

The state directory holds the writable disk. Its `base-image` link protects
the backing image from garbage collection. Rebuilding the launcher preserves
existing state; use [system updates](configuration.md) to update that VM.

To start fresh, shut down the VM and run the following from its launch directory.
**This deletes the VM and all files saved inside it.**

```sh
rm -rf openbsd-native-vm/
nix run --refresh github:iamanaws/nix-openbsd#native-vm
```

If you set `NIX_VM_STATE_DIR`, use that directory instead.

## Binary cache

Use [nix-openbsd.cachix.org](https://nix-openbsd.cachix.org) alongside the standard
Nix cache. When prompted, accept the flake's cache URL and signing key and
remember both settings. The guest daemon already configures these caches.

The cache holds cross-built seeds and the validated native system, Nix, stdenv,
Clang, LLD and runtimes. Important outputs are pinned. VM images and build
history stay local.
