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
  imports = [ ../system/tempfiles.nix ];
  options.services.relayd = {
    enable = lib.mkEnableOption "OpenBSD relayd";

    package = lib.mkPackageOption pkgs [ "openbsd" "relayd" ] { };

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

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/run" = { };
      # relayd unveils this path even when AgentX is disabled.
      "/var/agentx" = { };
    };

    init.services.relayd = {
      description = "OpenBSD relay daemon";
      dependencies = [ "NETWORKING" ] ++ lib.optional (config.services.httpd.enable or false) "httpd";
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
        ${relayd} -n -f ${configPath}
      '';
    };
  };
}
