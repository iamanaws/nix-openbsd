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

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "d /var/run 0755 root wheel - -"
      "d /var/agentx 0755 root _agentx - -"
    ];

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
        mkdir -p /var/empty /var/run /var/agentx
        chown root:wheel /var/empty /var/run
        chown root:_agentx /var/agentx
        chmod 0555 /var/empty
        chmod 0755 /var/agentx
        rm -f /var/agentx/master
        ${snmpd} -n -f ${configPath} ${lib.escapeShellArgs cfg.extraFlags}
      '';
    };
  };
}
