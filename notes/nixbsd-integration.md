# NixBSD integration gaps

## Live configuration switching

The integration review found a missing OpenBSD substitution for `@rcorder@`
in `switch-to-configuration.sh`. Review OpenBSD service ordering
and `check` versus `status` handling before testing `switch`, `test`, service
restarts and rollback in a disposable VM. Boot and login tests do not cover
these operations.

## Raw disk export

The flake exposes `system-image`. Add a raw
`disk.img` output using build-host `qemu-img`, as in the
[Obsidian phase6 follow-up](https://github.com/nix-community/nixbsd/compare/openbsd-phase6...obsidiansystems:nixbsd:openbsd-phase6).
Check the exported partition layout and boot the image before writing it to
a physical disk. QEMU boots the existing image format.
