# Upstream work

Keep backports until the pin includes the fix and native checks pass without it.
Candidate fixes need review against upstream sources before submission.

## Local patches

Paths are relative to [pkgs/openbsd](../pkgs/openbsd), except the test patch.
[Native probes](../tests/native/README.md#focused-runtime-probes) check runtime fixes.

| Patch | Purpose | Status / next step |
| --- | --- | --- |
| `libc-no-tags.patch` | Skip libc's ctags database. | Nixpkgs' existing patch refreshed for 8.0; remove when the pin includes it. |
| `fdisk-readonly.patch` | Read partition tables without requiring a boot-code template. | Candidate: OpenBSD. Only load the template for write/interactive operations; validated through the native security report. |
| `rc-boot-phases.patch` | Run NixBSD's ordered services. | Nixpkgs' existing patch refreshed for 8.0; remove when the pin includes it. |
| `gnulib-openbsd-fseeko.patch` | Opaque FILE support. | Gnulib backport for gzip and tar. Remove when each bundles the fix and passes native checks; [compile probe](../tests/upstream/gnulib-fseeko.py). Cross-build success alone is insufficient. |
| `libffi-openbsd-closures.patch` | Closures without RWX mappings. | Scoped adaptation of the [OpenBSD ports fix](https://raw.githubusercontent.com/openbsd/ports/master/devel/libffi/patches/patch-src_closures_c). Keep until upstream avoids RWX and closure tests pass without it. |
| `librthread-private-semaphores.patch` | Separate private futex wakeups after fork. | Candidate: OpenBSD; preserve shared/named semaphore behavior. |
| `libcxxabi-openbsd-futex.patch` | Correct futex operation constants. | LLVM libc++abi: current upstream uses 0/1; OpenBSD requires 1/2. Native guard probe fails before the patch and passes after it. The default guard implementation uses a mutex. |
| `libcxx-openbsd-mbstate.patch` | mbstate declarations without importing overloads. | [LLVM #200940](https://github.com/llvm/llvm-project/pull/200940) fixes the C++17/20 module failure. Frozen C++03 needs our [follow-up](../upstream/llvm/libcxx-mbstate-cxx03.patch); check with the [probe](../tests/upstream/llvm-mbstate.py). Keep the working patch until the replacement passes the full suites. |
| `libcxx-openbsd-locale-headers.patch` | Locale declarations under feature-test macros. | LLVM 23.1.3 still fails with `_XOPEN_SOURCE=500`. Minimize declarations for the new locale API. The merged encoding fix [#228306](https://github.com/llvm/llvm-project/pull/228306) addresses a different failure. |
| `llvm-interpreter-roundeven.patch` | Interpreter support without libm roundeven. | Generic LLVM interpreter fix. Native regression passes all four host rounding modes; see the [probe](../tests/native/llvm-roundeven.cc). Related [#188898](https://github.com/llvm/llvm-project/pull/188898) changes library availability, not interpreter lowering. |
| `llvm-openbsd-wait-timeout.patch`, `llvm-openbsd-wait-timeout-22.patch` | Avoid process-wide alarms and reap the correct child after timeout. | The LLVM 22 variant adjusts include context. Split into generic child-specific reaping and timeout handling. Current upstream retains both problems; [#19243](https://github.com/llvm/llvm-project/issues/19243) is an earlier related report. |
| `llvm-openbsd-cas-sync.patch` | Flush new CAS headers before reading them through another descriptor. | Local fix, not submitted upstream. Reproduced stale reads before `msync`; all 36 CAS tests pass with the fix on OpenBSD 8.0. LLVM 22 only. |
| `llvm-lit-resource-limits.patch` | Detect whether Python provides `RLIMIT_AS`. | Local fix, not submitted upstream. Fixes an observed `AttributeError`; keeps descriptor, stack and file-size checks enabled on OpenBSD. LLVM 22 only. |
| `clang-openbsd-static-pie.patch` | Pass -pie for static PIE links. | Backport of [118efe76](https://github.com/llvm/llvm-project/commit/118efe7680bdc010ab984f8ae4505699f53bbca6); remove after updating Clang and running driver/linking checks. |
| `clang-openbsd-no-pie.patch` | Emit LLD-compatible -no-pie. | Backport of [a2171756](https://github.com/llvm/llvm-project/commit/a2171756dd5d690faf30bafe63810d1dc6cdb342); remove after updating Clang and running driver/linking checks. |
| `lld-openbsd-library-search.patch` | Find OpenBSD's `libfoo.so.major.minor` libraries. | Adapted from OpenBSD with explicit target selection and sysroot handling; [lookup probe](../tests/upstream/lld-openbsd.py). Keep bootstrap symlinks while older linkers remain in use. |
| `clang-openbsd-lld-emulation.patch` | Select LLD's OpenBSD target. | Local companion to the library lookup patch; GNU ld retains its existing arguments. Native driver and lookup probes pass. |
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
| `sqlite-utils-batch-test.patch` | Wait for a batch commit in the subprocess test. | Test timing adjustment; remove when sqlite-utils uses bounded waiting instead of a one-second sleep. |
| [libcxx-openbsd-test-features.patch](../tests/native/libcxx-openbsd-test-features.patch) | Report unsupported locale, quick_exit and thread-limit tests. | Split into three LLVM test changes. Preserve C/UTF-8 coverage when excluding regional formatting; avoid making missing quick_exit silently acceptable on platforms that promise it. |

## LLVM review

The 2026-10-17 review checked LLVM main `4bd435d59f89`, LLVM 23.1.3 and
PR #200940 at `e518ff874288` on OpenBSD/amd64. Installed LLVM 21 headers passed
42 compile/run probes; full upstream suites were not rerun. Keep userland
21.1.8 and kernel 22.1.8. LLVM 23.1.3 still needed headers and encoding fixes.

- Submit futex constants, then child-specific reaping. Review timeout handling
  separately; process-wide alarms conflict with concurrent waits, while fixed
  10 ms polling has a cost.
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
- The OpenBSD LLD lookup adaptation passes native probes for target selection,
  version ordering, search paths, static links and sysroots. Keep bootstrap
  library symlinks while older linkers remain in use, and keep Libtool's loader
  detection separate.

## Packaging and integration

| Area | Destination / next step |
| --- | --- |
| [Package overrides](../pkgs/openbsd/package-overrides.nix) | Nixpkgs for dependencies and build settings; package upstream for source defects. Keep bootstrap cycle handling separate. |
| Zlib shared-library detection | Track [zlib #960](https://github.com/madler/zlib/issues/960). Remove `--undefined-version` when shared-library detection and the [probe](../tests/upstream/zlib-shared.py) pass without it. |
| [Native stdenv](../pkgs/openbsd/native-stdenv.nix) and [libtool hook](../pkgs/openbsd/fix-libtool.sh) | Nixpkgs compiler wrappers, hooks and BSD scopes. Validate bootstrap closure independence after changes. |
| [Nix runtime overrides](../pkgs/openbsd/nix-runtime-overrides.nix) | Nix for PTY, build-user and fork handling. Submit separately with focused tests. |
| [OpenBSD build isolation](build-isolation.md) | Nix builder backend: integrate the native filesystem/network proof with input/output handling, concurrent builds and routing-domain lifecycle. Keep sandboxing disabled until that backend is validated. |
| [Native Nix dependencies](../pkgs/openbsd/native-nix.nix) and [system packages](../pkgs/openbsd/native-system-packages.nix) | Nixpkgs for package recipes and dependencies. Keep disabled tests distinct from correctness fixes. |
| [Native Go](../pkgs/openbsd/native-go.nix) and [bootstrap](../pkgs/openbsd/go-bootstrap.nix) | Nixpkgs for the OpenBSD ports bootstrap and store library paths. Go's direct OpenBSD `-nopie` linker option needs the LLD-compatible `-no-pie` spelling; review separately for Go upstream. |
| [dhcpleased and slaacd dependencies](../overlays/nixbsd.nix) | Nixpkgs: OpenBSD 8.0 uses libutil's `getexecpath` to re-execute these daemons. |
| DHCP DNS renewal | OpenBSD follow-up: `dhcpleased` records renewed DNS servers, but publishes a resolver proposal only when acquiring or reacquiring the lease. This integration preserves that behavior. |
| [sysctl startup](../modules/system/openbsd.nix) | NixBSD: OpenBSD's `sysctl -f` does not accept FreeBSD's `-i` flag. |
| [Static IPv6 startup](../modules/system/openbsd.nix) | NixBSD: follow OpenBSD `netstart`'s bounded DAD wait before starting daemons that bind static IPv6 addresses. Native BGP boot reproduced the bind failure without it. |
| [BGP, IKE and PF rc hooks](../modules/services) | Keep configuration checks in `rc_configtest`, following OpenBSD's daemon scripts, so invalid restarts preserve running daemons. PF reloads rules through `pfctl`. Native routing tests cover both IP versions and recovery. |
| [Version, dev.db and service startup fixes](../upstream/nixbsd/README.md) | Three proposed NixBSD patches with regression checks. Keep local adapters until the updated dependency passes FreeBSD evaluation and OpenBSD runtime tests. |
| [Boot overlay](../overlays/openbsd.nix), [system module](../modules/system/openbsd.nix), [services](../modules/services) | NixBSD for system integration; OpenBSD for base-source defects. Preserve service start, check and stop behavior. |
| [Generation manager](../modules/system/generations.nix) | Keep locally while stabilizing switching, failure recovery, rollback and reboot behavior. |
| [VM assembly](../vm/native.nix) | General image support to NixBSD / Nixpkgs. Demo and test-runner policy stay here. |

## Working order

1. Submit small, independently tested fixes.
2. Keep source updates, refactoring and behavior changes separate.
3. Preserve compatibility between the kernel, libc and headers.
4. Check bootstrap closures before removing seeds.
5. Run service, activation and boot tests before replacing integration adapters.

See [testing](testing.md) and [cache maintenance](development.md#cache-maintenance).
