# Status and limitations

Recorded VM runs validate the native stdenv, Nix 2.35.2, packages and SMP kernel
on amd64 OpenBSD 8.0. Native runtime closures contain no declared bootstrap seed
outputs. EFI remains cross-built.

Fresh-image boot and reboot passed on 2026-10-25, including all 11 configured
services, console/SSH login, HTTPS, a regular-user build and store integrity.
Generation checks passed live updates, failed-update recovery, rollback, GC and
boot-console recovery. Local mail and maintenance passed all five generation
phases on 2026-10-27.

See [tests](testing.md) for workflow coverage and [VM hosts](vm.md#hosts) for
launcher validation.

## Recorded suite results

These are saved run results, not a new full-suite validation on every commit.
A cached test can reuse their outputs.

| Component | Result and scope |
| --- | --- |
| Nix 2.35.2 | Signed cache downloads, store verification, daemon restart, GC and PTY checks locally and through the regular-user daemon passed. |
| [Nix sandbox](build-isolation.md) | All 17 integration phases passed on 2026-10-28: filesystem/network isolation, C/C++/Go/cgo consumers, daemon policy, concurrency, cancellation, timeouts, detached children, IPC cleanup and worker recovery. |
| LLVM 22 X86 `check-all` | 36,274 passed; 34,443 unsupported; 62 expected failures; 414 skipped. LLVM 21 had one lit timeout that passed twice alone, without a full rerun. |
| Clang and LLD | Full suites disabled; focused compile/link and OpenBSD library-search checks pass. Userland uses LLVM 21.1.8; the kernel uses 22.1.8. |
| libffi | 1,750 passed. |
| fmt, CFFI, libevent | 21 fmt groups and ten selected CFFI `extern "Python"` tests pass. Libevent uses [test adjustments](../tests/packages/default.nix). |
| sqlite-utils | 1,458 passed, 16 skipped. Two Hypothesis modules excluded because native Rust is unavailable. |
| Go 1.26.8 | 249 standard-library packages pass in short mode; 112 have no tests. Pure Go, SQLite cgo and regular-user builds pass. Shfmt 3.14.1 passes packaged tests. |
| libc++abi | 58 passed, 22 unsupported. |
| libc++ | 9,948 passed, 782 unsupported, 49 expected failures. Includes all 393 header-visibility tests. Floating-point atomic stress runs serially to fit OpenBSD's thread table. |

## Limitations

| Area | Remaining limits |
| --- | --- |
| Isolation | Sandboxing is opt-in and disabled by default. Process/IPC namespaces and TCP state remain shared; see [platform limits](build-isolation.md#limits). |
| Hosts | ARM Linux and Apple Silicon launcher runtime checks are pending. |
| Nix | Full upstream suites have not run. BLAKE3 uses its non-TBB implementation. |
| Toolchains | Go `cmd`, race and non-short standard tests have not run. Compiler-rt coverage is limited to builtins, excluding sanitizers. |
| libc++ | OpenBSD has C-locale formatting and UTF-8 conversion; regional locale and missing `quick_exit` tests are unsupported. |
| Networking | DHCP renewals record DNS changes but refresh proposals on reacquisition. SLAAC ignores advertised search domains. See [networking](networking.md). |
| Routing/VPNs | BGP and PSK IKEv2 are tested; OSPF, RIP, IKEv1, certificates, timed rekeying and live network switching are not. |
| DNS/NTP | Local fixtures do not validate DNSSEC or clock accuracy. |
| Mail | Local Unix-socket delivery only; custom TCP listeners, relaying, TLS and filters are unvalidated. |
| Maintenance | No root-device backups, accounting or optional rdist validation. Mtree does not verify the store. |
| Other packages | Bootstrap Perl disables crypt to break its libxcrypt cycle. Texinfo uses its Perl parser. Nixpkgs disables full coreutils checks on BSD; GNU make skips one `/bin/echo` test. AgentX exchanges are untested. |

Package coverage remains experimental. [Upstream work](upstream.md) tracks local
fixes; [the roadmap](roadmap.md) lists remaining integration work.
