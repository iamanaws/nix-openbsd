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
  imports = [ ../system/tempfiles.nix ];
  options.services.cron = {
    enable = lib.mkEnableOption "OpenBSD cron";

    package = lib.mkPackageOption pkgs [ "openbsd" "cron" ] { };

    controlPackage = lib.mkPackageOption pkgs [ "openbsd" "cronctl" ] {
      nullable = true;
      default =
        if pkgs.openbsd ? cronctl then
          [
            "openbsd"
            "cronctl"
          ]
        else
          null;
      extraDescription = "Set to null to use cron's automatic reload without pre-activation validation.";
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
    # Cron rejects symlinks and compares mtimes, which are fixed in the store.
    environment.etc."crontab".mode = "0600";
    environment.etc."crontab".text = ''
      SHELL=/bin/sh
      PATH=/run/current-system/sw/bin:/bin:/usr/bin

      ${lib.concatStringsSep "\n" cfg.systemCronJobs}
    '';

    environment.systemPackages = [
      cfg.package
      cfg.crontabPackage
    ]
    ++ lib.optional (cfg.controlPackage != null) cfg.controlPackage;

    users.groups.crontab.gid = 66;

    # Keep cron running so configuration updates do not rerun @reboot jobs.
    openbsd.rc.services.cron.hooks.rc_reload =
      if cfg.controlPackage != null then
        ''
          ${cfg.controlPackage}/bin/cronctl reload
        ''
      else
        ''
          # Cron notices the changed crontab at its next minute check.
          :
        '';

    services.tempfiles.directories = {
      "/var/cron".mode = "0555";
      "/var/cron/atjobs" = {
        mode = "1770";
        group = "crontab";
      };
      "/var/cron/tabs" = {
        mode = "1730";
        group = "crontab";
      };
      "/var/run" = { };
    };

    init.services.cron = {
      description = "OpenBSD cron daemon";
      dependencies = [ "FILESYSTEMS" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [ cron ] ++ cfg.extraFlags;
      preStart = ''
        rm -f /var/run/cron.sock
      '';
    };
  };
}
