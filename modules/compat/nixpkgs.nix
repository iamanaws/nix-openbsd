{ lib, ... }:

{
  # Current Nixpkgs' terminfo module populates the systemd initrd, while the
  # OpenBSD NixBSD module set intentionally has no systemd initrd module.
  # Declare the otherwise-unused option until NixBSD carries an equivalent
  # compatibility update.
  options.boot.initrd.systemd.contents = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    internal = true;
  };

  # The current fish module references these behind programs.fish.enable, but
  # the older NixBSD man-page module predates the cache option namespace.
  options.documentation.man.cache = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
    };
    generateAtRuntime = lib.mkOption {
      type = lib.types.bool;
      default = false;
      internal = true;
    };
  };

  # Newer NixOS modules can assign module ownership to maintainer teams.
  options.meta.teams = lib.mkOption {
    type = lib.types.listOf lib.types.anything;
    default = [ ];
    internal = true;
  };

  # terminfo.nix configures both sudo implementations in current Nixpkgs.
  # NixBSD only provides sudo, so retain the unused sudo-rs setting.
  options.security."sudo-rs".extraConfig = lib.mkOption {
    type = lib.types.lines;
    default = "";
    internal = true;
  };

  # Current man-db exposes its cache updater as a systemd service. NixBSD
  # consumes neither the service nor this compatibility option.
  options.systemd.services = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    internal = true;
  };
  options.systemd.user = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    internal = true;
  };
}
