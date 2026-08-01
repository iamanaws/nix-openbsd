{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.ripd;
  configPath = "/etc/ripd.conf";
  ripd = "${cfg.package}/bin/ripd";
in
{
  options.services.ripd = {
    enable = lib.mkEnableOption "OpenBSD ripd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.ripd;
      defaultText = lib.literalExpression "pkgs.openbsd.ripd";
      description = "The OpenBSD ripd package to use.";
    };

    controlPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.ripctl;
      defaultText = lib.literalExpression "pkgs.openbsd.ripctl";
      description = "The OpenBSD ripctl package to install.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of ripd.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to ripd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."ripd.conf" = {
      text = cfg.config;
      mode = "0600";
    };
    environment.systemPackages = [
      cfg.package
      cfg.controlPackage
    ];

    users.users._ripd = {
      uid = 88;
      isSystemUser = true;
      group = "_ripd";
      home = "/var/empty";
      description = "OpenBSD RIP daemon";
    };
    users.groups._ripd.gid = 88;

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "d /var/run 0755 root wheel - -"
    ];

    init.services.ripd = {
      description = "OpenBSD RIP daemon";
      dependencies = [ "NETWORKING" ] ++ lib.optional config.services.pf.enable "pf";
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [
        ripd
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        mkdir -p /var/empty /var/run
        chown root:wheel /var/empty /var/run
        chmod 0555 /var/empty
        rm -f /var/run/ripd.sock*
        ${ripd} -n -f ${configPath} ${lib.escapeShellArgs cfg.extraFlags}
      '';
    };
  };
}
