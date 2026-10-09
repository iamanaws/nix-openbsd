# Validation status

The native stdenv, Nix, system packages and SMP kernel pass VM validation on
amd64 OpenBSD 7.9. Validated native runtime closures contain no declared
bootstrap seed outputs. The EFI loader remains cross-built.

## Validated workflows

- Native toolchain and package tests through the Nix daemon, requested by root
  and a regular user, with non-root builders.
- Native Nix 2.34.8: signed cache downloads, store verification, daemon restart
  and garbage collection.
- Native VM: boot, clean restart, persistent state, EFI mounting, services,
  HTTP and SSH access.
- System generations: live updates, rollback, failed-update recovery,
  garbage collection and boot-console recovery.
- Published revision `3787d66`: fresh-VM package fetching, a forced native hello
  build, personal configuration builds, live switching and rollback across reboots.

The public workflow passed on 2026-09-28. The refreshed native system passed
the generation VM suite on 2026-10-09; all 18 local generation tests also pass.
See the [testing guide](testing.md) for commands and suite coverage.

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

Builds use separate users without sandboxing. Full upstream Nix suites have
not been run; BLAKE3 uses its non-TBB implementation. Native package coverage
is still experimental. The cross-built reference demo is a separate target.

OpenBSD provides C-locale formatting and UTF-8 character conversion. Tests
requiring regional locales or the absent `quick_exit` API report unsupported.
The tests cover compiler builtins, but not sanitizers or other compiler-rt libraries.
Bootstrap Perl has crypt disabled to break its dependency cycle with libxcrypt.
Texinfo loads native helper extensions but uses its Perl parser.
Nixpkgs disables coreutils' full check phase on BSD. GNU make skips one test
that requires `/bin/echo`.

The native package test does not cover AgentX exchanges with an SNMP daemon.
HTTP/TLS cache fetching is covered by `--nix`. See [package fixes](../pkgs/openbsd) and the
[next steps](roadmap.md).
