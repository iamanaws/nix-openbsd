{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.isakmpd;
  configPath = "/etc/isakmpd/isakmpd.conf";
  isakmpd = "${cfg.package}/bin/isakmpd";
in
{
  options.services.isakmpd = {
    enable = lib.mkEnableOption "OpenBSD isakmpd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.isakmpd;
      defaultText = lib.literalExpression "pkgs.openbsd.isakmpd";
      description = "The OpenBSD isakmpd package to use.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of isakmpd.conf(5).";
    };

    disablePolicyChecks = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Pass -K and leave policy installation to ipsecctl.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to isakmpd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."isakmpd/isakmpd.conf" = {
      text = cfg.config;
      mode = "0600";
    };
    environment.systemPackages = [ cfg.package ];

    users.users._isakmpd = {
      uid = 68;
      isSystemUser = true;
      group = "_isakmpd";
      home = "/var/empty";
      description = "OpenBSD IKEv1 daemon";
    };
    users.groups._isakmpd.gid = 68;

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "d /var/run 0755 root wheel - -"
      "d /etc/isakmpd 0700 root wheel - -"
      "d /etc/isakmpd/ca 0755 root wheel - -"
      "d /etc/isakmpd/certs 0755 root wheel - -"
      "d /etc/isakmpd/crls 0755 root wheel - -"
      "d /etc/isakmpd/keynote 0700 root wheel - -"
      "d /etc/isakmpd/private 0700 root wheel - -"
      "d /etc/isakmpd/pubkeys 0755 root wheel - -"
    ];

    init.services.isakmpd = {
      description = "OpenBSD IKEv1 daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      pidFile = "/var/run/isakmpd.pid";
      path = [ pkgs.coreutils ];
      startCommand = [
        isakmpd
        "-c"
        configPath
      ]
      ++ lib.optional cfg.disablePolicyChecks "-K"
      ++ cfg.extraFlags;
      preStart = ''
        mkdir -p /var/empty /var/run \
          /etc/isakmpd/{ca,certs,crls,keynote,private,pubkeys}
        chown root:wheel /etc/isakmpd \
          /etc/isakmpd/{ca,certs,crls,keynote,private,pubkeys}
        chmod 0700 /etc/isakmpd /etc/isakmpd/keynote /etc/isakmpd/private
        chmod 0755 /etc/isakmpd/{ca,certs,crls,pubkeys}
        rm -f /var/run/isakmpd.{fifo,pcap,pid,report,result}
      '';
    };
  };
}
