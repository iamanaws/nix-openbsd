# nixopenbsd

Work in progress toward declarative OpenBSD systems with NixBSD.

This repository contains OpenBSD packages, service modules and an experimental
native stdenv. A [custom NixBSD checkout](https://github.com/iamanaws/nixbsd)
provides boot, login, SSH, basic networking and a patched Nix daemon.
The goal is to configure, build and update OpenBSD through NixBSD as we do
Linux through NixOS.

The native stdenv and Nix pass VM validation. See the [results and limitations](notes/native-stdenv.md).
The native VM includes native Nix, system packages and an SMP kernel.
This is a development environment. Nix builds use separate users without a sandbox.

## Code and tests

- [Packages and stdenv](pkgs/openbsd) contain OpenBSD utilities, daemons,
  libraries and native build fixes. The [overlay](overlays/openbsd.nix) adds
  the extra OpenBSD packages to Nixpkgs.
- [Modules](modules/README.md) configure networking, web services, VPNs,
  logging and monitoring through NixBSD.
- [Base VM checks](tests/base/run.sh) test service control, outbound HTTPS,
  MTU, IPv6 routes and network startup failures.
  Run `bash tests/base/run.sh --max-jobs 1 --cores 8`.
- [Native build tests](tests/native/README.md) rebuild tools and compile
  packages through the Nix daemon as root and an unprivileged client.
- [Network tests](tests/network/README.md) check declarative addresses,
  hostnames, routes, BGP and IPsec between two VMs.
- [Nix on OpenBSD](notes/nix-openbsd.md) records the runtime fixes and tests.

## Run the native VM

Use x86_64 Linux with KVM and flakes enabled. The flake pins the custom
NixBSD branch and inherits its Nixpkgs pin.

```sh
nix run --accept-flake-config .#native-vm
```

Linux assembles the image from the cached native system. Once it boots,
test HTTP or connect over SSH:

```sh
curl http://127.0.0.1:8080/
ssh -p 2222 bestie@127.0.0.1
```

HTTP goes through `relayd` to `httpd`. The demo also enables PF, DNS
configuration, NTP, cron, logging and local monitoring. Routing daemons and
VPNs stay disabled unless a test or configuration enables them.

The test accounts `root` and `bestie` use the password `toor`. Do not expose
the VM or reuse these credentials.

The VM uses 8 CPUs and 4 GiB RAM. State lives in `openbsd-native-vm/`;
its `base-image` link keeps the backing image safe from garbage collection.
Set `NIX_VM_STATE_DIR` to use another directory. `NIX_VM_CORES`,
`NIX_VM_MEMORY` (MiB), `NIX_VM_HTTP_PORT` and `NIX_VM_SSH_PORT` override defaults.
VM disk traffic is capped at 40 MiB/s reads and 20 MiB/s writes.
`NIX_VM_DISK_READ_BPS` and `NIX_VM_DISK_WRITE_BPS` override these limits in bytes/s.
These limits apply to the running VM; image builds run through the host Nix daemon.
Shut down as root with `shutdown -p now` inside the VM.
Rebuilding the launcher preserves existing state; use a new state directory
to boot an updated system. Live switching is not supported yet.

## Build packages inside OpenBSD

As `bestie`, build and run a native package directly from the flake:

```sh
nix build --accept-flake-config github:iamanaws/nix-openbsd#hello
./result/bin/hello
```

Or run it directly:

```sh
nix run --accept-flake-config github:iamanaws/nix-openbsd#hello
nix run --accept-flake-config github:iamanaws/nix-openbsd#jq -- -n '1 + 1'
```

Native package outputs include `hello`, `jq`, `curl` and `git`.
From a local checkout, use `.#hello` instead of the GitHub reference.
`nix develop` provides the native compiler environment for package development.

The native package set is exposed as `legacyPackages.x86_64-openbsd` for
custom derivations. Package coverage is still experimental; the
[validation notes](notes/native-stdenv.md) describe what has been tested.

From Linux, run the fresh-VM development and restart test with:

```sh
nix run --accept-flake-config .#test-native-vm
```

It checks `nix build` and `nix run` as a regular user, services,
HTTP, SSH availability and persistent state. Logs stay in the printed test
directory; successful test disks are removed. Use `-- --keep` to keep them.

## Other targets

Other build outputs include the minimal VM, system image, system closure
and individual packages:

```sh
nix build .#minimal-vm
nix build .#system-image
nix build .#toplevel
nix build .#libagentx
nix build --accept-flake-config .#native-nix
```

The experimental `native-system` target builds the system packages and SMP
kernel with the native stdenv. Run inside OpenBSD:

```sh
nix build --accept-flake-config .#native-system --max-jobs 1 --cores 8
```

The `vm` target is the original cross-built demo with native Nix:

```sh
nix build --accept-flake-config .#vm
./result/bin/run-openbsd-webserver-vm
```

`native-system-image` builds the standalone QCOW2 image. Image assembly runs
on Linux and requires the native system closure locally or in the cache.
The EFI loader is still cross-built. See [validation results](notes/native-stdenv.md).

## Binary cache

Use [nix-openbsd.cachix.org](https://nix-openbsd.cachix.org) alongside the
standard Nix cache by accepting the flake's cache settings:

```sh
nix build --accept-flake-config .#minimal-vm
```

The cache contains cross-built seeds and the validated native system, Nix,
stdenv, Clang, LLD and runtimes. Important outputs are pinned. VM images and build history
stay local.

## Next steps

- Add live configuration switching, service restarts and rollback through NixBSD.
- Improve disk-image generation and add raw `disk.img` export. The
  [integration notes](notes/nixbsd-integration.md) track these gaps.
- Expand native package builds and tests.
- Extend OpenBSD networking support and tests, including IPv6, routing,
  firewall policies and VPNs.
- Assess the risks of builds without sandboxing and how to isolate them.
- Upstream tested package and stdenv fixes to Nixpkgs, and system support
  and modules to NixBSD where appropriate.
