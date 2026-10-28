# nix-openbsd

Build packages and configure OpenBSD with Nix, using a
[custom NixBSD branch](https://github.com/iamanaws/nixbsd).
The native amd64 VM includes Nix, a native stdenv and an SMP kernel.
Personal configurations support live updates and rollback.

This is experimental. Builds use separate users without sandboxing.
See [status and limitations](docs/status.md).

## Quick start

On x86_64 Linux with KVM and Nix flakes enabled:

```sh
nix run github:iamanaws/nix-openbsd#native-vm
```

The flake includes `nix-openbsd.cachix.org` as an optional binary cache to save
build time. A trusted cache can supply modified outputs, so only use it if you
trust me.

Log in as `bestie` with password `toor`, then run inside OpenBSD:

```sh
nix run github:iamanaws/nix-openbsd#hello
```

It prints `Hello, world!`. The VM has public test credentials; keep it off
untrusted networks. See [VM details](docs/vm.md) for SSH, shutdown, tagged
releases and experimental ARM Linux/macOS launchers.

## Documentation

| Guide | Contents |
| --- | --- |
| [VM](docs/vm.md) | Hosts, releases, resources and persistent state. |
| [Configuration](docs/configuration.md) | Personal systems, live updates and rollback. |
| [Networking](docs/networking.md) | DHCP, SLAAC, DNS proposals, routing and VPNs. |
| [Services](docs/services.md) | Directories, doas, local mail and maintenance. |
| [Modules](modules/README.md) | Module integration and service handlers. |
| [Development](docs/development.md) | Native packages, toolchains and build targets. |
| [Testing](docs/testing.md) | Suite selection, fixtures and reports. |
| [Status](docs/status.md) | Recorded results and limitations. |
| [Roadmap](docs/roadmap.md) | Remaining work. |
| [Nix internals](docs/nix-internals.md) | Runtime fixes and bootstrap history. |
| [Build isolation](docs/build-isolation.md) | Native proof and sandbox backend requirements. |
| [Upstream](docs/upstream.md) | Patch owners, review notes and removal criteria. |
