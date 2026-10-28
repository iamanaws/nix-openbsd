# Native build isolation

Native Nix runs OpenBSD builds as `nixbld` users with `sandbox = false`.
Build users prevent root execution but leave unrelated readable files and
network access available.

Nix 2.34.8's [builder factory](https://github.com/NixOS/nix/blob/2.34.8/src/libstore/unix/build/derivation-builder.cc)
has Linux and macOS sandbox backends. On OpenBSD, `sandbox = true` rejects all
builds. `relaxed` rejects ordinary builds but permits fixed-output builds through
the existing unsandboxed path. `sandbox-fallback = true` adds no backend.

## Native proof

```sh
nix run .#test -- --suite isolation
nix run .#test -- --suite isolation --vm-state ./openbsd-native-vm --keep
```

The proof uses the pinned OpenBSD 8.0 kernel in a disposable VM. It is not an
installed launcher or production sandbox.

| Mechanism | Result |
| --- | --- |
| Plain `unveil` | Denies access before exec, then resets in the executed program. |
| Inherited pledge promises with `unveil` | Persists restrictions on this kernel, but aborts an existing native utility whose control run succeeds. |
| `chroot` and dropped privileges | Rejects unrelated paths, absolute symlinks and parent traversal across exec. Inputs are read-only, outputs writable, root privileges unrecoverable. Networking remains available. |
| Private routing domain plus chroot | Separates IPv4/IPv6 from the original domain. Both domains can use the same loopback ports. Unprivileged workers cannot restore domain 0. |

Compiler checks build and run C, C++, Go and cgo consumers inside the filesystem
and network proof. Regular-user daemon controls build the same consumers, fetch
fixed-output content over both IP versions, and read an outside fixture during
an ordinary unsandboxed build. Unsupported sandbox requests must fail before
their builder starts, including when fallback is requested.

The [unveil](https://man.openbsd.org/OpenBSD-8.0/unveil.2) inheritance experiment
depends on this kernel's `PS_EXECPLEDGE` handling, not a general exec contract.
Inherited [pledge promises](https://man.openbsd.org/OpenBSD-8.0/pledge.2) can alter
or terminate arbitrary tools; compiler checks do not use that combination.

The [chroot](https://man.openbsd.org/OpenBSD-8.0/chroot.2) fixture changes root and
working directory, clears supplementary groups, drops saved user/group privileges
and closes unrelated descriptors before exec. Input closures use hard links,
with copying across filesystems. The fake store is sticky; outputs have a
separate writable directory. Its loader comes from the declared compiler wrapper,
without a host `/usr/libexec/ld.so` dependency.

The fixture enters [routing domain](https://man.openbsd.org/OpenBSD-8.0/rdomain.4)
100 with private loopback before dropping privileges. It removes interfaces
after workers exit. It changes no host network state or PF rules.

## Backend work

A Nix backend still needs:

- Input closures, loader/device/configuration paths, extra sandbox paths and
  output registration without writable access to the real store.
- Domain allocation alongside administrator-owned domains, concurrent builds,
  fixed-output networking and failed setup.
- Complete process cleanup before domain removal. Only 255 nonzero IDs exist;
  removal moves the remaining routing table into domain 0, so surviving workers
  must not gain access.
- Output recovery, failure/cancellation handling, daemon restart, regular-user
  trust rules and separate review of process/IPC access.

The proof establishes controlled filesystem and IP-network behavior. It provides
no process/IPC namespaces and does not enable `sandbox = true`.
