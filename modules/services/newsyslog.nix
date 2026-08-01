{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.newsyslog;
  configPath = "/etc/newsyslog.conf";
  newsyslog = "${cfg.package}/bin/newsyslog";
in
{
  options.services.newsyslog = {
    enable = lib.mkEnableOption "OpenBSD newsyslog log rotation";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.newsyslog;
      defaultText = lib.literalExpression "pkgs.openbsd.newsyslog";
      description = "The OpenBSD newsyslog package to use.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of newsyslog.conf(5).";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "0 * * * *";
      description = "Five-field cron schedule for hourly log rotation.";
    };

    createLogFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/var/log/messages"
        "/var/log/authlog"
        "/var/log/secure"
        "/var/log/daemon"
        "/var/log/maillog"
        "/var/log/xferlog"
        "/var/log/lpd-errs"
        "/var/cron/log"
      ];
      description = "Log files created before syslogd starts.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."newsyslog.conf".text = cfg.config;
    environment.systemPackages = [
      cfg.package
      pkgs.gzip
    ];

    services.cron.enable = lib.mkDefault true;
    services.cron.systemCronJobs = [
      "${cfg.schedule} root ${newsyslog} -f ${configPath}"
    ];

    systemd.tmpfiles.rules = [
      "d /var/log 0755 root wheel - -"
      "d /var/cron 0555 root wheel - -"
    ]
    ++ map (path: "f ${path} 0640 root wheel - -") cfg.createLogFiles;

    init.services.newsyslog-check = {
      description = "Validate OpenBSD newsyslog configuration";
      dependencies = [ "FILESYSTEMS" ];
      before = [ "SERVERS" ];
      startType = "oneshot";
      path = [ pkgs.coreutils ];
      startCommand = [
        newsyslog
        "-n"
        "-f"
        configPath
      ];
      preStart = ''
        mkdir -p /var/log /var/cron
        chown root:wheel /var/log /var/cron
        chmod 0755 /var/log
        chmod 0555 /var/cron
        ${lib.concatMapStringsSep "\n" (path: ''
          if [ ! -e ${lib.escapeShellArg path} ]; then
            touch ${lib.escapeShellArg path}
            chown root:wheel ${lib.escapeShellArg path}
            chmod 0640 ${lib.escapeShellArg path}
          fi
        '') cfg.createLogFiles}
      '';
    };
  };
}
