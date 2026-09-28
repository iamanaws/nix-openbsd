# Nix implementation notes

The native VM and reference demo use [native Nix 2.34.8](../pkgs/openbsd/native-nix.nix).
Standalone NixBSD and the minimal bootstrap VM use cross-built Nix.
For current usage and results, see [development](development.md) and
[validation status](status.md).

## Runtime fixes

The NixBSD OpenBSD overlay supplies these fixes:

- Link libarchive with bzip2, Expat, LZMA and libc so compressed build logs can be read.
- Open the builder's PTY slave before forking. A supervisor keeps it open until
  the builder exits and output drains, preserving terminal behavior and exit status.
- Enable `nixbld` build-user handling so root's builds run under non-root UIDs.
- Preserve libc's thread flag across fork callbacks to prevent daemon build
  deadlocks. This uses the private `__isthreaded` symbol and needs review when
  updating OpenBSD; see the [OpenBSD report](https://www.mail-archive.com/misc@openbsd.org/msg183368.html).

The overlay also disables AWS support and applies terminal and Boost fixes.
The daemon uses `sandbox = false` and `build-users-group = "nixbld"`.
Build users do not isolate the filesystem or network.

Related system fixes configure loopback before services, provide curl's
unversioned linker name for Git's HTTPS helper, and register the running and
booted systems as GC roots.

## Bootstrap tests

These earlier tests exercise NixBSD's cross-built Nix package. From the workspace
containing both repositories:

```sh
nix build path:./nixbsd#openbsd-base.config.nix.package
nix build path:./nixbsd#openbsd-base.vm
OPENBSD_VM_FLAKE="path:$PWD/nixbsd" bash nixbsd/scripts/smoke-test-nix-openbsd-vm.sh
```

They passed on 2026-09-12 in local-store mode and through the daemon as root
and `bestie`. Coverage includes:

- Non-root builders, evaluation, failed builds, store verification and NAR round-trips.
- Terminal detection, live output, fast and signal exits, setup failures and timeout cleanup.
- Signed HTTPS substitution, invalid signatures and archives, TLS trust and Git fetching.
- Concurrent builds with distinct UIDs and garbage collection with and without roots.
- A native C program using `pledge()` and `strlcpy()`, compiled with cross-built TinyCC.

The cache and Git fixtures use host loopback port 18443 and public test keys.
Set `OPENBSD_VM_KEEP_TMP=1` to retain logs. These bootstrap checks are separate
from the [native stdenv and Nix suite](../tests/native/README.md).

## Default Nixpkgs bootstrap

At the pinned Nixpkgs revision, the default OpenBSD Nix recipe fails evaluation
in ncurses because `stdenv.cc.libc` is null. That bootstrap expects `/usr` tools;
this project supplies its own native stdenv. From the same workspace:

```sh
bash nixbsd/scripts/check-nix-openbsd-native.sh
```

The equivalent FreeBSD recipe evaluates with its packaged Clang and libc;
that check does not build it. The standalone base image also has login-limit
warnings for stack size and the initial GC heap.

The [removed OpenBSD port](https://github.com/openbsd/ports/commit/7f027d386301a6844d1f4e054b0833943e6a33bd)
used Nix 2.3.16. Its peer-credential fix is upstream; its build-system and fetcher
patches do not apply directly to modern Nix.
