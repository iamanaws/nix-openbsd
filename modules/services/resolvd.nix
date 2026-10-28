{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.resolvd;
  resolvd = "${cfg.package}/bin/resolvd";
  updateResolver = ''
    (
      temporary=$(mktemp /etc/.resolv.conf.XXXXXXXX) || exit 1
      trap 'rm -f "$temporary"' EXIT
      install -m 0644 /etc/resolv.conf.resolvd "$temporary" &&
        mv -f "$temporary" /etc/resolv.conf
    )
  '';
in
{
  options.services.resolvd = {
    enable = lib.mkEnableOption "OpenBSD resolvd";

    package = lib.mkPackageOption pkgs [ "openbsd" "resolvd" ] { };

    config = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "User-managed contents of resolv.conf(5), applied at startup and live updates.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to resolvd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."resolv.conf.resolvd".text = cfg.config;
    environment.systemPackages = [ cfg.package ];

    # resolvd watches resolv.conf; replace it atomically without sending a signal.
    openbsd.rc.services.resolvd.hooks.rc_reload = updateResolver;

    init.services.resolvd = {
      description = "OpenBSD resolver configuration daemon";
      dependencies = [ "FILESYSTEMS" ];
      before = [ "NETWORKING" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [ resolvd ] ++ cfg.extraFlags;
      preStart = ''
        rm -f /dev/resolvd.lock
        ${updateResolver}
      '';
    };
  };
}
