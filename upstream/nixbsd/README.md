# NixBSD fixes for review

Three independent patches against pinned NixBSD `c292e27`.
They are not applied here; local adapters remain active.

| Patch | Change | Adapter to retire after updating the pin |
| --- | --- | --- |
| [version-revision.patch](version-revision.patch) | Substitute known installer revisions and preserve unknown ones. | Version wrapper in [nixpkgs.nix](../../modules/system/nixpkgs.nix). |
| [rc-dev-db.patch](rc-dev-db.patch) | Create `/var/run`; leave `dev.db` to `dev_mkdb` on OpenBSD. | Rc substitution in [openbsd.nix](../../modules/system/openbsd.nix). |
| [rc-start-failure.patch](rc-start-failure.patch) | Return startup errors before `postStart` on OpenBSD. | Network `rc_start` override in [openbsd.nix](../../modules/system/openbsd.nix). |

With Nix, Git, Bash and Python 3, run from the project root:

```sh
python3 tests/upstream/nixbsd.py
```

Checks patch a temporary source copy and test both BSD version substitutions,
directory creation and startup status. Each fails before patching and passes
afterward. They build no packages or modify repository files.

Before retiring adapters, validate FreeBSD evaluation and OpenBSD boot,
service startup and shutdown with the updated pin. Submit patches separately.
