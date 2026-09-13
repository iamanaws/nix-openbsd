# Native OpenBSD package test

Run from `nixopenbsd`, with `nixbsd` beside it:

```sh
nix build --impure --max-jobs 1 --cores 2 --out-link result-native-test --expr \
  '(import ./tests/native { nixbsd = builtins.getFlake ("path:" + toString ../nixbsd); }).test'
./result-native-test/bin/test-openbsd-native
```

The host supplies cross-built seed tools and sources to an OpenBSD 7.9 VM.
The VM rebuilds Bash, coreutils, sed, gzip, `file`, GNU make, XZ and their
dependencies, then uses them to build test packages without substitutes.
The first run may need to cross-build LLVM and Clang.

The VM has four vCPUs, 8 GiB of RAM and a 16 GiB root filesystem. Host and
guest builds run one package at a time, with two cores per build.

Failed runs keep the log, disk and failed build directories. Set
`OPENBSD_VM_KEEP_TMP=1` to keep successful runs too. The timeout is one hour;
change it with `OPENBSD_VM_TIMEOUT`, in seconds. The runner requests a clean
guest shutdown after the test.

## Checks

Root and `bestie` request builds through the daemon. The test checks:

- Non-root `nixbld` builders and use of the rebuilt tools.
- C/C++ compilation, compression round trips and coreutils operations.
- Libagentx shared-library and static-archive consumers, including store
  references and RPATH.
- Nixpkgs' hello, zlib and pigz recipes, plus local-file fetching.

Both clients pass. GNU make passes 1,418 tests across 131 categories, and XZ
passes all 19 package tests.

## Limitations

The compiler, libc, Perl, curl and other tools still come from the seed.
Autoconf's check phase skips its suite. Texinfo uses its pure-Perl fallback.
The image lacks UTF-8 locale data. The test does not cover HTTP/TLS fetching
or AgentX exchanges with an SNMP daemon.

Nixpkgs disables coreutils' full check phase on BSD. GNU make skips one test
that requires `/bin/echo`. The remaining package fixes live in
[`pkgs/openbsd`](../../pkgs/openbsd).
