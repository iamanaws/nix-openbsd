# Native OpenBSD package test

Run from `nixopenbsd`, with `nixbsd` beside it:

```sh
nix build --impure --max-jobs 1 --cores 8 --out-link result-native-test \
  --extra-substituters https://nix-openbsd.cachix.org \
  --extra-trusted-public-keys 'nix-openbsd.cachix.org-1:IbN25q8l3NyIq8L16AWaJ1MNTxZRiYdzO5eYFQv1J+4=' \
  --expr '(import ./tests/native { nixbsd = builtins.getFlake ("path:" + toString ../nixbsd); }).test'
./result-native-test/bin/test-openbsd-native
```

The host supplies cross-built seed tools and sources to an OpenBSD 7.9 VM.
The guest builds the native stdenv and test packages, using the
[binary cache](../../README.md#binary-cache) when available.
See the [stdenv status](../../notes/native-stdenv.md) for results and limitations.

The runner imports recipes and tests after boot over a local connection.
Rerun the build command after editing them. Changes to seed tools, preloaded
sources or VM configuration rebuild the base image. Recipe changes reuse it.

Use `--prepare-only` to check recipe transfer and evaluation without building
packages, `--cxx` to run the full C++ suites, or `--toolchain` to build and test
native LLVM, Clang and LLD. Use `--nix` to build the native Nix CLI and daemon,
then run the package checks through that daemon as root and `bestie`. It also
checks for bootstrap references, downloads from Cachix, and tests garbage
collection in a disposable store. The original daemon is restored afterward.

The VM has eight vCPUs, 16 GiB of RAM and a 64 GiB root filesystem. Host and
guest builds run one package at a time, with eight cores per build.

Failed runs keep the log, disk and failed build directories. Set
`OPENBSD_VM_KEEP_TMP=1` to keep successful runs too. The timeout is 24 hours.
Change it with `OPENBSD_VM_TIMEOUT`, in seconds. The runner requests a clean
guest shutdown after the test.

## Checks

Root and `bestie` request builds through the daemon. The test checks:

- Non-root `nixbld` builders and use of the rebuilt tools.
- A final stdenv closure without bootstrap seed outputs.
- C/C++ compilation, response files, compression and coreutils operations.
- Dynamic and static PIE libc consumers, compiler builtins and C++ thread-local storage.
- Private and shared semaphores, timed waits and thread cancellation.
- Libunwind's upstream tests and C++ exception cleanup across a shared library.
- Dynamic and static PIE C++ consumers using the rebuilt runtimes.
- Archive extraction, patching and awk's in-place editing extension.
- Native Perl threads, subsecond timestamps and zlib extensions.
- Native Python hashing, file I/O, subprocesses, compression, ctypes callbacks and psutil.
- UTF-8 locales, character case conversion and display widths.
- Native ncurses tools and the generated terminfo database.
- Libagentx shared-library and static-archive consumers, including store
  references and RPATH.
- Nixpkgs' hello, zlib and pigz recipes, plus local-file fetching.
