# Upstream work

Track remaining patches, their destination, and when they can be removed.
Candidate fixes still need review against current upstream sources.

## Local patches

Paths are relative to [pkgs/openbsd](../pkgs/openbsd), except the test patch.
Keep backports until the pinned source includes the fix and the relevant checks
pass without it. See [native probes](../tests/native/README.md#focused-runtime-probes).

| Patch | Purpose | Status / next step |
| --- | --- | --- |
| `libc-difftime.patch` | Negative timestamps. | OpenBSD [b018fff](https://github.com/openbsd/src/commit/b018fffbd6c97a22e7af2d20e7fa5ba61fdbfb36). Remove after updating the source and checking both bootstrap and native libc with the [probe](../tests/native/difftime.c). |
| `kernel-clang.patch` | Kernel format attributes, SCSI sleep identifier and sensor register selection. | OpenBSD backports: [printf](https://github.com/openbsd/src/commit/2f70c1a437bcc2bff242b351d3336b6d7ac1a877), [SCSI](https://github.com/openbsd/src/commit/3c019fcac636f960f981bb0cf7e92433c3c50874), [sensors](https://github.com/openbsd/src/commit/9f06b4d0de89448d55447db96bc04231453a7d12). Remove after a source update and kernel build/boot checks. |
| `gnulib-openbsd-fseeko.patch` | Opaque FILE support. | Gnulib backport for gzip and tar. Remove when each bundles the fix and passes native checks; [compile probe](../tests/upstream/gnulib-fseeko.py). Cross-build success alone is insufficient. |
| `libffi-openbsd-closures.patch` | Closures without RWX mappings. | Scoped adaptation of the [OpenBSD ports fix](https://raw.githubusercontent.com/openbsd/ports/master/devel/libffi/patches/patch-src_closures_c). Keep until upstream avoids RWX and closure tests pass without it. |
| `librthread-private-semaphores.patch` | Separate private futex wakeups after fork. | Candidate: OpenBSD; preserve shared/named semaphore behavior. |
| `libcxxabi-openbsd-futex.patch` | Correct futex operation constants. | LLVM libc++abi: current upstream uses 0/1; OpenBSD requires 1/2. Native guard probe fails before the patch and passes after it. The default guard implementation uses a mutex. |
| `libcxx-openbsd-mbstate.patch` | mbstate declarations without importing overloads. | [LLVM #200940](https://github.com/llvm/llvm-project/pull/200940) fixes the C++17/20 module failure. Frozen C++03 needs our [follow-up](../upstream/llvm/libcxx-mbstate-cxx03.patch); check with the [probe](../tests/upstream/llvm-mbstate.py). Keep the working patch until the replacement passes the full suites. |
| `libcxx-openbsd-locale-headers.patch` | Locale declarations under feature-test macros. | LLVM 23.1.3 still fails with `_XOPEN_SOURCE=500`. Minimize declarations for the new locale API. The merged encoding fix [#228306](https://github.com/llvm/llvm-project/pull/228306) addresses a different failure. |
| `llvm-interpreter-roundeven.patch` | Interpreter support without libm roundeven. | Generic LLVM interpreter fix. Native regression passes all four host rounding modes; see the [probe](../tests/native/llvm-roundeven.cc). Related [#188898](https://github.com/llvm/llvm-project/pull/188898) changes library availability, not interpreter lowering. |
| `llvm-openbsd-wait-timeout.patch` | Avoid process-wide alarms and reap the correct child after timeout. | Split into generic child-specific reaping and timeout handling. Current upstream retains both problems; [#19243](https://github.com/llvm/llvm-project/issues/19243) is an earlier related report. Keep the tested local patch while preparing focused regression tests. |
| `clang-openbsd-static-pie.patch` | Pass -pie for static PIE links. | Backport of [118efe76](https://github.com/llvm/llvm-project/commit/118efe7680bdc010ab984f8ae4505699f53bbca6); remove after updating Clang and running driver/linking checks. |
| `clang-openbsd-no-pie.patch` | Emit LLD-compatible -no-pie. | Backport of [a2171756](https://github.com/llvm/llvm-project/commit/a2171756dd5d690faf30bafe63810d1dc6cdb342); remove after updating Clang and running driver/linking checks. |
| `gnulib-openbsd-case-mapping.patch` | Consistent Unicode case conversion. | Candidate: gnulib; consumed by grep. |
| `diffutils-openbsd-pipes.patch` | Do not treat anonymous pipes as the same file. | Candidate: gnulib; consumed by diffutils. |
| `findutils-test-gnulib.patch` | Link the xargs test against gnulib. | Candidate: findutils. |
| `rsync-exclude-timestamps.patch` | Set identical timestamps for the equal-age test files. | Submitted: [rsync #1120](https://github.com/RsyncProject/rsync/pull/1120). Remove when the pinned release includes the fix; [reproducer](../tests/upstream/rsync-timestamps.py). |
| `gnumake-tests-shell.patch` | Test the Nixpkgs PATH-based default shell. | Candidate: Nixpkgs first; distinguish packaging from make behavior. |
| `krb5-openbsd-shared.patch` | Link shared libraries with the compiler driver. | Candidate: MIT Kerberos. |
| `libuv-openbsd-tests.patch` | OpenBSD kqueue and network-error expectations. | Candidate: libuv tests. |
| `mandoc-pledge.patch` | Replace the removed tmppath promise. | Candidate: mandoc; compare OpenBSD's version and errata first. |
| `nix-openbsd-ptsname.patch` | Use the locked ptsname fallback. | Candidate: Nix; retire after the pinned source supports OpenBSD. |
| `doctest-openbsd.patch` | Identify OpenBSD in platform tests. | Candidate: doctest. |
| `toml11-openbsd-hexfloat.patch` | Parse hex floats with strtof/strtod. | Candidate: toml11; separately investigate OpenBSD sscanf behavior. |
| `psutil-openbsd-no-swap.patch` | Handle a system with no swap devices. | Candidate: psutil; compare current implementation before submitting. |
| [libcxx-openbsd-test-features.patch](../tests/native/libcxx-openbsd-test-features.patch) | Report unsupported locale, quick_exit and thread-limit tests. | Split into three LLVM test changes. Preserve C/UTF-8 coverage when excluding regional formatting; avoid making missing quick_exit silently acceptable on platforms that promise it. |

## LLVM review

Checked LLVM main `4bd435d59f89`, LLVM 23.1.3 and PR #200940 at `e518ff874288`
on OpenBSD/amd64 on 2026-10-17. The installed LLVM 21 headers pass 42 compile/run
checks. These are focused probes; the full upstream suites were not rerun.
Keep LLVM 21.1.8 for now: 23.1.3 still needs the header fixes and encoding backport.

- Start with the libc++abi futex constants, then child-specific reaping in
  LLVM Support. The timeout redesign needs separate review: process-wide alarms
  are unsafe with concurrent waits, but fixed 10 ms polling also has a cost.
- The [#200940](https://github.com/llvm/llvm-project/pull/200940) follow-up fixes
  a repeated C++03 module-map path and a 0/1 configuration flag tested with
  `defined`. A similar proposal,
  [#216069](https://github.com/llvm/llvm-project/pull/216069), was closed in its favor.
- [#165086](https://github.com/llvm/llvm-project/pull/165086) handles compiler-rt
  multilib detection. Our recipe already selects the default target only.
- [#212979](https://github.com/llvm/llvm-project/pull/212979) handles Clang's libc++
  include search. Check header provenance when reproducing failures; our compiler
  wrapper supplies the libc++ store include path.
- LLDB process fixes [#122534](https://github.com/llvm/llvm-project/pull/122534)
  and [#205768](https://github.com/llvm/llvm-project/pull/205768) do not replace
  LLVM Support's wait fix. LLDB is outside our current native toolchain.
- The missing locale-encoding function from
  [#224954](https://github.com/llvm/llvm-project/pull/224954) is covered by merged
  [#228306](https://github.com/llvm/llvm-project/pull/228306). Its
  [release backport](https://github.com/llvm/llvm-project/pull/232746) targets LLVM 23,
  not our LLVM 21 pin.

## Packaging and integration

| Area | Destination / next step |
| --- | --- |
| [Package overrides](../pkgs/openbsd/package-overrides.nix) | Nixpkgs for dependencies and build settings; package upstream for source defects. Keep bootstrap cycle handling separate. |
| Zlib shared-library detection | Track [zlib #960](https://github.com/madler/zlib/issues/960). Remove `--undefined-version` when shared-library detection and the [probe](../tests/upstream/zlib-shared.py) pass without it. |
| [Native stdenv](../pkgs/openbsd/native-stdenv.nix) and [libtool hook](../pkgs/openbsd/fix-libtool.sh) | Nixpkgs compiler wrappers, hooks and BSD scopes. Validate bootstrap closure independence after changes. |
| [Nix runtime overrides](../pkgs/openbsd/nix-runtime-overrides.nix) | Nix for PTY, build-user and fork handling. Submit separately with focused tests. |
| [Native Nix dependencies](../pkgs/openbsd/native-nix.nix) and [system packages](../pkgs/openbsd/native-system-packages.nix) | Nixpkgs for package recipes and dependencies. Keep disabled tests distinct from correctness fixes. |
| [Version, dev.db and service startup fixes](../upstream/nixbsd/README.md) | Three proposed NixBSD patches with regression checks. Keep local adapters until the updated dependency passes FreeBSD evaluation and OpenBSD runtime tests. |
| [Boot overlay](../overlays/openbsd.nix), [system module](../modules/system/openbsd.nix), [services](../modules/services) | NixBSD for system integration; OpenBSD for base-source defects. Preserve service start, check and stop behavior. |
| [Generation manager](../modules/system/generations.nix) | Keep locally while stabilizing switching, failure recovery, rollback and reboot behavior. |
| [VM assembly](../vm/native.nix) | General image support to NixBSD / Nixpkgs. Demo and test-runner policy stay here. |

## Working order

1. Submit small, independently tested fixes.
2. Retire backports as source updates make them unnecessary. Keep kernel, libc
   and headers compatible.
3. Replace local integration adapters with tested NixBSD support.
4. Simplify bootstrap code after package and integration changes settle.

Keep source updates, refactoring and behavior changes separate. Check affected
packages before removing a workaround; use closure checks for bootstrap changes
and VM tests for service, activation and boot changes. See [testing](testing.md).
