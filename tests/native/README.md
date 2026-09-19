# Native OpenBSD package test

Run from `nixopenbsd`, with `nixbsd` beside it:

```sh
nix build --impure --max-jobs 1 --cores 6 --out-link result-native-test \
  --extra-substituters https://nix-openbsd.cachix.org \
  --extra-trusted-public-keys 'nix-openbsd.cachix.org-1:IbN25q8l3NyIq8L16AWaJ1MNTxZRiYdzO5eYFQv1J+4=' \
  --expr '(import ./tests/native { nixbsd = builtins.getFlake ("path:" + toString ../nixbsd); }).test'
./result-native-test/bin/test-openbsd-native
```

The host supplies cross-built seed tools and sources to an OpenBSD 7.9 VM.
The VM rebuilds the build tools, curl, Perl, minimal Python, libc, compiler
builtins, libunwind and libc++ from Nixpkgs, reusing cached outputs when available.
See the [stdenv notes](../../notes/native-stdenv.md) for current results and remaining work.

Recipes and tests are imported after boot over a local host-to-guest connection.
Rerun the build command after editing them; the base image is reused.
Seed tools, preloaded sources and VM configuration changes still rebuild it.

Use `--prepare-only` to check recipe transfer and evaluation without building
packages, or `--cxx` to run the full C++ suites.

The VM has six vCPUs, 8 GiB of RAM and a 64 GiB root filesystem. Host and
guest builds run one package at a time, with six cores per build.

Failed runs keep the log, disk and failed build directories. Set
`OPENBSD_VM_KEEP_TMP=1` to keep successful runs too. The timeout is 24 hours;
change it with `OPENBSD_VM_TIMEOUT`, in seconds. The runner requests a clean
guest shutdown after the test.

## Checks

Root and `bestie` request builds through the daemon. The test checks:

- Non-root `nixbld` builders and use of the rebuilt tools.
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

## Limitations

The compiler and linker still come from the seed.
The normal run checks C++ consumers. Inside the VM, `test-openbsd-native --cxx`
runs the full libc++/libc++abi suites; some OpenBSD failures remain under investigation.
Only compiler builtins are rebuilt; sanitizers and the other compiler-rt libraries
are not covered. Non-PIE linking still needs a Clang/LLD flag compatibility fix.
Bootstrap Perl has crypt disabled to break its dependency cycle with libxcrypt.
Texinfo loads native helper extensions but uses its Perl parser.
The test does not cover HTTP/TLS fetching or AgentX exchanges with an SNMP daemon.

Nixpkgs disables coreutils' full check phase on BSD. GNU make skips one test
that requires `/bin/echo`. The remaining package fixes live in
[`pkgs/openbsd`](../../pkgs/openbsd).
