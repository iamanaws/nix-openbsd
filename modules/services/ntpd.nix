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
  options.services.ntpd = {
    enable = lib.mkEnableOption "OpenBSD ntpd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.ntpd;
      defaultText = lib.literalExpression "pkgs.openbsd.ntpd";
      description = "The OpenBSD ntpd package to use.";
    };

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

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "d /var/db 0755 root wheel - -"
      "d /var/run 0755 root wheel - -"
    ];

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
        mkdir -p /var/empty /var/db /var/run
        chown root:wheel /var/empty /var/db /var/run
        chmod 0555 /var/empty
        rm -f /var/run/ntpd.sock
        ${ntpd} -n -f ${configPath}
      '';
    };
  };
}
