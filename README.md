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
nix run github:iamanaws/nix-openbsd#native-vm
```

When Nix asks about the cache URL and signing key, answer `y` to accept each
setting and `y` again to remember it. Do this once per user on each system.

Linux assembles the image from cached packages. When the console shows
`login:`, log in as **bestie**, password **toor**.

Inside OpenBSD, build and run hello:

```sh
nix build github:iamanaws/nix-openbsd#hello
nix run github:iamanaws/nix-openbsd#hello
uname -srm
```

You should see `Hello, world!` and `OpenBSD 7.9 amd64`. No checkout is needed.
These commands use cached packages when available; `nix build` does not force
compilation. The first run also fetches sources and build inputs, which can
take a few minutes. To try another package:

```sh
nix run github:iamanaws/nix-openbsd#jq -- -n '1 + 1'
```

This prints `2`. Native package outputs include `hello`, `jq`, `curl` and `git`.

Alternatively, connect over SSH from another terminal on the Linux host:

```sh
ssh -p 2222 bestie@127.0.0.1
```

The web service is at http://127.0.0.1:8080/ on the host, through `relayd` to
`httpd`. The VM also enables PF, DNS configuration, NTP, cron, logging and
local monitoring.
The test accounts `root` and `bestie` both use `toor`. Do not expose
the VM or reuse these credentials.

To stop the VM:

```sh
shutdown -p now
```

If the guest is unresponsive, press **Ctrl+A**, release, then **X** to quit
QEMU immediately. This is a forced stop, so prefer a clean shutdown.

The VM defaults to 2 virtual CPUs and 4 GiB RAM. To give it 8 CPUs and 8 GiB RAM:

```sh
NIX_VM_CORES=8 NIX_VM_MEMORY=8192 nix run github:iamanaws/nix-openbsd#native-vm
```

Set these when starting the VM; shut it down first if it is already running.
Nix builds use the CPUs available inside the guest, one package at a time.
State lives in `openbsd-native-vm/`;
its `base-image` link keeps the backing image safe from garbage collection.
Set `NIX_VM_STATE_DIR` to use another directory. `NIX_VM_CORES`,
`NIX_VM_MEMORY` (MiB), `NIX_VM_HTTP_PORT` and `NIX_VM_SSH_PORT` override defaults.
VM disk traffic is capped at 40 MiB/s reads and 20 MiB/s writes.
`NIX_VM_DISK_READ_BPS` and `NIX_VM_DISK_WRITE_BPS` override these limits in bytes/s.
These limits apply to the running VM; image builds run through the host Nix daemon.
Rebuilding the launcher preserves existing state. Update that VM from inside
OpenBSD using system generations below.

To start fresh, shut down the VM, then run these on the host from the directory
where you launched it. This deletes the VM and all files saved inside it:

```sh
rm -rf openbsd-native-vm/
nix run --refresh github:iamanaws/nix-openbsd#native-vm
```

## Update the native system

From a nix-openbsd checkout inside OpenBSD (see [development](#develop-packages-inside-openbsd)),
build the system, then run the activation commands as root:

```sh
nix build .#native-system
./result/bin/switch-to-configuration dry-activate
./result/bin/switch-to-configuration test
./result/bin/switch-to-configuration switch
```

`dry-activate` checks and previews changes. `test` applies them for the current
boot. `switch` also selects the configuration for future boots.
Packages, HTTP and relayd support live updates. Other services can opt in through
`openbsd.system.services`. Kernel, filesystem, networking and unhandled service
changes require a reboot:

```sh
./result/bin/switch-to-configuration boot
shutdown -r now
```

An older VM needs one reboot into the new system before it can switch live.

List generations or return to the previous one:

```sh
openbsd-system list
openbsd-system rollback --live
```

For rollback at the next boot, use `openbsd-system rollback` and reboot.
Append a generation number to select a specific retained generation.
After a temporary `test`, return to the boot selection with
`openbsd-system test /nix/var/nix/profiles/system`.

Failed live updates attempt to restore the previous configuration and services.
Logs are in `/var/log/openbsd-system.log`. Rollback covers packages and
configuration, not application data. See the [generation tests](tests/generations/README.md)
for coverage and boot-console recovery.

## Develop packages inside OpenBSD

Git is included in the VM. To edit packages locally:

```sh
git clone https://github.com/iamanaws/nix-openbsd
cd nix-openbsd
nix build .#hello
nix run .#hello
```

From this checkout, `nix develop` provides the native compiler environment.
The `.#native-system` commands above also run from this directory.

The native package set is exposed as `legacyPackages.x86_64-openbsd` for
custom derivations. Package coverage is still experimental; the
[validation notes](notes/native-stdenv.md) describe what has been tested.

From Linux, run the fresh-VM development and restart test with:

```sh
nix run .#test-native-vm
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
nix build .#native-nix
```

The experimental `native-system` target builds the system packages and SMP
kernel with the native stdenv. Run inside OpenBSD:

```sh
nix build .#native-system
```

The `vm` target is the original cross-built demo with native Nix:

```sh
nix build .#vm
./result/bin/run-openbsd-webserver-vm
```

`native-system-image` builds the standalone QCOW2 image. Image assembly runs
on Linux and requires the native system closure locally or in the cache.
The EFI loader is still cross-built. See [validation results](notes/native-stdenv.md).

## Binary cache

Use [nix-openbsd.cachix.org](https://nix-openbsd.cachix.org) alongside the
standard Nix cache. Accept and remember the flake's cache settings when prompted,
as described above. The VM already configures these caches for its daemon.

The cache contains cross-built seeds and the validated native system, Nix,
stdenv, Clang, LLD and runtimes. Important outputs are pinned. VM images and build history
stay local.

## Next steps

- Extend live updates to more services and networking changes.
- Improve disk-image generation and add raw `disk.img` export. The
  [integration notes](notes/nixbsd-integration.md) track these gaps.
- Expand native package builds and tests.
- Extend OpenBSD networking support and tests, including IPv6, routing,
  firewall policies and VPNs.
- Assess the risks of builds without sandboxing and how to isolate them.
- Upstream tested package and stdenv fixes to Nixpkgs, and system support
  and modules to NixBSD where appropriate.
