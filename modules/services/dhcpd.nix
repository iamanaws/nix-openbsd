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
  imports = [ ../system/tempfiles.nix ];
  options.services.dhcpd = {
    enable = lib.mkEnableOption "OpenBSD dhcpd";

    package = lib.mkPackageOption pkgs [ "openbsd" "dhcpd" ] { };

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
      description = "OpenBSD DHCP programs";
    };
    users.groups._dhcp.gid = 77;

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/db" = { };
    };

    init.services.dhcpd = {
      description = "OpenBSD DHCP daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [ dhcpd ] ++ commonArgs ++ cfg.extraFlags ++ cfg.interfaces;
      preStart = ''
        touch ${leasePath}
        chown root:_dhcp ${leasePath}
        chmod 0640 ${leasePath}
        ${dhcpd} -n ${lib.escapeShellArgs commonArgs} ${lib.escapeShellArgs cfg.interfaces}
      '';
    };
  };
}
