{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.ntpd;
  configPath = "/etc/ntpd.conf";
  ntpd = "${cfg.package}/bin/ntpd";
in
{
  imports = [ ../system/tempfiles.nix ];
  options.services.ntpd = {
    enable = lib.mkEnableOption "OpenBSD ntpd";

    package = lib.mkPackageOption pkgs [ "openbsd" "ntpd" ] { };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of ntpd.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to ntpd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."ntpd.conf".text = cfg.config;
    environment.etc."protocols".source = "${pkgs.iana-etc}/etc/protocols";
    environment.etc."services".source = "${pkgs.iana-etc}/etc/services";
    environment.systemPackages = [ cfg.package ];

    users.users._ntp = {
      uid = 83;
      isSystemUser = true;
      group = "_ntp";
      home = "/var/empty";
      description = "OpenBSD NTP daemon";
    };
    users.groups._ntp.gid = 83;

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/db" = { };
      "/var/run" = { };
    };

    init.services.ntpd = {
      description = "OpenBSD network time daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [
        ntpd
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        rm -f /var/run/ntpd.sock
        ${ntpd} -n -f ${configPath}
      '';
    };
  };
}
