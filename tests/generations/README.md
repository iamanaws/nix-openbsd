# Native system generations

The tests use one persistent VM disk. They cover boot selection, rollback,
garbage collection and recovery through the boot console. The live fixtures
also check package updates, HTTP content, adding/removing a daemon, unchanged
SSH processes, invalid configurations and recovery after activation or service
startup fails.
Directory checks cover ownership, permissions, drift repair, preserved contents
and recovery when a path cannot be created.
Cron checks cover schedule validation, SQLite writes as a locked service account,
reload failure recovery and rollback without restarting cron or rerunning `@reboot` jobs.
Building the fixtures with `withCronctl = false` tests automatic reload without
the helper; parser checks and the injected reload failure are omitted in that mode.
NTP checks use loopback peers and cover configuration validation, restart failures,
stopped services, rollback and persistence after reboot. They do not test clock accuracy.

Run from the project root on x86_64 Linux:

```sh
nix run .#test -- --suite generations
nix run .#test -- --suite cron-fallback
nix run .#test -- --suite dns
nix run .#test -- --suite dns --live-only
```

The runner builds and transfers the fixtures automatically. See the
[testing guide](../../docs/testing.md) for prepared VMs, logs and resource limits.

DNS checks use a local server and cover lookups, resolver-file updates,
blocklist reloads, cache preservation,
failed-update recovery, stopped services and rollback across reboots. They do not
test DNSSEC validation.

Local failure tests need Bash, jq, GNU coreutils and Python:

```sh
python3 -m unittest discover -s tests/generations -p 'test_*.py'
```

Use `--suite workflow` to check the personal configuration template and
`openbsd-rebuild` against project inputs. Add `--live-only` to skip reboot, GC
and console recovery. The lower-level `run.py` also supports
`--recovery-state DIR/state` for console recovery.

## Boot-console recovery

Retained generations live under `/nix/var/nix/profiles/system-N-link` and have
boot files in `/boot/nixos/N.conf`. Record the desired generation's store path
before testing boot changes. At the VM's `boot>` prompt, select both its init
and kernel:

```text
set init /nix/store/GENERATION/bin/activate-init-native
boot /nix/store/GENERATION/kernel
```

This changes that boot only. Once logged in, use
`openbsd-rebuild boot --store-path /nix/var/nix/profiles/system-N-link`
to select the retained configuration for future boots.
