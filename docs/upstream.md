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
| `libcxxabi-openbsd-futex.patch` | Correct futex operation constants. | Candidate: LLVM libc++abi. |
| `libcxx-openbsd-mbstate.patch` | mbstate declarations without importing overloads. | Candidate: LLVM libc++. |
| `libcxx-openbsd-locale-headers.patch` | Locale declarations under feature-test macros. | LLVM libc++; adapt to the moved upstream locale code before submission. |
| `llvm-interpreter-roundeven.patch` | Interpreter support without libm roundeven. | Candidate: LLVM. |
| `llvm-openbsd-wait-timeout.patch` | Avoid process-wide alarms and reap the correct child after timeout. | Candidate: LLVM; rebuilt library passes check-all and native wait checks. |
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
| [libcxx-openbsd-test-features.patch](../tests/native/libcxx-openbsd-test-features.patch) | Report unsupported locale, quick_exit and thread-limit tests. | Candidate: LLVM test configuration; retain explicit unsupported results. |

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
