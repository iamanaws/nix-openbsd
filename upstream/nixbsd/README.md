# NixBSD fixes for review

Three independent patches against the pinned NixBSD `c292e27`. They are not
applied by this project; the working local adapters remain in place.

| Patch | Scope | Local adapter to retire after updating the pin |
| --- | --- | --- |
| [version-revision.patch](version-revision.patch) | Shared installer tools: substitute known revisions and preserve unknown revisions. | Version wrapper in `modules/system/nixpkgs.nix`. |
| [rc-dev-db.patch](rc-dev-db.patch) | OpenBSD only: create `/var/run`, leaving `dev.db` for `dev_mkdb`. | Rc source substitution in `modules/system/openbsd.nix`. |
| [rc-start-failure.patch](rc-start-failure.patch) | OpenBSD only: return daemon startup errors before `postStart`. | Network `rc_start` override in `modules/system/openbsd.nix`. |

Run from the project root, with Nix, Git, Bash and Python 3 available:

```sh
python3 tests/upstream/nixbsd.py
```

The checks apply the patches to a temporary copy of the pinned source. They
exercise version substitutions for both BSD platforms, directory creation, and
startup-hook exit statuses. Each check fails on the original and passes after
patching. No packages are built or repository files modified by the checks.

These are host-side regression checks, not BSD VM tests. Before removing the
adapters, validate the updated pin with FreeBSD evaluation and OpenBSD boot,
service startup and shutdown tests. Submit each patch separately.
