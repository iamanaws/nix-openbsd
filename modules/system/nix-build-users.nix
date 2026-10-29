{
  config,
  lib,
  pkgs,
  ...
}:
let
  users = map (nr: "nixbld${toString nr}") (lib.range 1 config.nix.nrBuildUsers);
in
{
  config = lib.mkIf (pkgs.stdenv.hostPlatform.isOpenBSD && config.nix.enable && !config.boot.isJail) {
    # NixBSD supplies membership in nixbld for user discovery. Sandboxed builds
    # use each account's primary group instead of the shared store group.
    users.users = lib.genAttrs users (name: {
      group = lib.mkOverride 90 name;
    });
    users.groups = lib.genAttrs users (_: { });
  };
}
