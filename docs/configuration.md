# Configure the native system

## Create a configuration

Inside the native VM:

```sh
mkdir my-openbsd
cd my-openbsd
nix flake init -t github:iamanaws/nix-openbsd#native-system
```

Edit `configuration.nix` to choose packages, [networking](networking.md) and
[services](services.md). The template uses `lib.mkNativeSystem`, native packages,
and the VM's existing disks and root/bestie accounts. It omits the web demo.

Keep `flake.lock`. Run `nix flake update nix-openbsd` to update the project input.
In a Git checkout, add new configuration files before building.

Build as a regular user, then select and reboot as root:

```sh
nix build .#nixosConfigurations.my-openbsd.config.system.build.toplevel -o result-system
```

```sh
./result-system/bin/switch-to-configuration boot
shutdown -r now
```

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
