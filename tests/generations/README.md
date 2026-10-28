# System generation tests

From the project root on x86_64 Linux with KVM:

```sh
nix run .#test -- --suite generations
nix run .#test -- --suite dns --live-only
```

The runner prepares and transfers fixtures. Each suite uses a persistent test
disk for live changes, reboot, rollback, GC and console recovery.
See [runner options](../../docs/testing.md) for resources, prepared VMs and logs.

| Suite | Checks |
| --- | --- |
| `generations` | Packages, HTTP, daemon addition/removal, unchanged SSH processes, invalid configurations and activation/startup recovery. Directories check ownership, permissions, drift repair and retained contents. Cron checks SQLite jobs as locked accounts, reload recovery and no repeated `@reboot` jobs. NTP uses loopback peers. |
| `cron-fallback` | Generation fixtures with `withCronctl = false`. Checks automatic minute-based reload; omits parser checks and injected reload failures. |
| `dns` | Local DNS lookups, resolver updates, blocklists, cache preservation and failed-update recovery. |
| `logging` | Delivery, rotation, file creation, stopped services and persistent history. Rotation-only changes preserve syslogd/cron. Equal-size syslog configs with fixed timestamps still trigger restart. |
| `doas` | Passwords, command/argument restrictions, environment handling and rule rollback, with sudo disabled. |
| `mail` | Regular-user submission, aliases, mbox modes, service-account cron output, offline queues and delivery across reboot. Requires no port-25 listener. |
| `maintenance` | Daily/weekly/monthly execution, reports, mail, hook modes, calendar, locate/manual databases, disabled schedules, persistence and console recovery. |
| `workflow` | Personal configuration template and `openbsd-rebuild` against project inputs. |

Service suites also check stopped daemons, failed updates and rollback.
NTP does not measure clock accuracy; DNS does not check DNSSEC.
Only newsyslog rotation rules have a preflight syntax checker; syslogd has none.

Local failure tests require Bash, jq, GNU coreutils and Python:

```sh
python3 -m unittest discover -s tests/generations -p 'test_*.py'
```

`--live-only` skips reboot, GC and console recovery for selected generation
suites. The lower-level `run.py` also accepts `--recovery-state DIR/state`.
For manual rescue, see [boot-console recovery](../../docs/configuration.md#rollback-and-recovery).
