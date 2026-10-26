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
  imports = [ ../system/tempfiles.nix ];
  options.services.syslogd = {
    enable = lib.mkEnableOption "OpenBSD syslogd";

    package = lib.mkPackageOption pkgs [ "openbsd" "syslogd" ] { };

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

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/run" = { };
      "/var/log" = { };
      "/var/cron" = { };
    };

    # OpenBSD 8.0 runs the privileged parent in a separate executable.
    openbsd.rc.services.syslogd.shellVariables.pexp = "syslogd-parent: \\[priv\\]";

    init.services.syslogd = {
      description = "OpenBSD system logging daemon";
      dependencies = [
        "FILESYSTEMS"
      ]
      ++ lib.optional (config.services.newsyslog.enable or false) "newsyslog-check";
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
