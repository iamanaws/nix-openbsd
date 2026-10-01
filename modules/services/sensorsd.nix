{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.sensorsd;
  configPath = "/etc/sensorsd.conf";
  sensorsd = "${cfg.package}/bin/sensorsd";
in
{
  options.services.sensorsd = {
    enable = lib.mkEnableOption "OpenBSD sensorsd";

    package = lib.mkPackageOption pkgs [ "openbsd" "sensorsd" ] { };

    config = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Verbatim contents of sensorsd.conf(5). An empty file monitors all stateful sensors.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to sensorsd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."sensorsd.conf".text = cfg.config;
    environment.systemPackages = [ cfg.package ];

    init.services.sensorsd = {
      description = "OpenBSD hardware sensors daemon";
      dependencies = [ "NETWORKING" ] ++ lib.optional config.services.syslogd.enable "syslogd";
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [ sensorsd ] ++ cfg.extraFlags;
      preStart = ''
        mkdir -p /var/run
        chown root:wheel /var/run
      '';
    };
  };
}
