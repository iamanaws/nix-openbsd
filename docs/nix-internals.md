# Nix implementation notes

The native VM and reference demo use [native Nix 2.34.8](../pkgs/openbsd/native-nix.nix).
Standalone NixBSD and the minimal bootstrap VM use cross-built Nix.

## Runtime fixes

The [runtime overrides](../pkgs/openbsd/nix-runtime-overrides.nix) and NixBSD
overlay provide:

- Libarchive links to bzip2, Expat, LZMA and libc for compressed build logs.
- A PTY slave opened before fork, with a supervisor retaining it until the
  builder exits and output drains.
- Non-root `nixbld` execution for root's builds.
- Preservation of libc's thread flag across fork callbacks to avoid daemon
  deadlocks. The private `__isthreaded` symbol needs review on OpenBSD updates;
  see the [OpenBSD report](https://www.mail-archive.com/misc@openbsd.org/msg183368.html).
- Terminal and Boost compatibility fixes, with AWS support disabled.

The daemon sets `sandbox = false` and `build-users-group = "nixbld"`.
See [isolation](build-isolation.md) for the native proof and missing backend.
System adapters also configure loopback before services, give curl an unversioned
linker name for Git HTTPS, and root running/booted systems against GC.

## Cross-built bootstrap

These historical NixBSD checks run from a workspace containing both repositories:

```sh
nix build path:./nixbsd#openbsd-base.config.nix.package
nix build path:./nixbsd#openbsd-base.vm
OPENBSD_VM_FLAKE="path:$PWD/nixbsd" bash nixbsd/scripts/smoke-test-nix-openbsd-vm.sh
```

The 2026-09-12 run covered local-store and daemon builds as root and bestie:
builder UIDs, evaluation, failure cleanup, PTYs, NARs, signed HTTPS substitution,
Git, concurrent builds and GC. A native C consumer used cross-built TinyCC.
Fixtures use loopback port 18443 and public keys.
`OPENBSD_VM_KEEP_TMP=1` retains logs.
Current [native checks](../tests/native/README.md) validate the rebuilt tools.

## Default Nixpkgs bootstrap

At the pinned Nixpkgs revision, its default OpenBSD Nix recipe fails ncurses
evaluation because `stdenv.cc.libc` is null. It expects `/usr` tools; this
project supplies a native stdenv. From the same workspace:

```sh
bash nixbsd/scripts/check-nix-openbsd-native.sh
```

The FreeBSD recipe evaluates with packaged Clang and libc; this check does not
build it. The standalone base image also reports stack-limit and initial-GC-heap
login warnings.

The [removed OpenBSD port](https://github.com/openbsd/ports/commit/7f027d386301a6844d1f4e054b0833943e6a33bd)
used Nix 2.3.16. Its peer-credential fix is upstream; build-system and fetcher
patches do not apply directly to modern Nix.
