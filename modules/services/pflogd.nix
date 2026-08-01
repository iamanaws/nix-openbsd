{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pflogd;
  pflogd = "${cfg.package}/bin/pflogd";
in
{
  options.services.pflogd = {
    enable = lib.mkEnableOption "OpenBSD pflogd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.pflogd;
      defaultText = lib.literalExpression "pkgs.openbsd.pflogd";
      description = "The OpenBSD pflogd package to use.";
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "pflog0";
      description = "Packet filter logging interface to capture.";
    };

    logFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/log/pflog";
      description = "Path to the packet filter capture log.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to pflogd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      pkgs.openbsd.tcpdump
    ];

    users.users._pflogd = {
      uid = 74;
      isSystemUser = true;
      group = "_pflogd";
      home = "/var/empty";
      description = "OpenBSD packet filter logging daemon";
    };
    users.groups._pflogd.gid = 74;

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "f ${cfg.logFile} 0600 root wheel - -"
    ];

    init.services.pflogd = {
      description = "OpenBSD packet filter logging daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [
        pflogd
        "-i"
        cfg.interface
        "-f"
        cfg.logFile
      ]
      ++ cfg.extraFlags;
      preStart = ''
        mkdir -p /var/empty "$(dirname ${lib.escapeShellArg cfg.logFile})"
        touch ${lib.escapeShellArg cfg.logFile}
        chmod 0600 ${lib.escapeShellArg cfg.logFile}
      '';
    };
  };
}
