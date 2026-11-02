# Configure the native system

## Create a configuration

Inside the native VM or on a [supported image host](vm.md#hosts):

```sh
mkdir my-openbsd
cd my-openbsd
nix flake init -t github:iamanaws/nix-openbsd#native-system
```

Edit `configuration.nix` to choose packages, [networking](networking.md) and
[services](services.md). The template uses `lib.mkNativeSystem`, native packages,
and the reference disk layout and root/bestie accounts. It omits the web demo.

Keep `flake.lock`. Run `nix flake update nix-openbsd` to update the project input.
In a Git checkout, add new configuration files before building.

Inside OpenBSD, build as a regular user, then select and reboot as root:

```sh
nix build .#nixosConfigurations.my-openbsd.config.system.build.toplevel -o result-system
```

```sh
./result-system/bin/switch-to-configuration boot
shutdown -r now
```

## Build images

The template exports `native-system-image` (QCOW2) and `native-raw-image`
(`disk.img`) on the supported hosts. Set `rootSize` in `flake.nix` to choose the
root filesystem size; the template uses `"24g"`. This sets the size of a new
image. Existing disks retain their size.

For a new image, generate a disk ID (DUID) once:

```sh
od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
```

Use that 16-digit value in both filesystem devices, replacing this example ID:

```nix
{ lib, ... }:
{
  fileSystems."/".device = lib.mkForce "0123456789abcdef.a";
  fileSystems."/boot/efi".device = lib.mkForce "0123456789abcdef.i";
}
```

`lib.mkNativeImages` writes the same DUID into the image's disklabel. Root and
EFI mounts then follow that disk when device numbering changes. Keep the ID
when rebuilding images for that disk; disks attached together need distinct
IDs. When updating an installed system, use its existing DUID from `disklabel`.
The template keeps the reference VM's device paths until these settings are
uncommented.

Build `result-system` inside OpenBSD as above. On the image host, use the same
configuration and lock file, and copy that system closure from the VM. For the
default local SSH port:

```sh
system_path=$(nix eval --raw .#nixosConfigurations.my-openbsd.config.system.build.toplevel.outPath)
nix copy --no-check-sigs \
  --from 'ssh://bestie@127.0.0.1:2222?remote-program=/run/current-system/sw/bin/nix-store' \
  "$system_path"
nix build .#native-raw-image -o result-raw
nix build .#native-system-image -o result-image
```

`--no-check-sigs` permits this copy of your own unsigned build. Image assembly
uses the copied closure or a binary cache; it does not build OpenBSD packages on
the host. macOS uses a matching Linux builder as described in the
[host requirements](vm.md#hosts). Before booting a raw copy, follow the
[random-seed instructions](vm.md#raw-disk-export).

For an existing configuration, `lib.mkNativeImages` takes the result of
`lib.mkNativeSystem`, a host `system` and an optional `rootSize` (default `"12g"`).
It returns `image` and `rawImage`, as used in the
[template](../templates/native-system/flake.nix).

Images use the reference VM's serial console by default. For a keyboard and
display, uncomment this setting in `configuration.nix`, then rebuild the system
and images:

```nix
{ lib, ... }:
{
  boot.loader.stand-openbsd.console = lib.mkForce "pc0";
}
```

This selects the boot console and enables OpenBSD's standard virtual terminals
in [`/etc/ttys`](https://man.openbsd.org/OpenBSD-8.0/ttys.5). Use `"com0"` for
serial boot output and login. Console changes require a reboot. Boot selection
and rollback use each generation's console setting.

## Update

After the first boot, run from your configuration directory:

```sh
openbsd-rebuild build --flake .#my-openbsd
```

As root:

```sh
openbsd-rebuild dry-activate --flake .#my-openbsd
openbsd-rebuild switch --flake .#my-openbsd
```

| Action | Effect |
| --- | --- |
| `build` | Build into `result-system` without activation. |
| `dry-activate` | Check and preview changes. |
| `test` | Apply for the current boot. |
| `switch` | Apply now and select for future boots. |
| `boot` | Select for the next boot without changing the running system. |

All actions except `build` require root. Flake activation proceeds only after
a successful build. Use `--store-path PATH` for an existing build.
To update the reference demo, build `.#native-system` in the project checkout,
then run `openbsd-rebuild ACTION --store-path ./result`. An older VM needs one
boot into the new system before live switching.

| Change | Live behavior |
| --- | --- |
| Packages, httpd, relayd | Supported. |
| `resolvd`, `unwind` | resolvd watches atomic file updates without a syntax checker; unwind validates before reload. |
| NTP | Validate before restart. |
| Cron | Validate and reload without restarting or rerunning `@reboot` jobs. |
| Syslog | Restart; syslogd has no configuration-check mode. |
| Log rotation | Check with `newsyslog -n`; keep syslogd and cron running. |
| Local mail | Validate configuration and restart smtpd. |
| Doas rules | Validate before activation. Wrapper changes require reboot. |
| Kernel, filesystems, networking, privileged wrappers, other services | Use `boot` and reboot. |

Other services can declare [live handlers](../modules/README.md#live-service-handlers).
Log files and [service directories](services.md#service-directories) are prepared
at boot and activation without truncating existing contents.

## Rollback and recovery

As root:

```sh
openbsd-rebuild list-generations
openbsd-rebuild switch --rollback
```

Use `openbsd-rebuild boot --rollback` for rollback at the next reboot.
To choose a specific generation, replace `--rollback` with
`--store-path /nix/var/nix/profiles/system-N-link`.
After a temporary `test`, return to the boot selection with:

```sh
openbsd-rebuild test --store-path /nix/var/nix/profiles/system
```

Failed live updates attempt to restore the previous configuration and services.
Logs are in `/var/log/openbsd-system.log`. Rollback restores packages and
configuration, not application data.

If a selection cannot boot, choose a retained generation at the VM's `boot>`
prompt, using its store path:

```text
set init /nix/store/GENERATION/bin/activate-init-native
boot /nix/store/GENERATION/kernel
```

This affects one boot. After login, select it permanently with
`openbsd-rebuild boot --store-path /nix/var/nix/profiles/system-N-link`.
Boot files live in `/boot/nixos/N.conf`; record a working generation's path
before testing boot changes.
