{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.cron;
  cron = "${cfg.package}/bin/cron";
in
{
  options.services.cron = {
    enable = lib.mkEnableOption "OpenBSD cron";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.cron;
      defaultText = lib.literalExpression "pkgs.openbsd.cron";
      description = "The OpenBSD cron package to use.";
    };

    crontabPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.crontab;
      defaultText = lib.literalExpression "pkgs.openbsd.crontab";
      description = "The OpenBSD crontab package to install.";
    };

    systemCronJobs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "0 * * * * root echo hourly" ];
      description = "Raw entries for the system crontab.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to cron.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."crontab".text = ''
      SHELL=/bin/sh
      PATH=/run/current-system/sw/bin:/bin:/usr/bin

      ${lib.concatStringsSep "\n" cfg.systemCronJobs}
    '';

    environment.systemPackages = [
      cfg.package
      cfg.crontabPackage
    ];

    users.groups.crontab.gid = 66;

    systemd.tmpfiles.rules = [
      "d /var/cron 0555 root wheel - -"
      "d /var/cron/atjobs 1770 root crontab - -"
      "d /var/cron/tabs 1730 root crontab - -"
    ];

    init.services.cron = {
      description = "OpenBSD cron daemon";
      dependencies = [ "FILESYSTEMS" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [ cron ] ++ cfg.extraFlags;
      preStart = ''
        mkdir -p /var/cron/atjobs /var/cron/tabs /var/run
        chown root:wheel /var/cron
        chmod 0555 /var/cron
        chown root:crontab /var/cron/atjobs /var/cron/tabs
        chmod 1770 /var/cron/atjobs
        chmod 1730 /var/cron/tabs
        rm -f /var/run/cron.sock
      '';
    };
  };
}
