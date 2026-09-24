{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.syslogd;
  configPath = "/etc/syslog.conf";
  syslogd = "${cfg.package}/bin/syslogd";
in
{
  options.services.syslogd = {
    enable = lib.mkEnableOption "OpenBSD syslogd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.syslogd;
      defaultText = lib.literalExpression "pkgs.openbsd.syslogd";
      description = "The OpenBSD syslogd package to use.";
    };

    clientPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.syslogc;
      defaultText = lib.literalExpression "pkgs.openbsd.syslogc";
      description = "Optional OpenBSD syslogc client package to install.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of syslog.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to syslogd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."syslog.conf".text = cfg.config;
    environment.systemPackages = [
      cfg.package
      cfg.clientPackage
    ];

    users.users._syslogd = {
      uid = 73;
      isSystemUser = true;
      group = "_syslogd";
      home = "/var/empty";
      description = "OpenBSD syslog daemon";
    };
    users.groups._syslogd.gid = 73;

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "d /var/run 0755 root wheel - -"
      "d /var/log 0755 root wheel - -"
    ];

    openbsd.rc.services.syslogd.shellVariables.pexp = "syslogd: \\[priv\\]";

    init.services.syslogd = {
      description = "OpenBSD system logging daemon";
      dependencies = [ "FILESYSTEMS" ] ++ lib.optional (config.services.newsyslog.enable or false) "newsyslog-check";
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [
        syslogd
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        mkdir -p /var/empty /var/run /var/log /var/cron
        chown root:wheel /var/empty /var/run /var/log
        chmod 0555 /var/empty
        chmod 0755 /var/run /var/log
        for f in /var/log/messages /var/log/authlog /var/log/secure \
                 /var/log/daemon /var/cron/log; do
          if [ ! -e "$f" ]; then
            touch "$f"
            chown root:wheel "$f"
            chmod 0640 "$f"
          fi
        done
        rm -f /dev/log
      '';
    };
  };
}
