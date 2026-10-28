{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.bgpd;
  configPath = "/etc/bgpd.conf";
  bgpd = "${cfg.package}/bin/bgpd";
in
{
  imports = [ ../system/tempfiles.nix ];
  options.services.bgpd = {
    enable = lib.mkEnableOption "OpenBSD bgpd";

    package = lib.mkPackageOption pkgs [ "openbsd" "bgpd" ] { };

    controlPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.bgpctl;
      defaultText = lib.literalExpression "pkgs.openbsd.bgpctl";
      description = "The OpenBSD bgpctl package to install.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of bgpd.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to bgpd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."bgpd.conf" = {
      text = cfg.config;
      mode = "0600";
    };
    environment.systemPackages = [
      cfg.package
      cfg.controlPackage
    ];

    users.users._bgpd = {
      uid = 75;
      isSystemUser = true;
      group = "_bgpd";
      home = "/var/empty";
      description = "OpenBSD BGP daemon";
    };
    users.groups._bgpd.gid = 75;
    openbsd.rc.services.bgpd.hooks.rc_configtest = ''
      rc_exec "''${daemon} -n ''${daemon_flags}"
    '';

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/run" = { };
    };

    init.services.bgpd = {
      description = "OpenBSD BGP daemon";
      dependencies = [ "NETWORKING" ] ++ lib.optional config.services.pf.enable "pf";
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [
        bgpd
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        rm -f /var/run/bgpd.sock*
      '';
    };
  };
}
