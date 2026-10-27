# Configure the native system

## Create a configuration

Inside the native VM:

```sh
mkdir my-openbsd
cd my-openbsd
nix flake init -t github:iamanaws/nix-openbsd#native-system
```

Edit `configuration.nix` to choose packages and [services](../modules/README.md).
The template uses `lib.mkNativeSystem`, the native package set and the VM's
existing disks and root/bestie accounts. It does not enable the web demo.

Keep `flake.lock` with your configuration. Run `nix flake update nix-openbsd`
to update the project input. If you use Git, add new files before building.

Build as a regular user:

```sh
nix build .#nixosConfigurations.my-openbsd.config.system.build.toplevel -o result-system
```

Then select the system and reboot as root:

```sh
./result-system/bin/switch-to-configuration boot
shutdown -r now
```

## Update

After that first boot, run from your configuration directory:

```sh
openbsd-rebuild build --flake .#my-openbsd
# As root:
openbsd-rebuild dry-activate --flake .#my-openbsd
openbsd-rebuild switch --flake .#my-openbsd
```

With `--flake`, `openbsd-rebuild` builds into `result-system` and activates only
if the build succeeds. `--store-path` and `--rollback` use existing builds.
All actions except `build` require root.

| Action | Effect |
| --- | --- |
| `build` | Build without activation. |
| `dry-activate` | Check and preview changes. |
| `test` | Apply changes for the current boot. |
| `switch` | Apply changes and select them for future boots. |
| `boot` | Select the next boot configuration without changing the running system. |

Packages, HTTP, relayd, DNS, NTP, logging, local mail and cron schedules support live updates.
`resolvd` watches atomic updates to `resolv.conf`; it has no syntax checker.
`unwind` checks its configuration before reloading. NTP checks before restarting.
Cron validates and reloads schedules without restarting or rerunning `@reboot` jobs.
Logging updates restart `syslogd`; it has no configuration-check mode.
Rotation rules are checked with `newsyslog -n`. Updating rotation rules alone
keeps syslogd and cron running. Boot and activation create declared log files as
`root:wheel` with mode `0640`, preserving existing contents.
Other services can opt in through `openbsd.system.services`. Kernel, filesystem,
networking and unhandled service changes require `boot` followed by a reboot.

Set `services.cron.controlPackage = null` to omit `cronctl`. Cron then detects
schedule changes and rollback at its next minute check, without pre-activation
validation. This is also the default when `pkgs.openbsd.cronctl` is absent.

To update the reference demo instead, run `nix build .#native-system` from a
[project checkout](development.md), then run
`openbsd-rebuild ACTION --store-path ./result` as root, using an activation action
from the table. An older VM needs one boot into the new system before live switching.

## Service directories

Declare directories in your configuration:

```nix
services.tempfiles.directories."/var/lib/my-service" = {
  mode = "0750";
  user = "my-service";
  group = "my-service";
};
```

Define the user and group through `users.users` and `users.groups`.
Directories default to `0755`, owned by `root:wheel`. Boot, live activation and
rollback apply their ownership and permissions without changing existing contents.
Removing a declaration leaves its directory and data in place.

## Administrative commands

Native systems enable OpenBSD's `doas`, using the NixOS `security.doas` options.
Members of `wheel` must authenticate with their own password by default.

```nix
security.doas.extraRules = [
  {
    users = [ "alice" ];
    cmd = "/run/current-system/sw/bin/openbsd-rebuild";
    args = [ "list-generations" ];
    noPass = true;
  }
];
```

Rules are checked when building and before live activation. Rule changes support
live updates and rollback. Enabling or disabling the setuid wrapper requires a
reboot. Set `security.sudo.enable = false` if you only want `doas`.

## Local mail

Native systems enable OpenBSD's `smtpd` for local submission and delivery to
`/var/mail/USER`. The default opens a Unix socket and has no TCP listener or
outbound relay. Cron sends job output through the wrapped `sendmail` command;
set `MAILTO` in `services.cron.systemCronJobs` to choose the recipient.

Route administrative mail to an existing account with aliases:

```nix
services.smtpd.aliases = ''
  root: alice
  postmaster: root
  MAILER-DAEMON: postmaster
'';
```

Submit mail with `sendmail alice` or `sendmail -t` and read the user's mbox at
`/var/mail/alice`. `smtpctl show queue` inspects pending delivery as root.
Submission by regular users also queues mail while smtpd is stopped.
OpenSMTPD returns `EX_TEMPFAIL` (75) after offline queuing and processes the
message when the daemon starts again.

Aliases use a text table in the Nix store, so changes need no `newaliases`
command. The default configuration references that generation's table directly.
Use `services.smtpd.config` for a custom smtpd.conf; reference
`/etc/mail/aliases` explicitly if the custom rules need the declared aliases.
Configuration and alias changes restart smtpd during live updates. Queues and
mailboxes persist across updates and rollback; rollback does not undo delivered
mail. Enabling or disabling the privileged wrappers requires a reboot.
Periodic daily, weekly and monthly maintenance jobs are not enabled yet.

## Rollback

As root, list generations or return to the previous one:

```sh
openbsd-rebuild list-generations
openbsd-rebuild switch --rollback
```

For rollback at the next boot, use `openbsd-rebuild boot --rollback` and reboot.
To use a specific older configuration, replace `--rollback` with
`--store-path /nix/var/nix/profiles/system-N-link`.
After a temporary `test`, return to the boot selection with:

```sh
openbsd-rebuild test --store-path /nix/var/nix/profiles/system
```

Failed live updates attempt to restore the previous configuration and services.
Logs are in `/var/log/openbsd-system.log`. Rollback covers packages and
configuration, not application data. See [boot-console recovery](../tests/generations/README.md#boot-console-recovery)
if the selected generation cannot boot.
