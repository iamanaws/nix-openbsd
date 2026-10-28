# Native build isolation

Nix 2.34.8 runs native OpenBSD builds as dedicated `nixbld` users, with
`sandbox = false`. Those accounts prevent builds from running as root; they
do not hide unrelated readable files or restrict network access.

The [Nix builder factory](https://github.com/NixOS/nix/blob/2.34.8/src/libstore/unix/build/derivation-builder.cc)
selects sandbox backends for Linux and macOS. On OpenBSD it rejects an ordinary
build with `sandbox = true` or `sandbox = relaxed`. Setting
`sandbox-fallback = true` does not add an OpenBSD backend or make that request
succeed. A fixed-output build with `sandbox = relaxed` follows Nix's existing
unsandboxed path; `sandbox = true` rejects it too.

## Native feasibility checks

Run the private-VM proof through the normal test runner:

```sh
nix run .#test -- --suite isolation
nix run .#test -- --suite isolation --vm-state ./openbsd-native-vm --keep
```

This suite tests the pinned OpenBSD 8.0 kernel and current Nix. It is a test
fixture, not an installed launcher or a production Nix sandbox implementation.
It changes routing state only inside its disposable VM.

| Mechanism | What the proof checks |
| --- | --- |
| Plain `unveil` | Access is denied before `exec`, then becomes available in the executed program. |
| Inherited pledge promises plus `unveil` | Restrictions persist on the pinned kernel, but an existing native utility aborts under the imposed promises while its control run succeeds. |
| `chroot` with dropped builder privileges | Unrelated paths, absolute symlinks and parent traversal remain inaccessible across execution; input files stay read-only, build-directory writes succeed and root privileges cannot be regained. Network access remains available. |
| `chroot` plus a private routing domain | IPv4 and IPv6 listeners in the original domain become unreachable. Private loopback listeners work on the same ports in both domains. The unprivileged process cannot restore its routing table or change a socket back to domain 0. |

The compiler checks build and run C, C++, pure Go and cgo programs inside the
filesystem and network proof. Separate controls build those consumers through
the Nix daemon as a regular user, fetch known fixed-output content over IPv4
and IPv6, and demonstrate an ordinary unsandboxed build reading a public
outside fixture. Unsupported sandbox requests must fail before their builder
starts, including with fallback requested.

The `unveil` inheritance experiment is specific to the pinned kernel's
`PS_EXECPLEDGE` handling. It is not a general execution contract. The
[OpenBSD unveil manual](https://man.openbsd.org/OpenBSD-8.0/unveil.2) describes
application-directed restrictions and their reset on execution. Applying an
inherited [pledge promise set](https://man.openbsd.org/OpenBSD-8.0/pledge.2) to
arbitrary tools can change their syscall behavior or terminate them. The proof
does not use that combination for its compiler checks.

The filesystem proof follows the [chroot privilege requirements](https://man.openbsd.org/OpenBSD-8.0/chroot.2):
enter the new root, change the working directory, clear supplementary groups,
drop all saved user/group privileges and close unrelated file descriptors
before executing the builder. Read-only input closures are hard-linked into
the private root, with copying as a cross-filesystem fallback. The fake store
uses sticky permissions; build outputs have a separate writable directory.
The compatibility loader path points to the declared compiler wrapper's store
loader, without relying on a host `/usr/libexec/ld.so`.

Network separation uses OpenBSD's [routing domains](https://man.openbsd.org/OpenBSD-8.0/rdomain.4)
and [setrtable](https://man.openbsd.org/OpenBSD-8.0/getrtable.2). The fixture
creates domain 100 with its own loopback interface, enters it before dropping
privileges, and removes its interfaces after the workers exit. No PF rules,
host interfaces or external services are changed.

## Nix integration still required

The native primitives need a Nix builder backend before production builds can
use them. That backend must handle:

- Input closure setup, loader/device/configuration paths, additional sandbox
  paths and output registration without exposing the real store for writes.
- Routing-domain allocation that coexists with administrator-owned domains,
  concurrent builds, fixed-output network access and failed setup.
- Complete child-process cleanup before a domain is removed. OpenBSD has at
  most 255 nonzero IDs, and removing a domain moves its remaining routing table
  into domain 0; a surviving process must not gain access through that change.
- Output recovery, build failures, cancellation, daemon restart and regular-user
  trust rules, with separate review of process and IPC access.

The proof establishes filesystem and IP-network behavior for controlled native
builds. It does not establish a complete boundary for hostile build programs,
provide process/IPC namespaces or enable `sandbox = true`.
