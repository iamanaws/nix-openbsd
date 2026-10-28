# OpenBSD modules

Native configurations use `lib.mkNativeSystem` from this flake.
The [template](../templates/native-system) supplies native packages and the
generation manager; choose services in `configuration.nix`.
See [service usage](../docs/services.md) and [networking](../docs/networking.md)
for options, examples and precautions.

For other NixBSD configurations, import the required [service modules](services)
and apply the [OpenBSD package overlay](../overlays/openbsd.nix).
They use `init.services` to generate rc.d scripts, declare users and directories,
and validate configuration where the daemon supports it.
[flake.nix](../flake.nix) contains the reference demo.

[OpenBSD integration](system/openbsd.nix) supplies PF defaults, DHCP, SLAAC,
MTU and IPv6 routes. It applies only to OpenBSD; the adapters remain local pending
upstream compatibility checks. See [upstream work](../docs/upstream.md).

## Live service handlers

The local generation manager supports selected service changes. Add handlers
through `openbsd.system.services`; see
[generations.nix](system/generations.nix) for built-in checks, reloads and restarts.
Unhandled changes require reboot. Validate startup, failed activation, rollback
and reboot with the [generation tests](../tests/generations/README.md).
