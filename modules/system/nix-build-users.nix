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
      class = lib.mkDefault "nixbld";
    });
    users.groups = lib.genAttrs users (_: { });
    users.classes.nixbld.settings = {
      tc = lib.mkDefault "default";
      # Match pbuild's process limits and the default class's descriptor limits.
      maxproc = lib.mkDefault {
        cur = 512;
        max = 1024;
      };
      openfiles = lib.mkDefault {
        cur = 512;
        max = 1024;
      };
    };
  };
}
