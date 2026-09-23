# Native stdenv status

As of 2026-09-23, the native stdenv passes validation in the OpenBSD VM.
The toolchain and package checks pass through the daemon as root and a
non-root client. The final closure contains native tools and runtimes;
the closure check rejects bootstrap seed outputs.

See the [test instructions and coverage](../tests/native/README.md) to run it.

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

OpenBSD provides C-locale formatting and UTF-8 character conversion. Tests
requiring regional locales or the absent `quick_exit` API report unsupported.
The tests cover compiler builtins, but not sanitizers or other compiler-rt libraries.
Bootstrap Perl has crypt disabled to break its dependency cycle with libxcrypt.
Texinfo loads native helper extensions but uses its Perl parser.
Nixpkgs disables coreutils' full check phase on BSD. GNU make skips one test
that requires `/bin/echo`.

The native package test does not cover HTTP/TLS fetching or AgentX exchanges
with an SNMP daemon. See [package fixes](../pkgs/openbsd) and the
[project next steps](../README.md#next-steps).
