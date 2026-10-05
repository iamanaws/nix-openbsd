# Patch ownership and cleanup

Audit started at `e826602`, 2026-09-28. The lock uses NixBSD `c292e27` and Nixpkgs
`8e56e26b`; OpenBSD sources come from `OPENBSD_7_9_BASE`. Moving an upstream
branch does not change those inputs.

This inventory covers the 25 local patch files and the main inline overrides.
Destinations are proposed owners, not claims that a change is ready to merge.
Unless evidence is linked below, current upstream status still needs checking.
Removal decisions and their validation are recorded below.

## Where fixes belong

| Change | Owner |
| --- | --- |
| OpenBSD libc, kernel or base utility defect | OpenBSD src. Check OpenBSD ports for existing third-party fixes too. |
| Nix builder, daemon or CLI defect | Nix. Nixpkgs carries any needed release backport. |
| Package dependencies, build flags, setup hooks, compiler wrappers and native stdenv | Nixpkgs. Source defects go to the affected project's upstream. |
| Boot, activation, rc services, accounts and declarative networking | NixBSD, with FreeBSD and OpenBSD checks. |
| Demo choices, VM test harness and bootstrap validation fixtures | Keep in nix-openbsd. |

NixOS is a reference for module options and command behavior. Its Linux/systemd
implementation is not a replacement for OpenBSD rc and boot handling.

## Confirmed upstream leads

