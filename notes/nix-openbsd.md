# Nix on OpenBSD

NixBSD uses stable Nix 2.34.8 from its Nixpkgs pin. `nix.package` defaults
to `pkgs.nix`. The Nix daemon module installs it and starts the service.

From the workspace containing both repositories:

```sh
nix build path:./nixbsd#openbsd-base.config.nix.package
nix build path:./nixbsd#openbsd-base.vm
OPENBSD_VM_FLAKE="path:$PWD/nixbsd" bash nixbsd/scripts/smoke-test-nix-openbsd-vm.sh
```

Build on x86_64 Linux for amd64 OpenBSD 7.9. The package requires NixBSD's
store and system setup.

## Fixes

`nixbsd/overlays/openbsd.nix` applies the package fixes. The daemon module
defaults to `sandbox = false` and `build-users-group = "nixbld"` on OpenBSD.
Separate build users do not isolate the builder's filesystem or network.

- Link libarchive to bzip2, Expat, LZMA and libc. Missing bzip2 and Expat
  symbols caused a crash when Nix opened a compressed build log.
- Open the PTY slave before forking the builder. OpenBSD otherwise allows
  the parent to read EOF before the child opens the slave. A supervisor keeps
  the slave open until the builder exits and its output drains, then preserves
  its exit code or signal. It shares the builder's UID and process group.
  Stdout and stderr remain terminals. The supervisor uses Nix's startup protocol.
- Enable Nix's build-user handling on OpenBSD. Nix previously ignored
  `nixbld` and ran root's builders as UID 0.
- Patch Nix's initialization code to preserve libc's thread flag across
  fork callbacks. This prevents the inherited atfork lock from blocking
  daemon builds. The patch uses the private `__isthreaded` symbol and needs
  review when updating OpenBSD. See the
  [OpenBSD report](https://www.mail-archive.com/misc@openbsd.org/msg183368.html).

The overlay also disables AWS support and applies terminal and Boost fixes.

The extended tests found these issues:

- Loopback had no address and was down. The OpenBSD network module
  configures `lo0` before network services start.
- Git's configure check could not find `-lcurl`, so it omitted its HTTPS
  helper. The curl package provides the unversioned linker name.
- Garbage collection deleted the running system in the test VM. OpenBSD
  activation registers `/run/current-system` and `/run/booted-system`
  as GC roots. This change does not apply to FreeBSD.

## Tests

The patched package passed the VM test on 2026-09-12 using the local store,
the daemon as root, and the daemon as the unprivileged `bestie` account.
Each run checked evaluation, fresh builds under a non-root UID, failed
builders, store verification, NAR round-trips and gzip/bzip2/XZ imports.
The test image uses the same Nix package and daemon module as `openbsd-base`.
Set `OPENBSD_VM_KEEP_TMP=1` to keep the console log.

The PTY test checks terminal detection, live C stdout without an explicit
flush, repeated fast exits, signal exits, complete logs and timeout cleanup.
A test library injects a child setup error in local-store mode to check that
Nix reports it through the startup protocol.
The PTY suite passed in all three modes. The previous pipe-based image
failed terminal detection.

The extended test covers signed HTTPS substitution, rejection of unsigned
and wrongly signed paths, corrupt archives, TLS trust, Git fetching,
overlapping builds under distinct UIDs, and garbage collection with roots.
It passed in all three modes on 2026-09-12. GC preserved the current and
booted systems, kept a rooted test path, and collected it after root removal.
The test serves its cache and Git repository from host loopback port 18443.
Its certificates and signing keys are public test fixtures.

The native C test supplies TinyCC, libc, headers and build tools from the
store without importing a native Nixpkgs environment. TinyCC is cross-built
with the image; the test program is compiled and linked inside OpenBSD by
a non-root builder. It checks the OS version and calls `pledge()` and
`strlcpy()`. The test runs the executable during the build and from the
client account. It passed in all three store/client modes.

Native stdenv and package testing is documented in the
[native test guide](../tests/native/README.md). See the
[stdenv status](native-stdenv.md) for current results.

## Default Nixpkgs bootstrap

The default native Nixpkgs recipe for Nix fails to evaluate in ncurses
because `stdenv.cc.libc` is null. Nixpkgs selects a bootstrap that expects
tools under `/usr` and does not provide packaged libc metadata. This check
uses Nixpkgs' default bootstrap, not this project's native stdenv.
Reproduce the default recipe failure with:

```sh
bash nixbsd/scripts/check-nix-openbsd-native.sh
```

At the same Nixpkgs pin, the native FreeBSD recipe for stable Nix evaluates.
FreeBSD has a dedicated bootstrap with packaged Clang and libc. This check
covers evaluation only.

The base image's login limits also cause stack-size and initial GC-heap warnings.

The [removed OpenBSD port](https://github.com/openbsd/ports/commit/7f027d386301a6844d1f4e054b0833943e6a33bd)
used Nix 2.3.16. Its peer-credential fix is already upstream. Its build-system
and fetcher patches do not apply directly to modern Nix.
