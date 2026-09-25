# Native stdenv status

As of 2026-09-23, the native stdenv passes validation in the OpenBSD VM.
The toolchain and package checks pass through the daemon as root and a
non-root client. The final closure contains native tools and runtimes;
the closure check rejects bootstrap seed outputs.

See the [test instructions and coverage](../tests/native/README.md) to run it.

Native Nix 2.34.8 passed the package checks through its own daemon on
2026-09-24, as root and a regular user with unprivileged builders. Signed
Cachix downloads, store verification and isolated garbage collection passed.
Its runtime closure contains no declared bootstrap outputs. Full upstream
Nix suites have not been run; BLAKE3 uses its non-TBB implementation.

A fresh demo VM also passed on 2026-09-24 with native Nix: root and regular-user
daemon builds, daemon restart, signed cache downloads and HTTP serving.
The demo's other system packages are cross-built.

The native system and SMP kernel passed VM boot and runtime checks on
2026-09-25. Its 296-path closure contains none of the 37 bootstrap outputs;
all 272 recorded derivations target `x86_64-openbsd`. Checks covered EFI mounting,
HTTP, DHCP, cron, syslog, root and regular-user Nix builds, daemon restart,
signed cache downloads, and compiling and running C with the cached native stdenv.
The image uses the existing cross-built EFI loader. The `native-system-image`
recipe supplies the EFI disklabel entry, initial Nix database and runtime directories.
The `native-vm` launcher passed the same runtime checks from a fresh disk,
plus a shutdown and restart check with persistent state.

## Suite results

These counts come from the recorded VM runs. A cached test run can reuse their outputs.

- LLVM's `check-all` passes for the X86 configuration. Full Clang and LLD
  suites are disabled; the toolchain tests cover compilation and linking.
- libc++abi has 58 passes and 22 unsupported tests.
- libc++ has 9,948 passes, 782 unsupported tests and 49 expected failures.
  This includes all 393 header-visibility tests after the OpenBSD declaration fix.
  Floating-point atomic stress tests run serially to avoid exhausting
  OpenBSD's thread table.

## Limitations

Boot prints warnings for unfinished base integration, including optional IPsec key
generation, savecore and vi recovery.

OpenBSD provides C-locale formatting and UTF-8 character conversion. Tests
requiring regional locales or the absent `quick_exit` API report unsupported.
The tests cover compiler builtins, but not sanitizers or other compiler-rt libraries.
Bootstrap Perl has crypt disabled to break its dependency cycle with libxcrypt.
Texinfo loads native helper extensions but uses its Perl parser.
Nixpkgs disables coreutils' full check phase on BSD. GNU make skips one test
that requires `/bin/echo`.

The native package test does not cover AgentX exchanges with an SNMP daemon.
HTTP/TLS cache fetching is covered by `--nix`. See [package fixes](../pkgs/openbsd) and the
[project next steps](../README.md#next-steps).
