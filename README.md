# NixBSD OpenBSD web server

This flake builds an experimental NixBSD OpenBSD VM running the native
OpenBSD `httpd(8)` and `relayd(8)` daemons. The request path is:

```text
host 127.0.0.1:8080 -> guest relayd :80 -> guest httpd 127.0.0.1:8080
```

The OpenBSD programs are packaged locally with the same
`pkgs.openbsd.mkDerivation` conventions as the pinned `bsd-nixpkgs` fork:

- `openbsd.httpd`
- `openbsd.relayd`
- `openbsd.relayctl`
- `openbsd.libagentx`

Local NixBSD modules provide `services.httpd` and `services.relayd`, including
the standard OpenBSD users, chroots, configuration checks, and rc services.

## Run the VM

Enable flakes if they are not already enabled:

```sh
export NIX_CONFIG='experimental-features = nix-command flakes'
```

Build the VM runner:

```sh
nix build --accept-flake-config .#vm
```

The native daemon packages are not yet in the NixBSD cache, so Nix must
cross-compile them for OpenBSD. The rest of the VM may be downloaded from the
upstream cache; review that cache before accepting the flake configuration.

Start the VM:

```sh
./result/bin/run-openbsd-webserver-vm
```

In another terminal, wait for the guest to finish booting and then test it:

```sh
curl http://127.0.0.1:8080/
```

Inside the guest, inspect relayd with:

```sh
relayctl show summary
ps axww | grep -E '[h]ttpd|[r]elayd'
```

SSH is also forwarded to localhost port 2222:

```sh
ssh -p 2222 demo@127.0.0.1
```

The inherited demonstration accounts are `root` and `demo`; their
demonstration password is `toor`. Do not expose this VM or reuse those
credentials for a real machine.

VM state is stored in `openbsd-webserver.qcow2` in the current directory.
Delete that file to start again from a fresh disk image.

## Other outputs

Build the native OpenBSD packages individually:

```sh
nix build --accept-flake-config .#libagentx
nix build --accept-flake-config .#httpd
nix build --accept-flake-config .#relayd
nix build --accept-flake-config .#relayctl
```

Build the installable system image:

```sh
nix build --accept-flake-config .#system-image
```

Build only the configured system closure:

```sh
nix build --accept-flake-config .#toplevel
```

## Upstreaming

The derivations under `pkgs/openbsd/` are intentionally shaped like files
under `pkgs/os-specific/bsd/openbsd/pkgs/` in `bsd-nixpkgs`. The service
modules follow NixBSD's `init.services` interface, which is converted to
generated OpenBSD `rc.d` scripts. This keeps the package and module changes
easy to split into separate upstream pull requests.
