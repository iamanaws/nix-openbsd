# Native build isolation

Native Nix 2.35.2 includes an opt-in OpenBSD sandbox backend. The reference
configuration uses `sandbox = false` and dedicated `nixbld` users. Enabling
the sandbox hides unrelated files and separates ordinary builds' IP networking.

## Configuration

Reserve unused routing-domain IDs exclusively for Nix, at least one per
concurrent ordinary build. For example, after reserving IDs 201–204:

```nix
nix.settings = {
  sandbox = true;
  sandbox-fallback = false;
  sandbox-rdomains = [ "201" "202" "203" "204" ];
  max-jobs = 4;
};
```

Nix requires root and dedicated build users, normally through the daemon.
The OpenBSD module gives each build user a private primary group, retaining
membership in `nixbld` for user discovery. Sandboxed builds use that private
group with no supplementary groups; unsandboxed builds use `nixbld` to write to
the host store. Root, shared and duplicate primary groups are rejected before
a sandboxed builder starts. Activate the account configuration before enabling
the sandbox.

Nix creates and removes the reserved loopback interfaces. Keep these IDs out
of other interface configurations and PF rules that connect domains.
Administrator-owned interfaces are preserved. Invalid, missing or exhausted
pools fail before the builder starts, even with `sandbox-fallback = true`.

| Mode | Fixed-output and `__noChroot` builds |
| --- | --- |
| `sandbox = true` | Fixed-output builds use the filesystem sandbox and daemon networking. `__noChroot` is rejected. |
| `sandbox = relaxed` | Fixed-output and `__noChroot` builds follow Nix's unsandboxed path. Ordinary builds remain sandboxed. |

### Resource limits

Sandboxed builders use their host account's native login class. The module
assigns `nixbld`, with process limits of 512 soft / 1024 hard, matching OpenBSD's
`pbuild` class, and descriptor limits of 512 soft / 1024 hard. Data size inherits
the `default` class; the module adds no memory cap. Adjust these through the
existing login-class options, for example:

```nix
users.classes.nixbld.settings = {
  maxproc = { cur = 256; max = 512; };
  openfiles = { cur = 512; max = 1024; };
  datasize = "4G";
};
```

Activate the account and login-class configuration before enabling the sandbox.
Nix reads `maxproc`, `openfiles` and `datasize` before entering the chroot and
applies them in the builder child before dropping privileges. This includes
strict fixed-output builds. Invalid classes or limits fail before the builder
starts. A class cannot raise the daemon's hard limits; the daemon and cleanup
workers retain their own limits.

Data-size limits also cover Nix's launcher before exec, so leave room for its
allocations. Very small values can prevent the builder from starting.

`maxproc` counts processes per build UID. Descriptor and data-size limits apply
per process. These are not aggregate budgets for an entire build or all
concurrent builds; threads and other shared kernel resources remain outside
these limits.

## Filesystem and lifecycle

