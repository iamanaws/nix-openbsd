# Services

Choose services in your [system configuration](configuration.md).
[Modules](../modules/services) generate OpenBSD rc.d services and use each
daemon's native configuration format.

Configuration text enters the readable Nix store. Do not put passwords or VPN
pre-shared keys in these options; runtime file permissions do not protect the
store copy. [Networking](networking.md) covers DHCP, SLAAC, routing and VPNs.

## Service directories

```nix
services.tempfiles.directories."/var/lib/my-service" = {
  mode = "0750";
  user = "my-service";
  group = "my-service";
};
```

Define accounts through `users.users` and `users.groups`.
Directories default to `0755`, owned by `root:wheel`. Boot, live activation and
rollback apply permissions without changing contents. Removing a declaration
leaves the directory and data.

## Administrative commands

Native systems enable `security.doas` through the NixOS module and OpenBSD
authentication. Wheel members authenticate with their own password by default.

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

Rules validate at build and activation. Rule updates support live rollback;
enabling or disabling the privileged wrapper requires reboot.
Set `security.sudo.enable = false` to use only doas.

## Cron and logging

`services.cron.systemCronJobs` declares site-specific jobs. With `cronctl`,
activation validates and reloads schedules immediately without restarting cron
or rerunning `@reboot` jobs. Set `services.cron.controlPackage = null` to omit it.
This also happens when the package set lacks `pkgs.openbsd.cronctl`; cron then
detects updates and rollback at its next minute check, without preflight validation.

`services.newsyslog` runs rotation through cron and prepares files for syslogd;
it starts no daemon. Boot and activation create declared logs as `root:wheel`
with mode `0640`, preserving contents.
See [live update behavior](configuration.md#update) for checks and restarts.

## Local mail

Native systems enable `services.smtpd` for Unix-socket submission and delivery
to `/var/mail/USER`. The default has no TCP listener or outbound relay.
Cron submits output through the wrapped `sendmail`; use `MAILTO` in cron jobs
to select a recipient.

Route administrative mail to an existing account:

```nix
services.smtpd.aliases = ''
  root: alice
  postmaster: root
  MAILER-DAEMON: postmaster
'';
```

Submit with `sendmail alice` or `sendmail -t`, read `/var/mail/alice`, and inspect
pending mail as root with `smtpctl show queue`. Submission while smtpd is stopped
queues the message and returns `EX_TEMPFAIL`, exit code 75. Delivery resumes when
the daemon starts.

Aliases are text tables in the store; no `newaliases` step is needed.
The default smtpd configuration references the generation's table.
Custom `services.smtpd.config` rules must reference `/etc/mail/aliases` if they
use declared aliases. Configuration and alias changes restart smtpd.
Queues and mailboxes survive updates and rollback; delivered mail is not undone.
Privileged wrapper changes require reboot.

## Scheduled maintenance

`services.maintenance` installs and schedules OpenBSD's
[daily, weekly and monthly scripts](https://man.openbsd.org/daily).
It is disabled by default.

```nix
services.maintenance = {
  enable = true;
  daily.config = ''
    CALENDAR=0
    SUIDSKIP="/nix"
  '';
  monthly.schedule = "30 5 1 * *";
  monthly.config = ''
    echo 'Local monthly maintenance'
  '';
};
```

The example disables calendar notifications and skips `/nix` in the daily
setuid/device scan. The daily hook is empty by default.

| Job | Default schedule | Hook |
| --- | --- | --- |
| Daily | 01:30 every day | `services.maintenance.daily.config` writes `/etc/daily.local`. |
| Weekly | 03:30 Saturday | `services.maintenance.weekly.config` writes `/etc/weekly.local`. |
| Monthly | 05:30 on the first day | `services.maintenance.monthly.config` writes `/etc/monthly.local`. |

Schedules use the system timezone and run from `/var/log` with that directory
as `HOME`. Disable an individual job to remove its schedule while retaining its
script for manual use. Its cron entry contains the complete command.
Disabling the module removes scripts and configuration but preserves reports
and backups.

Hooks are verbatim shell fragments, installed as `root` with mode `0600`.
Live updates validate syntax and reload cron. Rollback restores hooks and
schedules. Reports are `/var/log/daily.out`, `weekly.out`, `monthly.out` and
`security.out`, with previous versions ending in `.old`. Nonempty reports go
to root; configure a [mail alias](#local-mail). Monthly has no standard tasks
beyond its hook.

The weekly default `MAKEWHATISARGS=-n` scans manuals without writing into the
Nix store. Replace it with a writable manual directory to rebuild that database.
Locate rebuilds only if `/var/db/locate.database` exists.
The `maintenance-scripts` package supplies scripts and support files;
`calendar`, `locate` and `mail` are separate OpenBSD packages.

OpenBSD's security script checks accounts, homes, mailboxes, setuid files,
devices and configuration changes. `services.maintenance.mtreeConfig` sets its
`/etc/mtree/special` policy, which defaults to mutable account files and local
hooks with NixBSD ownership. It does not verify the store. The module adds no
Nix GC or generation pruning.

## Other services

The demo's SNMP service listens on localhost with a public test community;
query it with `snmp`. QEMU may provide no hardware sensors, so a running
`sensorsd` does not establish that readings work.
[ACME renewal](../modules/security/acme-client.nix) uses cron and needs public
HTTP-01 challenge access. Test with a staging authority first.
