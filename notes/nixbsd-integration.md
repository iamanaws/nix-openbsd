# NixBSD integration gaps

## Live configuration switching

The local [OpenBSD module](../modules/system/openbsd.nix) disables
`system.switch.enable` and rejects attempts to enable it.
The switching script needs OpenBSD service ordering and `check` semantics.
Implement and test switching, service restarts and rollback before enabling it.

## Raw disk export

The flake exposes `system-image`. Add a raw
`disk.img` output using build-host `qemu-img`, as in the
[Obsidian phase6 follow-up](https://github.com/nix-community/nixbsd/compare/openbsd-phase6...obsidiansystems:nixbsd:openbsd-phase6).
Check the exported partition layout and boot the image before writing it to
a physical disk. QEMU boots the existing image format.
