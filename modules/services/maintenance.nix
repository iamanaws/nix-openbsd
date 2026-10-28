{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.maintenance;
  periods = [
    "daily"
    "weekly"
    "monthly"
  ];
  schedules = {
    daily = "30 1 * * *";
    weekly = "30 3 * * 6";
    monthly = "30 5 1 * *";
  };
in
{
  imports = [ ../system/tempfiles.nix ];
  options.services.maintenance = {
    enable = lib.mkEnableOption "OpenBSD daily, weekly and monthly maintenance";
    package = lib.mkPackageOption pkgs [ "openbsd" "maintenance-scripts" ] { };
    mtreeConfig = lib.mkOption {
      type = lib.types.lines;
      description = ''
        Contents of /etc/mtree/special for security(8).
        The default checks mutable account files and this module's local hooks.
        Nix store integrity is outside the scope of this mtree policy.
      '';
      default = ''
        . type=dir uid=0
        etc type=dir uid=0
        master.passwd type=file uid=0 gid=0 mode=0600
        passwd type=file uid=0 gid=0 mode=0644
        group type=file uid=0 gid=0 mode=0644
        crontab type=file uid=0 gid=0 mode=0600
        ${lib.concatMapStringsSep "\n" (period: "${period}.local type=file uid=0 gid=0 mode=0600") periods}
        ..
        var type=dir uid=0
        backups type=dir uid=0 gid=0 mode=0700
        ..
        ..
      '';
    };
  }
  // lib.genAttrs periods (
    period:
    lib.mkOption {
      default = { };
      description = "Configuration for OpenBSD's /etc/${period}.";
      type = lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to schedule /etc/${period}.";
          };
          schedule = lib.mkOption {
            type = lib.types.singleLineStr;
            default = schedules.${period};
            description = "Five-field cron schedule in the system timezone.";
          };
          config = lib.mkOption {
            type = lib.types.lines;
            default = lib.optionalString (period == "weekly") "MAKEWHATISARGS=-n\n";
            description = ''
              Contents of /etc/${period}.local, sourced by /etc/${period} before its standard checks.
              The weekly default scans manuals without updating databases in the immutable Nix store.
              Set MAKEWHATISARGS to a writable manual tree to rebuild its database.
            '';
          };
        };
      };
    }
  );
  config = lib.mkIf cfg.enable {
    services.cron.enable = lib.mkDefault true;
    services.smtpd.enable = lib.mkDefault true;
    assertions = [
      {
        assertion = config.services.cron.enable;
        message = "services.maintenance requires services.cron.";
      }
      {
        assertion = config.services.smtpd.enable;
        message = "services.maintenance requires local mail for OpenBSD's reports.";
      }
    ];
    services.cron.systemCronJobs = map (
      period:
      "${cfg.${period}.schedule} root cd /var/log && HOME=/var/log ${pkgs.oksh}/bin/oksh /etc/${period}"
    ) (builtins.filter (period: cfg.${period}.enable) periods);
    environment.etc = lib.mkMerge (
      [
        {
          "mail.rc".source = "${pkgs.openbsd.mail}/etc/mail.rc";
          "mtree/special".text = cfg.mtreeConfig;
          "changelist".source = "${cfg.package}/etc/changelist";
        }
      ]
      ++ map (period: {
        "${period}".source = "${cfg.package}/etc/${period}";
        "${period}.local" = {
          text = cfg.${period}.config;
          mode = "0600";
          user = "root";
          group = "root";
        };
      }) periods
    );
    services.tempfiles.directories = {
      "/var/log" = { };
      "/var/backups" = {
        mode = "0700";
        group = "root";
      };
      "/var/db/pkg" = { };
    };
  };
}
