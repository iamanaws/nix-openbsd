# Native OpenBSD package test

Run from `nixopenbsd`, with `nixbsd` beside it:

```sh
nix build --impure --max-jobs 1 --cores 6 --out-link result-native-test --expr \
  '(import ./tests/native { nixbsd = builtins.getFlake ("path:" + toString ../nixbsd); }).test'
./result-native-test/bin/test-openbsd-native
```

The host supplies cross-built seed tools and sources to an OpenBSD 7.9 VM.
The VM rebuilds the build tools, curl, Perl, minimal Python, libc, compiler
builtins, libunwind and libc++ from Nixpkgs, then builds test packages without substitutes.
The first run may need to cross-build LLVM and Clang.

The VM has six vCPUs, 8 GiB of RAM and a 64 GiB root filesystem. Host and
guest builds run one package at a time, with six cores per build.

Failed runs keep the log, disk and failed build directories. Set
`OPENBSD_VM_KEEP_TMP=1` to keep successful runs too. The timeout is 90 minutes;
change it with `OPENBSD_VM_TIMEOUT`, in seconds. The runner requests a clean
guest shutdown after the test.

## Checks

Root and `bestie` request builds through the daemon. The test checks:

- Non-root `nixbld` builders and use of the rebuilt tools.
- C/C++ compilation, response files, compression and coreutils operations.
- Dynamic and static PIE libc consumers, compiler builtins and C++ thread-local storage.
- Libunwind's upstream tests and C++ exception cleanup across a shared library.
- Dynamic and static PIE C++ consumers using the rebuilt runtimes.
- Archive extraction, patching and awk's in-place editing extension.
- Native Perl threads, subsecond timestamps and zlib extensions.
- Native Python hashing, file I/O and subprocesses.
- UTF-8 locales, character case conversion and display widths.
- Native ncurses tools and the generated terminfo database.
- Libagentx shared-library and static-archive consumers, including store
  references and RPATH.
- Nixpkgs' hello, zlib and pigz recipes, plus local-file fetching.

## Limitations

The compiler and linker still come from the seed.
Libc++ has consumer tests here, not its full upstream test suite.
Only compiler builtins are rebuilt; sanitizers and the other compiler-rt libraries
are not covered. Non-PIE linking still needs a Clang/LLD flag compatibility fix.
Bootstrap Perl has crypt disabled to break its dependency cycle with libxcrypt.
Texinfo loads native helper extensions but uses its Perl parser.
The test does not cover HTTP/TLS fetching or AgentX exchanges with an SNMP daemon.

Nixpkgs disables coreutils' full check phase on BSD. GNU make skips one test
that requires `/bin/echo`. The remaining package fixes live in
[`pkgs/openbsd`](../../pkgs/openbsd).
