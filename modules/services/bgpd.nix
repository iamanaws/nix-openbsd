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
  options.services.bgpd = {
    enable = lib.mkEnableOption "OpenBSD bgpd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.bgpd;
      defaultText = lib.literalExpression "pkgs.openbsd.bgpd";
      description = "The OpenBSD bgpd package to use.";
    };

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

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "d /var/run 0755 root wheel - -"
    ];

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
        mkdir -p /var/empty /var/run
        chown root:wheel /var/empty /var/run
        chmod 0555 /var/empty
        rm -f /var/run/bgpd.sock*
        ${bgpd} -n -f ${configPath} ${lib.escapeShellArgs cfg.extraFlags}
      '';
    };
  };
}