- **Kernel compiler:** [Nixpkgs PR #564604](https://github.com/NixOS/nixpkgs/pull/564604)
  moves `openbsd.sys` from LLVM 18 to 20; it reports failures with LLVM 21+.
  Our override selects the tested native compiler independently of that pin.
  `kernel-clang.patch` backports OpenBSD's fixes for
  [kernel printf attributes](https://github.com/openbsd/src/commit/2f70c1a437bcc2bff242b351d3336b6d7ac1a877),
  [the SCSI sleep identifier](https://github.com/openbsd/src/commit/3c019fcac636f960f981bb0cf7e92433c3c50874)
  and [sensor register selection](https://github.com/openbsd/src/commit/9f06b4d0de89448d55447db96bc04231453a7d12).
  Keep these backports until the pinned source includes them; no new OpenBSD submission is needed.
- **difftime:** the local patch matches OpenBSD commit
  [b018fff](https://github.com/openbsd/src/commit/b018fffbd6c97a22e7af2d20e7fa5ba61fdbfb36).
  Keep it until the selected source contains that fix and negative-timestamp tests pass.
- **gnulib fseeko:** [upstream includes the OpenBSD 7.8+ branch](https://raw.githubusercontent.com/coreutils/gnulib/master/lib/fseeko.c).
  Findutils 4.11.0 includes the fix; its backport was removed on 2026-10-03.
  Gzip 1.14 and tar 1.35 still need it.
- **libffi closures:** [OpenBSD ports carries the dual-mapping workaround](https://raw.githubusercontent.com/openbsd/ports/master/devel/libffi/patches/patch-src_closures_c).
  Compare the complete patches and libffi versions before choosing one source for the fix.
- **libc++abi futex:** [LLVM main still uses literal operation numbers](https://raw.githubusercontent.com/llvm/llvm-project/main/libcxxabi/src/cxa_guard_impl.h).
  On OpenBSD, LLVM 21.1.8's upstream wait assertions fail without the patch;
  the patched syscall and 32-/64-bit guard checks passed on 2026-10-01.
  The [focused probe](../tests/native/README.md#focused-runtime-probes) selects
  futexes explicitly and reduces stress-test concurrency. Keep the fix for LLVM.
- **libc++ headers:** LLVM still lacks the OpenBSD-specific
  [mbstate declaration](https://github.com/llvm/llvm-project/blob/main/libcxx/include/__mbstate_t.h)
  and [locale visibility fixes](https://github.com/llvm/llvm-project/blob/main/libcxx/include/__locale_dir/support/openbsd.h).
  Removing the respective patches from 21.1.8 reproduces duplicate wide-character
  definitions with Clang modules and missing locale declarations under `_XOPEN_SOURCE=500`.
  With both patches, all 28 header-order, feature-macro and module checks passed
  on OpenBSD with C++17/20, 2026-10-01.
  Keep both as LLVM candidates; the locale code has moved upstream, so its patch
  needs adapting before submission. See [focused probes](../tests/native/README.md#focused-runtime-probes).
  Retire each patch when the pinned release passes its probe without it.
- **rc_start failure propagation:** [NixBSD main still runs postStart after an unchecked rc_exec](https://raw.githubusercontent.com/nix-community/nixbsd/main/modules/system/boot/init/portable/openbsd.nix).
  Keep the local guard until the service adapter handles this correctly.
- **LLVM child waits:** [upstream still uses SIGALRM and wait()](https://github.com/llvm/llvm-project/blob/main/llvm/lib/Support/Unix/Program.inc).
  The installed 21.1.8 library reproduced a timeout consuming an unrelated child's
  status and leaving its own child unreaped. The OpenBSD patch now uses
  `waitpid(ChildPid, ...)` with EINTR retries. The rebuilt LLVM passed
  `check-all` and the native exit-status, polling, concurrent-timeout,
  child-ownership and caller-alarm checks on 2026-10-02.
- **LLD -nopie:** [Clang commit a2171756](https://github.com/llvm/llvm-project/commit/a2171756dd5d690faf30bafe63810d1dc6cdb342)
  fixes the driver to emit `-no-pie`. Its backport replaces the local LLD alias.
  [Clang commit 118efe76](https://github.com/llvm/llvm-project/commit/118efe7680bdc010ab984f8ae4505699f53bbca6)
  also supplies the static-PIE driver fix. Both upstream driver tests passed with the rebuilt toolchain on 2026-10-02,
  along with native linking checks and hello, zlib and pigz builds.
- **Interpreter roundeven:** neither [LLVM's interpreter](https://github.com/llvm/llvm-project/blob/main/llvm/lib/ExecutionEngine/Interpreter/Execution.cpp)
  nor [OpenBSD's math header](https://github.com/openbsd/src/blob/master/include/math.h)
  supplies a replacement for this patch. Keep it as an LLVM candidate with its
  existing interpreter regression test, which passed all 26 cases on the
  installed native LLVM 21.1.8, 2026-10-01.
- **Nix terminal handling:** [Nix still limits its `ptsname()` fallback to macOS](https://github.com/NixOS/nix/blob/master/src/libutil/terminal.cc).
  `nix-openbsd-ptsname.patch` replaces the inline edit with identical source.
  Apply from `src/libutil`. The rebuilt Nix 2.34.8 library passed invalid-descriptor,
  distinct-PTY and 16,000 concurrent lookup checks on OpenBSD, 2026-10-01.
- **LibreSSL CPU detection:** [CMake calls `arch -s` on OpenBSD](https://github.com/Kitware/CMake/blob/master/Modules/CMakeDetermineSystem.cmake).
  The upstream [arch utility](https://man.openbsd.org/arch.1) was missing from
  the build environment. [arch.nix](../pkgs/openbsd/arch.nix) packages it without
  source changes; LibreSSL now declares the build dependency. Both packaging
  changes belong in Nixpkgs.
- **Nix CPU detection:** [Meson's CPU probes](https://github.com/mesonbuild/meson/blob/master/mesonbuild/envconfig.py)
  use `platform.processor()` on OpenBSD, which returns the CPU model in our guest.
  `meson-openbsd-cpu.patch` uses `platform.machine()` instead. The patched
  Meson 1.10.2 package passed the native CPU probe; 30 mocked non-OpenBSD cases
  were unchanged. See [focused probes](../tests/native/README.md#focused-runtime-probes).
- **Static PIE and cross builds:** [Nixpkgs PR #552510](https://github.com/NixOS/nixpkgs/pull/552510)
  is included in the new pin, `8e56e26b`. The local
  [adapter](../overlays/nixbsd.nix) selects upstream static PIE, bootloader and
  rc/kernel patches instead of the pinned NixBSD overrides. Base assertions,
  native/demo evaluation, and cross-built seed, kernel, bootloader, rc and makefs
  builds pass. Native rebuild and VM validation are in progress.

## Local patch files

Paths below are relative to [pkgs/openbsd](../pkgs/openbsd), except the test patch.
“Candidate” means retain pending upstream comparison, a reproducer and validation.

| Patch | Purpose | Disposition / owner |
| --- | --- | --- |
| `libc-difftime.patch` | Negative timestamps. | Backport; retire after source update. OpenBSD. |
| `kernel-clang.patch` | Kernel format attributes, SCSI sleep identifier and sensor register selection. | OpenBSD backports; retire after source update and kernel build/boot checks. |
| `gnulib-openbsd-fseeko.patch` | Opaque FILE support. | Backport; retire per consumer update. Gnulib. |
| `libffi-openbsd-closures.patch` | Closures without RWX mappings. | Reuse verified OpenBSD ports fix; libffi / Nixpkgs. |
| `librthread-private-semaphores.patch` | Separate private futex wakeups after fork. | Candidate: OpenBSD; preserve shared/named semaphore behavior. |
| `libcxxabi-openbsd-futex.patch` | Correct futex operation constants. | Candidate: LLVM libc++abi. |
| `libcxx-openbsd-mbstate.patch` | mbstate declarations without importing overloads. | Candidate: LLVM libc++. |
| `libcxx-openbsd-locale-headers.patch` | Locale declarations under feature-test macros. | Candidate: LLVM libc++; check against OpenBSD headers. |
| `llvm-interpreter-roundeven.patch` | Interpreter support without libm roundeven. | Candidate: LLVM. |
| `llvm-openbsd-wait-timeout.patch` | Avoid process-wide alarms and reap the correct child after timeout. | Candidate: LLVM; rebuilt library passes check-all and native wait checks. |
| `clang-openbsd-static-pie.patch` | Pass -pie for static PIE links. | LLVM backport; retire when the pinned Clang includes 118efe76. |
| `clang-openbsd-no-pie.patch` | Emit LLD-compatible -no-pie. | LLVM backport replacing the LLD alias; retire when the pinned Clang includes a2171756. |
| `gnulib-openbsd-case-mapping.patch` | Consistent Unicode case conversion. | Candidate: gnulib; consumed by grep. |
| `diffutils-openbsd-pipes.patch` | Do not treat anonymous pipes as the same file. | Candidate: gnulib; consumed by diffutils. |
| `findutils-test-gnulib.patch` | Link the xargs test against gnulib. | Candidate: findutils. |
| `rsync-exclude-timestamps.patch` | Set identical timestamps for the equal-age test files. | Candidate: rsync tests. |
| `gnumake-tests-shell.patch` | Test the Nixpkgs PATH-based default shell. | Candidate: Nixpkgs first; distinguish packaging from make behavior. |
| `krb5-openbsd-shared.patch` | Link shared libraries with the compiler driver. | Candidate: MIT Kerberos. |
| `libuv-openbsd-tests.patch` | OpenBSD kqueue and network-error expectations. | Candidate: libuv tests. |
| `mandoc-pledge.patch` | Replace the removed tmppath promise. | Candidate: mandoc; compare OpenBSD's version and errata first. |
| `meson-openbsd-cpu.patch` | Detect architecture rather than CPU model. | Candidate: Meson; propose the release backport to Nixpkgs. |
| `nix-openbsd-ptsname.patch` | Use the locked ptsname fallback. | Candidate: Nix; retire after the pinned source supports OpenBSD. |
| `doctest-openbsd.patch` | Identify OpenBSD in platform tests. | Candidate: doctest. |
| `toml11-openbsd-hexfloat.patch` | Parse hex floats with strtof/strtod. | Candidate: toml11; separately investigate OpenBSD sscanf behavior. |
| `psutil-openbsd-no-swap.patch` | Handle a system with no swap devices. | Candidate: psutil; compare current implementation before submitting. |
| [libcxx-openbsd-test-features.patch](../tests/native/libcxx-openbsd-test-features.patch) | Report unsupported locale, quick_exit and thread-limit tests. | Candidate: LLVM test configuration; retain explicit unsupported results. |

## Retired workarounds

- **2026-10-01: kernel source substitutions.** Replaced with the OpenBSD backports
  above, including all sensor configuration writes. The native Clang 21
  `GENERIC.MP` build, VM boot, disk I/O, networking and native compile/run checks
  passed. Physical I2C hardware was not tested. The compiler-selection refactor
  alone preserved the kernel derivation; the cross-built demo remains unchanged.
- **2026-10-01: mklocale-pledge.patch.** The Linux locale generator now uses
  Nixpkgs' `openbsd.compatHook` for pledge and packed-structure declarations.
  The native OpenBSD path keeps its system headers and real pledge call.
  A targeted Linux build produced byte-identical UTF-8 data and license text,
  with no runtime store references. Source pins are unchanged; no VM image was rebuilt.
- **2026-10-01: Nix CPU substitution.** Replaced by the Meson fix above.
  Rebuilt Nix 2.34.8 reports `x86_64-openbsd`. Root and regular-user package
  builds, bootstrap-closure checks, signed-cache download, store verification
  and isolated GC passed. The full upstream Nix suites remain disabled.
- **2026-10-01: LibreSSL CPU source edit.** Added OpenBSD's `arch` as a build
  dependency. The native utility and CMake probes passed, along with all 135
  enabled LibreSSL 4.2.1 tests and an installed `openssl` smoke check.
- **2026-10-01: flock Makefile edit.** Use the upstream `man_MANS` make variable
  to skip documentation. The native executable is byte-identical; exclusive/shared
  locking, timeouts, release/wakeup and child exit-status checks passed.

## Overrides outside patch files

These matter as much as the patch count. Review inline substitutions, disabled
checks and dependency overrides when updating a package.

| Location | Work to separate | Destination / removal condition |
| --- | --- | --- |
| zlib in [package-overrides.nix](../pkgs/openbsd/package-overrides.nix) | Allow unused version-script entries so LLD passes the shared-library probe. | Remove when [zlib #960](https://github.com/madler/zlib/issues/960) is fixed in the pinned source. |
| [package-overrides.nix](../pkgs/openbsd/package-overrides.nix) | Shared package fixes: iconv/FTS dependencies, header generation, ncurses triples, Tcl/Expect linking, config.guess and tests. | Propose each to Nixpkgs or the package upstream. Stage-only cycle breaking stays in native-packages.nix. |
| [native-stdenv.nix](../pkgs/openbsd/native-stdenv.nix), [fix-libtool.sh](../pkgs/openbsd/fix-libtool.sh) | Wrapper flags, resource directories, loader paths and library names. | Nixpkgs stdenv/hooks; compare generic cc/bintools wrappers and clangUseLLVM before adding helpers. |
| [nix-runtime-overrides.nix](../pkgs/openbsd/nix-runtime-overrides.nix) | PTY, build-user and atfork patches imported from NixBSD; terminal fallback patch plus stack and trusted-key edits inline. | Runtime changes to Nix. Share patch selection with cross packaging; test signed-cache trust and failed builders. |
| [native-nix.nix](../pkgs/openbsd/native-nix.nix) dependency scope | Boehm linker script, bmake, unzip, Boost flags, BLAKE3 without TBB, Meson CPU detection and disabled Meson checks. | Nixpkgs / individual projects; keep test exclusions distinct from correctness fixes. |
| [native-system-packages.nix](../pkgs/openbsd/native-system-packages.nix) | Kernel compiler/linker selection, LibreSSL's arch dependency, jq timezone tests, Git expectations, Python splicing and disabled documentation. | Recipe changes to Nixpkgs. Remove only after native kernel/package tests. |
| `native-system-packages.nix` version workaround | Overrides all replaceVarsWith calls to repair nixos-version. | Fix the NixBSD version module; remove the broad helper override. |
| [overlays/openbsd.nix](../overlays/openbsd.nix) | Reboot UID, init session handling, rc boot edits and syslogd's executable path. | Split OpenBSD source defects from Nix store / NixBSD boot adaptations. Keep shutdown and service-control tests. |
| [modules/system/openbsd.nix](../modules/system/openbsd.nix) | Password defaults, activation ordering, PF defaults, mount helpers, dev.db, DHCP checks, MTU/IPv6 and rc_start errors. | NixBSD modules, with scoped platform conditions. Retain local fixes until the pin contains tested equivalents. |
| [service modules](../modules/services) | Package options plus daemon-specific rc behavior. | NixBSD. Standard package options use mkPackageOption; keep daemon-specific users, checks, process patterns and chroots explicit. |
| [generation manager](../modules/system/generations.nix) | Native boot selection, transactions, live-service policy and rollback. | Keep locally for now; eventual NixBSD backend. Preserve locking, GC roots, failure recovery and boot-console recovery. |
| [vm/native.nix](../vm/native.nix) | EFI disklabel, Nix database initialization, image assembly and launcher policy. | General image support to NixBSD / Nixpkgs; resource limits and demo policy can stay local. |

The pinned NixBSD overlay also carries linker-name fixes, static PIE, makefs/mkimg
adaptations and boot patches. Audit those as inherited dependencies without
editing the sibling checkout. The three Nix patches are source-owned by NixBSD
at present, even though their intended upstream is Nix.

## Cleanup order

1. **Package fixes separated.** Shared fixes live in
   [package-overrides.nix](../pkgs/openbsd/package-overrides.nix); bootstrap stages
   remain in native-packages.nix. Nix runtime fixes live in
   [nix-runtime-overrides.nix](../pkgs/openbsd/nix-runtime-overrides.nix), separate
   from its dependency overrides. This split preserved Nix and its 12 checked
   build dependencies. Patch locations and overlay order are unchanged.
2. **Common helpers adopted.** Nineteen service package options use
   `lib.mkPackageOption`; SNMP keeps its dependent package selection. A shared
   [build-tools helper](../pkgs/openbsd/bootstrap-build-tools.nix) preserves each
   stage's compiler-build Python, CMake, Ninja and re2c inputs.
   The 2026-10-01 refactor preserved 26 native package derivations, both system
   derivations, their 32 service scripts and three cross/demo target derivations.
3. **Retire known backports one at a time.** Start with the difftime and gnulib
   leads above. Source updates must keep kernel, libc and header versions compatible.
4. **Prepare small upstream fixes.** Start with package metadata/build fixes and
   isolated source bugs. Keep PTY, fork/thread behavior and activation transactions
   in separate reviews with their regression tests.
5. **Simplify integration last.** Replace rc text rewriting and the global
   replaceVarsWith override with properly scoped NixBSD changes. Keep FreeBSD
   evaluation and OpenBSD runtime coverage before switching the dependency pin.

Use existing Nixpkgs generic stdenv, wrappers, setup hooks and BSD package scopes.
The pinned stdenv selector has no dedicated OpenBSD stages, so the current native
bootstrap cannot simply be replaced by importing the upstream default. FreeBSD's
staged bootstrap is a useful reference, not an interchangeable implementation.

For each removal, record the replacement commit/version and run the affected
regression. Bootstrap edits also need closure checks; service changes need start,
check and stop coverage; activation edits need switch, failure recovery, rollback
and reboot coverage. See [testing](testing.md). Updating a pin, reorganizing code
and changing behavior should be separate changes so failures remain attributable.
