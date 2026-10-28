# Run the native VM

Start with the [quick start](../README.md#quick-start).
The launcher assembles an amd64 image from package outputs; images stay outside
the binary cache. The first guest package build may also fetch sources and inputs.

## Hosts

| Host | Execution | Validation |
| --- | --- | --- |
| x86_64 Linux | KVM when accessible, otherwise TCG. | Boot, services and persistence passed with both on 2026-10-26. |
| ARM64 Linux | TCG emulating amd64. | Evaluation only; hardware testing pending. |
| Apple Silicon macOS | TCG emulating amd64. | Evaluation only; hardware testing pending. |

All hosts share the amd64 package set. Emulation is slower. Image assembly runs
on Linux; macOS needs an `aarch64-linux` builder, such as nix-darwin's Linux
builder. Its launcher and QEMU run on macOS.
Native arm64 OpenBSD is [future work](roadmap.md#host-validation-and-arm64-openbsd).

## Releases

The validated baseline is OpenBSD 8.0. To stay on that release:

```sh
nix run github:iamanaws/nix-openbsd/openbsd-8.0#native-vm
```

Use the same tag in package references. New OpenBSD releases get separate tags
after validation.

## Access and shutdown

Both `bestie` and `root` use the public password `toor`.
Connect from the host with:

```sh
ssh -p 2222 bestie@127.0.0.1
```

The reference web demo is at http://127.0.0.1:8080/, through relayd to httpd.
Inside the VM, run `shutdown -p now` to stop it. If unresponsive, press Ctrl+A,
release, then X to force QEMU to exit.

## Resources

Set these variables before launching:

| Variable | Default |
| --- | --- |
| `NIX_VM_CORES` | `2` |
| `NIX_VM_MEMORY` | `4096` MiB |
| `NIX_VM_HTTP_PORT` | `8080` |
| `NIX_VM_SSH_PORT` | `2222` |
| `NIX_VM_STATE_DIR` | `openbsd-native-vm/` |
| `NIX_VM_ACCEL` | `auto`: KVM on compatible Linux hosts, otherwise TCG |
| `NIX_VM_DISK_READ_BPS` | `41943040`, or 40 MiB/s |
| `NIX_VM_DISK_WRITE_BPS` | `20971520`, or 20 MiB/s |

For example:

```sh
NIX_VM_CORES=8 NIX_VM_MEMORY=8192 nix run github:iamanaws/nix-openbsd#native-vm
```

Guest builds use available CPUs, one package at a time. Disk limits apply to the
running VM; image builds use the host Nix daemon. Set `NIX_VM_ACCEL=tcg` to test
emulation on x86_64 Linux.

## Persistent state

The state directory holds the writable disk. Its `base-image` link retains the
backing image through GC. A new launcher preserves existing state; use
[system updates](configuration.md#update) to update an installed VM.

To start fresh, shut down and run from the launch directory.
This deletes the VM and every file saved inside it:

```sh
rm -rf openbsd-native-vm/
nix run --refresh github:iamanaws/nix-openbsd#native-vm
```

Use your chosen directory if you set `NIX_VM_STATE_DIR`.

## Binary cache

The guest daemon configures the standard Nix cache and `nix-openbsd.cachix.org`.
The project cache holds cross-built seeds and native packages, including the
system, Nix and toolchains. Release outputs are pinned; images and build history
stay local.
