# Patch ownership and cleanup

Audit of `e826602`, 2026-09-28. The lock uses NixBSD `c292e27` and Nixpkgs
`dc29ee8`; OpenBSD sources come from `OPENBSD_7_9_BASE`. Moving an upstream
branch does not change those inputs.

This inventory covers all 22 local patch files and the main inline overrides.
Destinations are proposed owners, not claims that a change is ready to merge.
Unless evidence is linked below, current upstream status still needs checking.
No workaround is cleared for removal by this audit alone.

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

- **difftime:** the local patch matches OpenBSD commit
  [b018fff](https://github.com/openbsd/src/commit/b018fffbd6c97a22e7af2d20e7fa5ba61fdbfb36).
  Keep it until the selected source contains that fix and negative-timestamp tests pass.
- **gnulib fseeko:** [upstream includes the OpenBSD 7.8+ branch](https://raw.githubusercontent.com/coreutils/gnulib/master/lib/fseeko.c).
  Check the bundled gnulib in gzip, tar and findutils separately before removing the backport.
- **libffi closures:** [OpenBSD ports carries the dual-mapping workaround](https://raw.githubusercontent.com/openbsd/ports/master/devel/libffi/patches/patch-src_closures_c).
  Compare the complete patches and libffi versions before choosing one source for the fix.
- **libc++abi futex:** [LLVM main still uses literal operation numbers](https://raw.githubusercontent.com/llvm/llvm-project/main/libcxxabi/src/cxa_guard_impl.h).
  The local constants fix is a candidate for LLVM, with a focused contention test.
- **rc_start failure propagation:** [NixBSD main still runs postStart after an unchecked rc_exec](https://raw.githubusercontent.com/nix-community/nixbsd/main/modules/system/boot/init/portable/openbsd.nix).
  Keep the local guard until the service adapter handles this correctly.
- **Static PIE and cross builds:** [Nixpkgs PR #552510](https://github.com/NixOS/nixpkgs/pull/552510)
  is already open. Track that work rather than submit a duplicate. Even after
  merging, verify the pinned package recipes and generated binaries before deleting overlays.

## Local patch files

Paths below are relative to [pkgs/openbsd](../pkgs/openbsd), except the test patch.
“Candidate” means retain pending upstream comparison, a reproducer and validation.

| Patch | Purpose | Disposition / owner |
| --- | --- | --- |
| `libc-difftime.patch` | Negative timestamps. | Backport; retire after source update. OpenBSD. |
| `gnulib-openbsd-fseeko.patch` | Opaque FILE support. | Backport; retire per consumer update. Gnulib. |
| `libffi-openbsd-closures.patch` | Closures without RWX mappings. | Reuse verified OpenBSD ports fix; libffi / Nixpkgs. |
| `librthread-private-semaphores.patch` | Separate private futex wakeups after fork. | Candidate: OpenBSD; preserve shared/named semaphore behavior. |
| `libcxxabi-openbsd-futex.patch` | Correct futex operation constants. | Candidate: LLVM libc++abi. |
| `libcxx-openbsd-mbstate.patch` | mbstate declarations without importing overloads. | Candidate: LLVM libc++. |
| `libcxx-openbsd-locale-headers.patch` | Locale declarations under feature-test macros. | Candidate: LLVM libc++; check against OpenBSD headers. |
| `llvm-interpreter-roundeven.patch` | Interpreter support without libm roundeven. | Candidate: LLVM. |
| `llvm-openbsd-wait-timeout.patch` | Thread-safe child timeout handling. | Candidate: LLVM; test timeout, exit status and child cleanup. |
| `lld-openbsd-nopie.patch` | Accept the OpenBSD Clang driver's -nopie. | Candidate: LLVM driver/linker compatibility. |
| `gnulib-openbsd-case-mapping.patch` | Consistent Unicode case conversion. | Candidate: gnulib; consumed by grep. |
| `diffutils-openbsd-pipes.patch` | Do not treat anonymous pipes as the same file. | Candidate: gnulib; consumed by diffutils. |
| `findutils-test-gnulib.patch` | Link the xargs test against gnulib. | Candidate: findutils. |
| `gnumake-tests-shell.patch` | Test the Nixpkgs PATH-based default shell. | Candidate: Nixpkgs first; distinguish packaging from make behavior. |
| `krb5-openbsd-shared.patch` | Link shared libraries with the compiler driver. | Candidate: MIT Kerberos. |
| `libuv-openbsd-tests.patch` | OpenBSD kqueue and network-error expectations. | Candidate: libuv tests. |
| `mandoc-pledge.patch` | Replace the removed tmppath promise. | Candidate: mandoc; compare OpenBSD's version and errata first. |
| `mklocale-pledge.patch` | Build the locale generator outside OpenBSD. | Keep as cross-build adaptation; Nixpkgs. |
| `doctest-openbsd.patch` | Identify OpenBSD in platform tests. | Candidate: doctest. |
| `toml11-openbsd-hexfloat.patch` | Parse hex floats with strtof/strtod. | Candidate: toml11; separately investigate OpenBSD sscanf behavior. |
| `psutil-openbsd-no-swap.patch` | Handle a system with no swap devices. | Candidate: psutil; compare current implementation before submitting. |
| [libcxx-openbsd-test-features.patch](../tests/native/libcxx-openbsd-test-features.patch) | Report unsupported locale, quick_exit and thread-limit tests. | Candidate: LLVM test configuration; retain explicit unsupported results. |

## Overrides outside patch files

These matter as much as the patch count. Review inline substitutions, disabled
checks and dependency overrides when updating a package.

| Location | Work to separate | Destination / removal condition |
| --- | --- | --- |
| [package-overrides.nix](../pkgs/openbsd/package-overrides.nix) | Shared package fixes: iconv/FTS dependencies, header generation, ncurses triples, Tcl/Expect linking, config.guess and tests. | Propose each to Nixpkgs or the package upstream. Stage-only cycle breaking stays in native-packages.nix. |
| [native-stdenv.nix](../pkgs/openbsd/native-stdenv.nix), [fix-libtool.sh](../pkgs/openbsd/fix-libtool.sh) | Wrapper flags, resource directories, loader paths and library names. | Nixpkgs stdenv/hooks; compare generic cc/bintools wrappers and clangUseLLVM before adding helpers. |
| [native-nix.nix](../pkgs/openbsd/native-nix.nix) | PTY, build-user and atfork patches imported from NixBSD; CPU detection, terminal, stack and trusted-key handling inline. | Nix runtime changes to Nix. Share patch selection with cross packaging; test signed-cache trust and failed builders. |
| [native-nix.nix](../pkgs/openbsd/native-nix.nix) dependency scope | Boehm linker script, bmake, unzip, Boost flags, BLAKE3 without TBB and disabled Meson checks. | Nixpkgs / individual projects; keep test exclusions distinct from correctness fixes. |
| [native-system-packages.nix](../pkgs/openbsd/native-system-packages.nix) | Kernel compiler selection and source edits, LibreSSL CPU detection, jq timezone tests, Git expectations, Python splicing and disabled documentation. | Recipe changes to Nixpkgs; kernel defects to OpenBSD. Remove only after native kernel/package tests. |
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
   remain in native-packages.nix. Patch locations and overlay order are unchanged.
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
