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

OpenBSD has no bind mounts, so build trees live on the store filesystem for
normal output renames. `--keep-failed` retains the build directory separately
from its copied input closure. The default sandbox build path is `/build`.

Ordinary builds enter a reserved [routing domain](https://man.openbsd.org/OpenBSD-8.0/rdomain.4)
before dropping privileges, with private IPv4/IPv6 loopback. Nix waits for all
live build-user processes to exit before removing the domain: removal moves
its remaining routing table into domain 0. System V IPC objects owned or created
by the build user are removed with that user's privileges.

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

Recursive Nix, UID ranges and diverted stores fail explicitly. The backend
imposes no generic inherited [pledge](https://man.openbsd.org/OpenBSD-8.0/pledge.2)
policy on arbitrary tools; earlier probes found one broke a native utility.
[unveil](https://man.openbsd.org/OpenBSD-8.0/unveil.2) normally resets on exec.

## Tests

Run daemon integration checks in a private copy of a stopped native VM:

```sh
nix run .#test -- --suite isolation
nix run .#test -- --suite isolation --vm-state ./openbsd-native-vm --keep
```

The temporary daemon enables sandboxing only inside its disposable VM.
Checks cover filesystem escapes, undeclared inputs, read-only host mappings,
account lookups, descriptors at builder entry, private IPv4/IPv6 loopback,
C/C++/Go/cgo consumers, fixed-output fetches and strict/relaxed policy. Boundary
probes check IPC permissions between concurrent builds, invalid primary-group
rejection, process visibility and domain 0 host access.
Lifecycle checks cover concurrency, exhausted pools, failures, retained
directories, timeouts, IPC cleanup and abandoned workers. Cancellation repeats
four times on the same UID and domain, each with 16 detached descendants and
three IPC objects. See [recorded results](status.md).

The separate `sandbox-packages` suite builds Hello, fmt, inih, MarkupSafe, shfmt
and dbmate from their native Nixpkgs recipes with fresh outputs. It preserves
their existing checks, verifies concurrent build isolation and exercises the
installed packages as a regular user. See [suite commands](testing.md#development-runs).

The `sandbox-nix` suite rebuilds Nix and all its internal libraries under the
sandbox, then runs native runtime, PTY, isolation and fresh package checks with
the rebuilt CLI and daemon. The compiler and external dependencies are reused.
