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
nix run .#sqlite-utils -- memory 'select 1 + 1 as result'
nix run .#tmux -- -V
nix run .#go -- version
nix run .#shfmt -- --version
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
| `sqlite-utils` | OpenBSD | Import, query and export SQLite data with Python. |
| `go`, `shfmt` | OpenBSD | Go compiler and tools, and the shell formatter built with Go. |
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

## Cache maintenance

Each validated release gets a versioned Git tag and Cachix pins. The current
release uses `openbsd-8.0` and `openbsd-8.0-packages`. Create new tags and pins
for future OpenBSD versions, and update the [VM guide](vm.md#releases).
Preserve existing release pins while developing `main`.

Publish validated development builds under a separate `main` pin, keeping its
latest revision. Give obsolete development pins one day of retention when
retiring them. Retire an older release only as a separate decision.

### Publish a bundle

Publication is manual. A [bundle](../tools/cache-bundle.nix) links to selected
store outputs; pinning it protects their dependency closures. Include packages,
documentation, toolchains, build tools, bootstrap seeds and sources. Leave VM
images, launchers and build history out.

Save `nix build --json` results from the validated builds. With `jq` and `cachix`
available, collect their outputs and publish from the checkout:

```sh
jq -s '[.[][] | .outputs[]] | unique' build-results.json > /tmp/cache-roots.json
nix build --impure --file tools/cache-bundle.nix \
  --argstr rootsFile /tmp/cache-roots.json --out-link /tmp/cache-bundle
bundle=$(readlink -f /tmp/cache-bundle)
cachix push --jobs 2 --num-concurrent-chunks 1 nix-openbsd "$bundle"
cachix pin nix-openbsd main "$bundle" --keep-revisions 1
```

Pass additional result files to `jq` to combine builds. Native outputs and their
dependencies must be copied from the guest into the publishing machine's store
first. The bundle recipe groups outputs; it does not build or test packages.
Keep the output list with the build records.

For a release, use its new versioned pin name instead of `main`.
`--keep-revisions 1` preserves the latest bundle until replaced; it does not
expire after one day. See [Cachix pins](https://docs.cachix.org/pins).
