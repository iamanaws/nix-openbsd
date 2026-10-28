# Validation status

The native stdenv, Nix, system packages and SMP kernel pass VM validation on
amd64 OpenBSD 8.0. Validated native runtime closures contain no declared
bootstrap seed outputs. The EFI loader remains cross-built.

The amd64 guest passed launcher checks with KVM and TCG on x86-64 Linux on
2026-10-26: boot, services, HTTPS, cached packages and persistent state across
an accelerator change. ARM Linux and Apple Silicon macOS launchers evaluate;
runtime checks on those hosts remain pending. See [VM hosts](vm.md#hosts).

## Validated workflows

- Native toolchain and package tests through the Nix daemon, requested by root
  and a regular user, with non-root builders.
- SQLite transactions and locking, tmux sessions, libevent and fmt consumers,
  Python TLS and SQLite, and CFFI extension builds with `extern "Python"` callbacks.
- sqlite-utils JSON/CSV imports, queries, exports and persistence as a regular user.
- Native UTF-8 locale data, including Unicode in Python subprocesses and CSV output.
- Native Go 1.26.8: direct compiler use, regular-user daemon builds, pure Go
  and SQLite cgo consumers, and shfmt 3.14.1 built through the Nixpkgs recipe.
- Native Nix 2.34.8: signed cache downloads, store verification, daemon restart
  and garbage collection.
- Native VM: boot, clean restart, persistent state, EFI mounting, services,
  HTTP and SSH access.
- Cron: validation and immediate reload with `cronctl`, automatic reload without it,
  service-account jobs, failure recovery and persistent data across updates and rollback.
- NTP: configuration checks, restart recovery, preserving stopped services and
  rollback across reboots. These checks use loopback peers and do not test clock accuracy.
- DNS: lookups through `unwind` and libc, atomic resolver-file updates, cached answers
  across blocklist reloads, failure recovery, stopped services and rollback across
  reboots. These checks use a local DNS server and do not test DNSSEC validation.
- Native IPv4 DHCP: automatic boot configuration, lease renewal, static-interface
  exclusion, DNS refresh after carrier recovery, regular-user lookups,
  configuration checks, complete daemon shutdown and reboot persistence.
- Native IPv6 SLAAC: automatic boot configuration, preferred/valid address
  lifetimes, router and DNS expiry, prefix and DNS changes, carrier recovery,
  regular-user DNS lookups over IPv6, complete daemon shutdown and reboot.
  Static-interface exclusion, explicit opt-in alongside static IPv6 addresses
  and disabling temporary addresses passed in two native VMs.
- Logging: log delivery and rotation, file ownership and permissions, stopped
  services, failed-update recovery and rollback across reboots.
- Native doas: password authentication, command restrictions, environment handling,
  configuration checks, live rule updates and rollback across reboots.
- Local mail: regular-user submission, aliases, mailbox permissions, service-account
  cron output, offline queuing, failed-update recovery and delivery across reboot.
  The five mail generation phases passed on 2026-10-27, including garbage collection
  and boot-console recovery.
- OpenBSD maintenance: daily, weekly and monthly scripts, reports,
  local hook permissions, calendar mail, locate and manual-index databases,
  configuration checks, live updates and disabled schedules. All five generation
  phases passed on 2026-10-27, including report persistence through reboot,
  rollback, garbage collection and boot-console recovery.
- System generations: live updates, rollback, failed-update recovery,
  garbage collection and boot-console recovery.

Fresh-image boot and reboot passed on 2026-10-25, including console and SSH
login, all 11 configured services, HTTPS, a regular-user native Nix build,
store integrity and persistent state. Image assembly used RAM staging to
limit host disk I/O.

OpenBSD 8.0 generation tests passed on 2026-10-25: live updates, rollback,
failed-update recovery, garbage collection and console boot recovery.
See the [testing guide](testing.md) for commands and suite coverage.

## Suite results

These counts come from the recorded VM runs. A cached test run can reuse their outputs.

- LLVM 22's X86 `check-all` has 36,274 passes, 34,443 unsupported tests,
  62 expected failures and 414 skipped tests. LLVM 21 had one lit timeout;
  that test passed twice in isolation, without a full-suite rerun.
  Full Clang and LLD suites are disabled; focused tests cover compilation,
  linking and OpenBSD library lookup. Userland uses LLVM 21.1.8; the kernel
  uses LLVM 22.1.8.
- libffi has 1,750 passes. fmt passes 21 test groups; CFFI passes the ten
  selected upstream `extern "Python"` tests. libevent's suite passes with the
  [test-only adjustments](../tests/packages/default.nix).
- sqlite-utils passes 1,458 upstream tests, with 16 skipped. Two Hypothesis test
  modules are excluded because native Rust is unavailable.
- Go 1.26.8 passes 249 standard-library package tests in short mode;
  112 packages have no tests. Shfmt passes its packaged upstream command tests
  and formatting checks.
- libc++abi has 58 passes and 22 unsupported tests.
- libc++ has 9,948 passes, 782 unsupported tests and 49 expected failures.
  This includes all 393 header-visibility tests after the OpenBSD declaration fix.
  Floating-point atomic stress tests run serially to avoid exhausting
  OpenBSD's thread table.

## Limitations

Builds use separate users without sandboxing. Full upstream Nix suites have
not been run; BLAKE3 uses its non-TBB implementation. Native package coverage
is still experimental. The cross-built reference demo is a separate target.
Go's `cmd` and race suites, and standard-library tests without `-short`,
have not been run.
OpenBSD 8.0 refreshes DHCP DNS proposals on lease reacquisition. Renewals record
changed servers in the lease; see [networking](configuration.md#networking).
OpenBSD 8.0's SLAAC client does not process advertised DNS search domains;
configure them through `services.resolvd.config`.
Mail tests cover local delivery through the Unix socket. Custom TCP listeners,
outbound relaying, TLS and filters have not been validated.
Maintenance tests do not exercise root-device backups, process accounting or
optional rdist jobs. The maintenance mtree policy covers mutable account files
and local hooks; it does not verify the Nix store.

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
