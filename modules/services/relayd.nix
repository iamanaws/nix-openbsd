{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.relayd;
  configPath = "/etc/relayd.conf";
  relayd = "${cfg.package}/bin/relayd";
in
{
  options.services.relayd = {
    enable = lib.mkEnableOption "OpenBSD relayd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.relayd;
      defaultText = lib.literalExpression "pkgs.openbsd.relayd";
      description = "The OpenBSD relayd package to use.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of relayd.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to relayd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."relayd.conf".text = cfg.config;
    environment.systemPackages = [
      cfg.package
      pkgs.openbsd.relayctl
    ];

    users.users._relayd = {
      uid = 89;
      isSystemUser = true;
      group = "_relayd";
      home = "/var/empty";
      description = "OpenBSD relay daemon";
    };
    users.groups._relayd.gid = 89;

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "d /var/run 0755 root root - -"
    ];

    init.services.relayd = {
      description = "OpenBSD relay daemon";
      dependencies = [ "NETWORKING" ] ++ lib.optional config.services.httpd.enable "httpd";
      before = [ "SERVERS" ];
      startType = "forking";
      path = [
        cfg.package
        pkgs.coreutils
        pkgs.openbsd.pfctl
      ];
      startCommand = [
        relayd
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        mkdir -p /var/empty /var/run
        chown root:wheel /var/empty
        chmod 0555 /var/empty
        ${relayd} -n -f ${configPath}
      '';
    };
  };
}