The backend follows Nix 2.35's [Linux](https://github.com/NixOS/nix/tree/2.35.2/src/libstore/linux/build),
[Darwin](https://github.com/NixOS/nix/tree/2.35.2/src/libstore/darwin/build) and
[FreeBSD](https://github.com/NixOS/nix/tree/2.35.2/src/libstore/freebsd/build)
structure, reusing Unix build-user locks, credential switching, output
registration and chroot cleanup.

Each private root contains declared input closures, configured sandbox paths,
minimal account databases and selected devices. `/build` and `/tmp` are writable.
Root-owned immutable store files can be hard-linked; other files are copied.
Inputs stay read-only. Host mappings are read-only snapshots, with symlink
traversal through destination parents rejected.

Source parents must be real directories, with absolute, normalized source paths.
Leaf symlinks are preserved. Snapshot copying holds source directories open and
checks file identities before reading; path replacements cannot redirect the
copy. Set-ID files are copied with those bits removed. Mutable file contents can
still change during a copy.

OpenBSD has no bind mounts, so build trees live on the store filesystem for
normal output renames. `--keep-failed` retains the build directory separately
from its copied input closure. Before retaining it, Nix checks its identity
against the directory descriptor opened before the build. Removed or replaced
directories are discarded; this also protects custom build paths under writable
`/tmp`. The default sandbox build path is `/build`.

After build processes exit, Nix clears user-settable
[file flags](https://man.openbsd.org/OpenBSD-8.0/chflags.2) on files owned by that
build UID inside the private root. Immutable and append-only flags therefore
cannot prevent output processing, failed-build retention or cleanup. The walk
uses directory descriptors without following symlinks and leaves other owners'
inodes alone, including hard-linked store inputs. A cleanup error prevents the
routing domain from being released. This does not repair flagged trees left by
an older Nix or an abruptly killed worker.

Before switching build users, Nix closes extra descriptors with native
`closefrom()`. This includes descriptors opened before the daemon's descriptor
limit was lowered, which a loop up to the current limit would miss.

Ordinary builds enter a reserved [routing domain](https://man.openbsd.org/OpenBSD-8.0/rdomain.4)
before dropping privileges, with private IPv4/IPv6 loopback. Nix waits for all
live build-user processes to exit before removing the domain: removal moves
its remaining routing table into domain 0. System V IPC objects owned or created
by the build user are removed with that user's privileges.

Cleanup must succeed before the filesystem cleanup starts, including for
fixed-output builds that have no private routing domain. A failed attempt
leaves the private root intact rather than handling files while build processes
may still be running.

After abrupt worker death, the tagged loopback stays isolated. The next holder
of that UID's lock kills abandoned processes before reclaiming it. Interfaces
owned by another build user or Nix state directory are left alone.

## Limits

Process metadata remains visible; cross-user signals still require permission.
System V IPC follows host UID, GID and mode permissions: private `0600` objects
and other build users' group-only objects are protected. Deliberately public
objects remain accessible. Cleanup removes leftovers without creating an IPC
namespace.

TCP `TIME_WAIT` state can outlive a build; assigning its domain ID to another UID
can delay reuse of the same port, even with `SO_REUSEADDR`.

Unprivileged domain 0 processes can join other domains under OpenBSD's
[setrtable rules](https://man.openbsd.org/OpenBSD-8.0/getrtable.2). Cooperating host
processes or fixed-output builds can reach a build's private IPv4/IPv6 loopback
and relay traffic; PF rules can also connect domains. The backend supports build
purity and controlled native builds, with no complete boundary against
cooperating hostile processes.

Recursive Nix, UID ranges and diverted stores fail explicitly.

Nix's PTY supervisor and IPC cleanup helper close extra descriptors and lock
unveil with all paths hidden. Their policies apply after forking, so the daemon
and build programs keep their own filesystem access. These helpers remain
unpledged: even `stdio tty` rejects the supervisor's `tcdrain()` ioctl, and pledge
does not permit System V IPC cleanup.
Policy setup errors fail the helper rather than continuing unrestricted. IPC
cleanup is marked complete only after the helper succeeds, so a failed attempt
is retried before routing-domain removal. The parent must have no existing
unveil rules: denying `/` does not revoke separately unveiled subpaths.

The external-builder launcher pledges `stdio exec` before rewriting arguments
and environment, following OpenBSD's `doas` pattern. Nix leaves exec promises
unset, so successful exec starts the build program unpledged. Builtin builders
run before this policy. The unpledged supervisor drains errors after the
builder fork; setup errors before that fork drain locally. A failed pledge or
exec reports an error and exits without launching another program.

The process-kill helper closes extra descriptors and pledges `stdio proc` after
switching to the build UID. It can signal that user's processes without keeping
filesystem or socket access. The parent keeps its own descriptors and policy;
a failed pledge reports cleanup failure.

Build processes do not inherit a blanket
[pledge](https://man.openbsd.org/OpenBSD-8.0/pledge.2) or
[unveil](https://man.openbsd.org/OpenBSD-8.0/unveil.2) policy. On the pinned 8.0
kernel, pledge's `execpromises` preserve unveil restrictions across exec.
Even broad promise sets deny System V IPC and routing sockets, including
operations available to an ordinary build user. The `error` promise returns
`ENOSYS` instead of terminating the process; it does not restore these APIs.
Locking inherited unveil also prevents native `ifconfig` from setting its own
rules. Leaving it unlocked lets a child reveal hidden paths again. C/C++/Go/cgo
consumers pass under the tested policy, but that does not make it compatible
with arbitrary build tools.

## Tests

Run daemon integration checks in a private copy of a stopped native VM:

```sh
nix run .#test -- --suite isolation
nix run .#test -- --suite isolation --vm-state ./openbsd-native-vm --keep
```

The temporary daemon enables sandboxing only inside its disposable VM.
Local checks and isolation-fixture preparation also compile the patch's snapshot
methods in a small C++ harness with adapters for Nix utilities. Nine probes cover
source replacement, FIFO swaps, directory descriptors, symlinks, permissions and
immutable-file links. These focused probes do not replace daemon integration.
The native suite also compiles the helpers from their patches and runs 55
focused probes before starting its temporary daemon. They check PTY output,
exit codes, signals and interrupted waits; IPC ownership and cleanup; locked
unveil, inherited rules and fork inheritance; descriptors above a lowered
limit; injected rule/lock failures and real prelocked policies; cleanup retries;
launcher restrictions, successful binary/script exec, argument/environment
transfer, exec errors and pledge setup failure; and Nix's descriptor cleanup
after lowered soft/hard limits, chroot and exec. Descriptor checks also cover
standard streams, repeated cleanup and an injected interrupted close. Cleanup
transaction checks include retrying a failed file-flag cleanup.
The PTY supervisor runs as a build user. The supervision flag, launcher policy
and child error path are extracted from the patch; descriptor cleanup comes from
the patched Nix source.
Nix exception types, process wrappers and error reporting use small adapters;
these probes do not validate Nix's full runtime under pledge.

Fourteen native cleanup probes run directory replacements as a build user inside
a chroot, then exercise the extracted OpenBSD and shared cleanup methods.
They cover symlinks, changed directory identities, missing paths, normal
retention and forced cleanup. Two controls check process-cleanup failure and
retry without a private routing domain. Filesystem adapters use one filesystem
and no pending outputs; full daemon checks also exercise replaced build directories.

Fourteen native file-flag probes compile the patch's traversal and active-root
guard. A chrooted build user sets flags before exiting; checks cover files,
inaccessible directories, symlinks, FIFOs, hard links, protected host/input
inodes and cleanup failures. Small utility adapters exercise native chmod,
chown, rename and deletion after cleanup. Full daemon checks cover flagged
outputs and failed builds with and without `--keep-failed`.

Ten native process-kill probes compile Nix's patched `killUser` function with
small process, logging and exception adapters. They cover empty UIDs, detached
and stopped processes, other users' processes, descriptors above a lowered
limit, forbidden file/socket calls, interrupted signals and setup failures.

Checks cover filesystem escapes, undeclared inputs, read-only host mappings,
account lookups, descriptors at builder entry, private IPv4/IPv6 loopback,
C/C++/Go/cgo consumers, fixed-output fetches and strict/relaxed policy. Boundary
probes check IPC permissions between concurrent builds, invalid primary-group
rejection, process visibility and domain 0 host access.
Exec-policy probes check inheritance through several execs, native utility
compatibility and C/C++/Go/cgo builds inside a regular user's sandboxed build.
Resource probes check native login-class precedence, inherited hard ceilings,
process/descriptor/data exhaustion, cancellation cleanup at exhausted limits
and compiler consumers with a finite data-size limit.
Lifecycle checks cover concurrency, exhausted pools, failures, retained
directories, timeouts, IPC cleanup and abandoned workers. Cancellation repeats
four times on the same UID and domain, each with 16 detached descendants and
three IPC objects. See [recorded results](status.md).

The separate `sandbox-packages` suite builds Hello, fmt, inih, MarkupSafe, shfmt
and dbmate from their native Nixpkgs recipes with fresh outputs. Five additional
projects cover stdenv tools, Autotools/Libtool regeneration, CMake/CTest, Meson
and Python wheel/C-extension packaging. Native API checks include process pools,
threads, file locks, mmap, Unix sockets, descriptor passing, private IPv4/IPv6
loopback and SQLite WAL. The suite preserves recipe checks, verifies concurrent
build isolation and exercises installed outputs as a regular user. See
[tool and workflow coverage](testing.md#development-runs).

The `sandbox-nix` suite rebuilds Nix and all its internal libraries under the
sandbox, then runs native runtime, PTY, isolation and fresh package checks with
the rebuilt CLI and daemon. The compiler and external dependencies are reused.
