{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.ospfd;
  configPath = "/etc/ospfd.conf";
  ospfd = "${cfg.package}/bin/ospfd";
in
{
  options.services.ospfd = {
    enable = lib.mkEnableOption "OpenBSD ospfd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.ospfd;
      defaultText = lib.literalExpression "pkgs.openbsd.ospfd";
      description = "The OpenBSD ospfd package to use.";
    };

    controlPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.ospfctl;
      defaultText = lib.literalExpression "pkgs.openbsd.ospfctl";
      description = "The OpenBSD ospfctl package to install.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of ospfd.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to ospfd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."ospfd.conf" = {
      text = cfg.config;
      mode = "0600";
    };
    environment.systemPackages = [
      cfg.package
      cfg.controlPackage
    ];

    users.users._ospfd = {
      uid = 85;
      isSystemUser = true;
      group = "_ospfd";
      home = "/var/empty";
      description = "OpenBSD OSPF daemon";
    };
    users.groups._ospfd.gid = 85;

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "d /var/run 0755 root wheel - -"
    ];

    init.services.ospfd = {
      description = "OpenBSD OSPF daemon";
      dependencies = [ "NETWORKING" ] ++ lib.optional config.services.pf.enable "pf";
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [
        ospfd
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        mkdir -p /var/empty /var/run
        chown root:wheel /var/empty /var/run
        chmod 0555 /var/empty
        rm -f /var/run/ospfd.sock*
        ${ospfd} -n -f ${configPath} ${lib.escapeShellArgs cfg.extraFlags}
      '';
    };
  };
}
