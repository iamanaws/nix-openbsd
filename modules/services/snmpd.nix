{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.snmpd;
  configPath = "/etc/snmpd.conf";
  snmpd = "${cfg.package}/bin/snmpd";
in
{
  imports = [ ../system/tempfiles.nix ];
  options.services.snmpd = {
    enable = lib.mkEnableOption "OpenBSD snmpd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.snmpd.override {
        snmp_mibs = cfg.mibsPackage;
        snmpd_metrics = cfg.metricsPackage;
      };
      defaultText = lib.literalExpression ''
        pkgs.openbsd.snmpd.override {
          snmp_mibs = config.services.snmpd.mibsPackage;
          snmpd_metrics = config.services.snmpd.metricsPackage;
        }
      '';
      description = "The OpenBSD snmpd package to use.";
    };

    controlPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.snmp;
      defaultText = lib.literalExpression "pkgs.openbsd.snmp";
      description = "The OpenBSD snmp(1) client package to install.";
    };

    metricsPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.snmpd_metrics;
      defaultText = lib.literalExpression "pkgs.openbsd.snmpd_metrics";
      description = "The OpenBSD snmpd_metrics backend package.";
    };

    mibsPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.snmp_mibs;
      defaultText = lib.literalExpression "pkgs.openbsd.snmp_mibs";
      description = "The OpenBSD SNMP MIB data package.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of snmpd.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to snmpd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."snmpd.conf" = {
      text = cfg.config;
      mode = "0600";
    };
    environment.etc."protocols".source = "${pkgs.iana-etc}/etc/protocols";
    environment.etc."services".source = "${pkgs.iana-etc}/etc/services";
    environment.systemPackages = [
      cfg.package
      cfg.controlPackage
      cfg.metricsPackage
      cfg.mibsPackage
    ];

    users.users._snmpd = {
      uid = 91;
      isSystemUser = true;
      group = "_snmpd";
      home = "/var/empty";
      description = "OpenBSD SNMP daemon";
    };
    users.groups._snmpd.gid = 91;
    users.groups._agentx.gid = 92;

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/run" = { };
      "/var/agentx".group = "_agentx";
    };

    init.services.snmpd = {
      description = "OpenBSD SNMP daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [
        pkgs.coreutils
      ];
      startCommand = [
        snmpd
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        rm -f /var/agentx/master
        ${snmpd} -n -f ${configPath} ${lib.escapeShellArgs cfg.extraFlags}
      '';
    };
  };
}
