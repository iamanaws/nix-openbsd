# Native system generations

The tests use one persistent VM disk. They cover boot selection, rollback,
garbage collection and recovery through the boot console. The live fixtures
also check package updates, HTTP content, adding/removing a daemon, unchanged
SSH processes, invalid configurations and recovery after activation or service
startup fails.

Build the fixtures inside OpenBSD from the repository root:

```sh
nix build --impure --expr '(import ./tests/generations/fixtures.nix {
  flake = builtins.getFlake ("path:" + toString ./.);
}).all' --max-jobs 1 --cores 8 -o generation-tests
```

Copy that closure to the Linux host. With an existing native VM launcher and
its original system closure available locally, run:

```sh
python3 tests/generations/run.py \
  --launcher "$launcher" --base-system "$base_system" \
  --system-a "$fixtures/a" --system-b "$fixtures/b" \
  --live-fixtures "$fixtures"
```

`fixtures` is the fixture bundle's store path. The harness imports only paths
absent from the base closure and keeps the VM's disk I/O limits. Logs remain
in the printed directory. Successful test disks are removed unless `--keep`
is passed.
Use `--recovery-state DIR/state` to repeat only console recovery on a preserved disk.

Local failure tests need Bash, jq, GNU coreutils and Python:

```sh
python3 -m unittest discover -s tests/generations -p 'test_*.py'
```

## Boot-console recovery

Retained generations live under `/nix/var/nix/profiles/system-N-link` and have
boot files in `/boot/nixos/N.conf`. Record the desired generation's store path
before testing boot changes. At the VM's `boot>` prompt, select both its init
and kernel:

```text
set init /nix/store/GENERATION/bin/activate-init-native
boot /nix/store/GENERATION/kernel
```

This changes that boot only. Once logged in, use `openbsd-system rollback N`
to select the retained generation permanently.
