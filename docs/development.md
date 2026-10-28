# Develop packages

Inside the native VM:

```sh
git clone https://github.com/iamanaws/nix-openbsd
cd nix-openbsd
nix build .#hello
nix run .#hello
nix run .#jq -- -n '1 + 1'
```

Builds reuse cached outputs when available. `nix develop` provides the native
compiler environment; use `legacyPackages.x86_64-openbsd` for custom derivations.

[Recipes](../pkgs/openbsd) define the stdenv, toolchain and OpenBSD utilities.
The [overlay](../overlays/openbsd.nix) extends Nixpkgs. NixBSD and Nixpkgs are
pinned separately. See [Nix internals](nix-internals.md) for runtime fixes and
[tests](testing.md) for validation.

## Native targets

Build with `nix build .#TARGET` inside OpenBSD. Packages with commands also
support `nix run .#TARGET -- ARGS`.

| Target | Contents |
| --- | --- |
| `hello`, `jq`, `curl`, `git` | Basic native package examples. |
| `sqlite`, `sqlite-utils`, `tmux` | Database tools and terminal multiplexer. |
| `go`, `shfmt` | Go toolchain and a formatter built with the Nixpkgs Go recipe. |
| `slaacd`, `slaacctl` | Native IPv6 autoconfiguration and controls. |
| `libevent`, `fmt` | C event and C++ formatting libraries. |
| `python3` | Python with zlib, ctypes, SSL and SQLite. |
| `python-cffi` | Python with CFFI and setuptools for extension builds. |
| `native-nix` | Native Nix CLI and daemon. |
| `native-system` | Reference system with an SMP kernel. |

Other base tools, including DHCP, are under
`legacyPackages.x86_64-openbsd.openbsd`.

For example:

```sh
nix run .#sqlite -- :memory: 'select sqlite_version();'
nix run .#sqlite-utils -- memory 'select 1 + 1 as result'
nix run .#go -- version
nix run .#python-cffi -- -c 'from cffi import FFI; print(FFI().sizeof("void *"))'
```

CFFI extensions should use
[`extern "Python"` callbacks](https://cffi.readthedocs.io/en/stable/using.html#extern-python-new-style-callbacks).
Legacy `ffi.callback()` requires memory permissions OpenBSD rejects.

## Host build targets

These run on Linux:

| Target | Output |
| --- | --- |
| `native-vm` | Native launcher and image; experimental launchers also exist on [other hosts](vm.md#hosts). |
| `native-system-image` | Native QCOW2 image. |
| `vm` | Cross-built reference demo with native Nix. |
| `minimal-vm` | Bootstrap VM. |
| `system-image`, `toplevel` | Cross-built reference image and system closure. |
| `libagentx` | Example cross-built OpenBSD package. |

Image assembly needs the native closure locally or in the cache. EFI remains
cross-built. To run the cross-built reference demo:

```sh
nix build .#vm
./result/bin/run-openbsd-webserver-vm
```

## Cache maintenance

Publication is manual.

1. Publish validated outputs. Copy native outputs and dependencies into the
   publishing host's store first.
2. Use [cache-bundle.nix](../tools/cache-bundle.nix) to retain packages,
   documentation, tools, bootstrap seeds and sources. Exclude VM images,
   launchers and build history.
3. Preserve release pins, including `openbsd-8.0` and `openbsd-8.0-packages`.
   Future releases get separate versioned tags and pins.
4. Use the `main` pin with `--keep-revisions 1` to retain the latest development
   bundle until replaced. Retire obsolete development pins with one day of
   retention; release retirement is separate.
