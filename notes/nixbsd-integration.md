# NixBSD integration gaps

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
