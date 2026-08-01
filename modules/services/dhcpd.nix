{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.dhcpd;
  configPath = "/etc/dhcpd.conf";
  leasePath = "/var/db/dhcpd.leases";
  dhcpd = "${cfg.package}/bin/dhcpd";
  commonArgs = [
    "-c"
    configPath
    "-l"
    leasePath
  ];
in
{
  options.services.dhcpd = {
    enable = lib.mkEnableOption "OpenBSD dhcpd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.dhcpd;
      defaultText = lib.literalExpression "pkgs.openbsd.dhcpd";
      description = "The OpenBSD dhcpd package to use.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of dhcpd.conf(5).";
    };

    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Interfaces on which dhcpd should listen.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to dhcpd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."dhcpd.conf".text = cfg.config;
    environment.systemPackages = [ cfg.package ];

    users.users._dhcp = {
      uid = 77;
      isSystemUser = true;
      group = "_dhcp";
      home = "/var/empty";
      description = "OpenBSD DHCP daemon";
    };
    users.groups._dhcp.gid = 77;

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "d /var/db 0755 root wheel - -"
      "f ${leasePath} 0640 root _dhcp - -"
    ];

    init.services.dhcpd = {
      description = "OpenBSD DHCP daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [ dhcpd ] ++ commonArgs ++ cfg.extraFlags ++ cfg.interfaces;
      preStart = ''
        mkdir -p /var/empty /var/db
        touch ${leasePath}
        chown root:_dhcp ${leasePath}
        chmod 0640 ${leasePath}
        ${dhcpd} -n ${lib.escapeShellArgs commonArgs} ${lib.escapeShellArgs cfg.interfaces}
      '';
    };
  };
}
