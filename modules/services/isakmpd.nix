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
  imports = [ ../system/tempfiles.nix ];
  options.services.isakmpd = {
    enable = lib.mkEnableOption "OpenBSD isakmpd";

    package = lib.mkPackageOption pkgs [ "openbsd" "isakmpd" ] { };

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

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/run" = { };
      "/etc/isakmpd".mode = "0700";
      "/etc/isakmpd/ca" = { };
      "/etc/isakmpd/certs" = { };
      "/etc/isakmpd/crls" = { };
      "/etc/isakmpd/keynote".mode = "0700";
      "/etc/isakmpd/private".mode = "0700";
      "/etc/isakmpd/pubkeys" = { };
    };

    openbsd.rc.services.isakmpd.shellVariables.pexp = "isakmpd: monitor \\[priv\\]";

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
        rm -f /var/run/isakmpd.{fifo,pcap,pid,report,result}
      '';
    };
  };
}
