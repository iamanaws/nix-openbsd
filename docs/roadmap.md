# Roadmap

The focus is native package builds and usable native systems. The cross-built
demo remains a reference. OpenBSD integration fixes stay in this project until
FreeBSD and OpenBSD compatibility has been tested for upstream changes.

## Next features

| Order | Work | Validation |
| --- | --- | --- |
| 1 | Build isolation. | Investigate restrictions on filesystem and network access while preserving working native builds. |

Native IPv4/IPv6 transit, PF policies, BGP and IKEv2 recovery across restarts and
independent router reboots are covered by the [network tests](../tests/network/README.md).

Package and toolchain cleanup is tracked in [upstream work](upstream.md).

## OpenBSD 8.0

[OpenBSD 8.0](https://www.openbsd.org/80.html) was released on October 20, 2026.
The [validated baseline](status.md) is OpenBSD 8.0.

The project uses the 8.0 release sources. The `difftime`
and kernel Clang backports have been removed. The private semaphore fix remains.
Native packages, the toolchain and system workflows pass VM validation.

- Check the 7.9-to-8.0 upgrade path separately, following the
  [upgrade notes](https://www.openbsd.org/faq/upgrade80.html) and
  [errata](https://www.openbsd.org/errata80.html).

The kernel uses LLVM 22.1.8; userland stays on LLVM 21.1.8.
Build frozen snapshots so development can continue independently.

## VM hosts

Run the cached amd64 guest on additional hosts before adding another OpenBSD
architecture. Host launchers and Linux image builders are separate from the
shared guest package set, preserving the existing bootstrap and native cache.
See [host requirements](vm.md#hosts). Validate boot, networking, cached package
commands and persistent state on ARM Linux and Apple Silicon macOS hardware.

## arm64 OpenBSD (later)

Defer this until the amd64 system and host launchers are stable. OpenBSD's arm64
port needs a separate bootstrap, native stdenv, AArch64 LLVM, Nix, kernel and EFI
loader in this project. Validate package builds, services, updates and rollback
before publishing an arm64 release and cache pins. Sources can be shared with
amd64; compiled outputs need their own builds. Preserve the amd64 release.

## Live configuration switching

The native system uses a [local generation manager](../modules/system/generations.nix).
It handles supported service updates, boot selection and rollback. Networking
and other unsupported live changes require a reboot.

The inherited `system.switch.enable` implementation stays disabled. Its
OpenBSD service ordering and checks need separate work before upstream use.

## Raw disk export

The flake exposes `system-image`. Add a raw
`disk.img` output using build-host `qemu-img`, as in the
[Obsidian phase6 follow-up](https://github.com/nix-community/nixbsd/compare/openbsd-phase6...obsidiansystems:nixbsd:openbsd-phase6).
Check the exported partition layout and boot the image before writing it to
a physical disk. QEMU boots the existing image format.
