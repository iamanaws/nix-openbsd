# Develop packages

## Native builds

Git is included in the native VM. Inside OpenBSD:

```sh
git clone https://github.com/iamanaws/nix-openbsd
cd nix-openbsd
nix build .#hello
nix run .#hello
nix run .#jq -- -n '1 + 1'
```

The flake exposes `hello`, `jq`, `curl` and `git`. Builds use cached outputs
when available. `nix develop` provides the native compiler environment.
Use `legacyPackages.x86_64-openbsd` for custom derivations.

[Package recipes](../pkgs/openbsd) contain the stdenv, toolchain and OpenBSD
utilities. The [overlay](../overlays/openbsd.nix) adds OpenBSD packages to
Nixpkgs. The flake pins NixBSD and Nixpkgs separately.
Package coverage remains experimental; see [status](status.md)
and [tests](testing.md).

## Build targets

Run `nix build .#TARGET` from the checkout.

| Target | Build environment | Output |
| --- | --- | --- |
| `hello`, `jq`, `curl`, `git` | OpenBSD | Native packages. |
| `native-nix` | OpenBSD | Native Nix CLI and daemon. |
| `native-system` | OpenBSD | Native reference system and SMP kernel. |
| `native-vm` | Linux | Native VM launcher and image. |
| `native-system-image` | Linux | Standalone native system QCOW2 image. |
| `vm` | Linux | Cross-built reference demo with native Nix. |
| `minimal-vm` | Linux | Minimal bootstrap VM. |
| `system-image`, `toplevel` | Linux | Cross-built reference image and system closure. |
| `libagentx` | Linux | Example cross-built OpenBSD package. |

Image assembly needs the native system closure locally or in the cache.
The EFI loader is still cross-built.

The cross-built demo is kept as a reference for comparison with NixBSD:

```sh
nix build .#vm
./result/bin/run-openbsd-webserver-vm
```

See [Nix implementation notes](nix-internals.md) for runtime fixes and
[the integration plan](roadmap.md) for remaining work.
