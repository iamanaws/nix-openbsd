# nixopenbsd

Work in progress toward declarative OpenBSD systems with NixBSD.

This repository contains OpenBSD packages, service modules and an experimental
native stdenv. A [custom NixBSD checkout](https://github.com/iamanaws/nixbsd)
provides boot, login, SSH, basic networking and a patched Nix daemon.
The goal is to configure, build and update OpenBSD through NixBSD as we do
Linux through NixOS.

The native stdenv passes VM validation. See the [results and limitations](notes/native-stdenv.md).
The demo is cross-built; native Nix and a native-built system are future work.
This is a development environment. Nix builds use separate users without a sandbox.

## Code and tests

- [Packages and stdenv](pkgs/openbsd) contain OpenBSD utilities, daemons,
  libraries and native build fixes. The [overlay](overlays/openbsd.nix) adds
  the extra OpenBSD packages to Nixpkgs.
- [Modules](modules/README.md) configure networking, web services, VPNs,
  logging and monitoring through NixBSD.
- [Base VM checks](tests/base/run.sh) test DHCP service control, outbound HTTPS,
  MTU and IPv6 routes. Run `bash tests/base/run.sh --max-jobs 1 --cores 8`.
- [Native build tests](tests/native/README.md) rebuild tools and compile
  packages through the Nix daemon as root and an unprivileged client.
- [Network tests](tests/network/README.md) check declarative addresses,
  hostnames, routes, BGP and IPsec between two VMs.
- [Nix on OpenBSD](notes/nix-openbsd.md) records the runtime fixes and tests.

## Run the demo

Use x86_64 Linux with KVM and flakes enabled. The flake uses a
local NixBSD input. Set its path in [flake.nix](flake.nix) to your custom
NixBSD checkout. It inherits that checkout's Nixpkgs pin.

```sh
nix build --accept-flake-config .#vm
./result/bin/run-openbsd-webserver-vm
```

The first build may need to cross-compile packages for OpenBSD. Once the VM
boots, test HTTP or connect over SSH:

```sh
curl http://127.0.0.1:8080/
ssh -p 2222 bestie@127.0.0.1
```

HTTP goes through `relayd` to `httpd`. The demo also enables PF, DNS
configuration, NTP, cron, logging and local monitoring. Routing daemons and
VPNs stay disabled unless a test or configuration enables them.

The test accounts `root` and `bestie` use the password `toor`. Do not expose
the VM or reuse these credentials. The VM stores its state in
`openbsd-webserver.qcow2` in the working directory.

Other build outputs include the minimal VM, system image, system closure
and individual packages:

```sh
nix build .#minimal-vm
nix build .#system-image
nix build .#toplevel
nix build .#libagentx
```

## Binary cache

Use [nix-openbsd.cachix.org](https://nix-openbsd.cachix.org) alongside the
standard Nix cache by accepting the flake's cache settings:

```sh
nix build --accept-flake-config .#minimal-vm
```

The cache contains cross-built seeds and the validated native stdenv, Clang,
LLD and runtimes. Important outputs are pinned. VM images and build history
stay local.

## Next steps

- Build Nix natively on OpenBSD.
- Add live configuration switching, service restarts and rollback through NixBSD.
- Improve disk-image generation and add raw `disk.img` export. The
  [integration notes](notes/nixbsd-integration.md) track these gaps.
- Expand native package builds and tests.
- Extend OpenBSD networking support and tests, including IPv6, routing,
  firewall policies and VPNs.
- Assess the risks of builds without sandboxing and how to isolate them.
- Upstream tested package and stdenv fixes to Nixpkgs, and system support
  and modules to NixBSD where appropriate.
