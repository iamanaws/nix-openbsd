# NixBSD integration gaps

## Live configuration switching

The earlier review found that `switch-to-configuration.sh` invoked `@rcorder@`
but substituted that path only for FreeBSD. Review OpenBSD service ordering
and `check` versus `status` handling before testing `switch`, `test`, service
restarts and rollback in a disposable VM. Boot and login tests do not cover
these operations.

## Raw disk export

The flake already exposes `system-image`. Consider an additional raw
`disk.img` output using build-host `qemu-img`, as in the
[Obsidian phase6 follow-up](https://github.com/nix-community/nixbsd/compare/openbsd-phase6...obsidiansystems:nixbsd:openbsd-phase6).
Validate the exported partition layout and boot it before using it to write
a physical disk. Raw export is not required for the existing QEMU boot path.
