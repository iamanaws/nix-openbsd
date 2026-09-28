# nix-openbsd

Build packages and configure OpenBSD with Nix, using a
[custom NixBSD branch](https://github.com/iamanaws/nixbsd).
The native VM includes Nix, a native stdenv, system packages and an SMP kernel.
It supports personal configurations, live updates and rollback.

This is experimental. Builds use separate users without sandboxing.
See [validation and limitations](docs/status.md).

## Quick start

On x86_64 Linux with KVM and Nix flakes enabled:

```sh
nix run github:iamanaws/nix-openbsd#native-vm
```

Accept and remember the cache settings when prompted. Log in as `bestie`
with password `toor`, then run inside OpenBSD:

```sh
nix build github:iamanaws/nix-openbsd#hello
nix run github:iamanaws/nix-openbsd#hello
```

The result is `Hello, world!`. Packages use the cache when available.
The VM has public test credentials; do not expose it to untrusted networks.

## Documentation

- [Run the VM](docs/vm.md): login, resources, persistent state and cache.
- [Configure the system](docs/configuration.md): personal configurations, updates and rollback.
- [Service modules](modules/README.md): networking, web services, logging and more.
- [Develop packages](docs/development.md): native builds, package sets and build targets.
- [Run tests](docs/testing.md): VM, package, network and generation checks.
- [Status](docs/status.md) and [next steps](docs/roadmap.md).
