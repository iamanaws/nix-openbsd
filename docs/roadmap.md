# Roadmap

The focus is native package builds and usable native systems. The cross-built
demo remains a reference. OpenBSD integration fixes stay in this project until
FreeBSD and OpenBSD compatibility has been tested for upstream changes.

## Next features

| Order | Work | Validation |
| --- | --- | --- |
| 1 | Live updates for NTP, then DNS and logging. | Configuration checks, service start/stop, failed-update recovery and rollback in the native VM. |
| 2 | Native Go support, then a Go application built through Nix. | Regular-user daemon builds, upstream tests and a cgo consumer using the existing C toolchain. |
| 3 | Broader network coverage. | IPv6 forwarding, PF policies, routing and VPN recovery across service restarts and reboots. |
| 4 | Build isolation. | Investigate restrictions on filesystem and network access while preserving working native builds. |

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
