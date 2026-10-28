# Roadmap

## Nix sandbox backend

Native Nix 2.35.2 includes an opt-in [OpenBSD sandbox backend](build-isolation.md).
Broaden package coverage with sandboxing enabled before reconsidering the
default. Shared kernel state and routing domains impose [platform limits](build-isolation.md#limits).

## Host validation and arm64 OpenBSD

Validate amd64 guest boot, networking, cache commands and persistence on ARM
Linux and Apple Silicon hardware. The [launchers evaluate](vm.md#hosts), but
hardware runs are pending.

Defer native arm64 OpenBSD until amd64 and the host launchers are stable.
It needs its own bootstrap, stdenv, AArch64 LLVM, Nix, kernel and EFI loader.
Share sources, build separate outputs, and validate packages, services, updates
and rollback before publishing a release. Preserve amd64 release pins.

## OpenBSD upgrades

OpenBSD 8.0 is the [validated baseline](status.md). Check the 7.9-to-8.0 path
separately against [upgrade notes](https://www.openbsd.org/faq/upgrade80.html)
and [errata](https://www.openbsd.org/errata80.html). The project uses release
sources; difftime and kernel Clang backports are removed, while the private
semaphore fix remains.

## Upstream integration

[Patch review](upstream.md) tracks package and toolchain cleanup.
Keep local NixBSD adapters until FreeBSD evaluation and OpenBSD runtime checks
pass with their replacements.

The [local generation manager](../modules/system/generations.nix) handles supported
live changes. The inherited `system.switch.enable` stays disabled until OpenBSD
service ordering and checks have separate validation.

## Raw disk export

Add a raw `disk.img` alongside `system-image`, using build-host `qemu-img` as in
the [NixBSD follow-up](https://github.com/nix-community/nixbsd/compare/openbsd-phase6...obsidiansystems:nixbsd:openbsd-phase6).
Validate partition layout and boot before writing it to physical media.
