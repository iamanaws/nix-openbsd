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

Builds use cached outputs when available. `nix develop` provides the native
compiler environment.
Use `legacyPackages.x86_64-openbsd` for custom derivations.

For example, inside OpenBSD:

```sh
nix run .#sqlite -- :memory: 'select sqlite_version();'
nix run .#tmux -- -V
nix run .#python3 -- -c 'import sqlite3, ssl; print(sqlite3.sqlite_version, ssl.OPENSSL_VERSION)'
nix run .#python-cffi -- -c 'from cffi import FFI; print(FFI().sizeof("void *"))'
```

`python3` includes zlib, ctypes, SSL and SQLite.
`python-cffi` adds CFFI and setuptools for extension builds. Use `nix develop` for
the compiler. Use CFFI's [`extern "Python"` callbacks](https://cffi.readthedocs.io/en/stable/using.html#extern-python-new-style-callbacks);
legacy `ffi.callback()` requires memory permissions that OpenBSD rejects.

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
| `sqlite`, `tmux` | OpenBSD | Database CLI and terminal multiplexer. |
| `libevent`, `fmt` | OpenBSD | C event library and C++ formatting library. |
| `python3`, `python-cffi` | OpenBSD | Python, or Python with CFFI and setuptools. |
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
