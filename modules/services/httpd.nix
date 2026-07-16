{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.httpd;
  configPath = "/etc/httpd.conf";
  httpd = "${cfg.package}/bin/httpd";
in
{
  options.services.httpd = {
    enable = lib.mkEnableOption "OpenBSD httpd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.httpd;
      defaultText = lib.literalExpression "pkgs.openbsd.httpd";
      description = "The OpenBSD httpd package to use.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of httpd.conf(5).";
    };

    documentRoot = lib.mkOption {
      type = lib.types.path;
      description = "Static content copied into the /var/www/htdocs chroot.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to httpd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."httpd.conf".text = cfg.config;
    environment.systemPackages = [ cfg.package ];

    users.users.www = {
      uid = 67;
      isSystemUser = true;
      group = "www";
      home = "/var/www";
      description = "OpenBSD HTTP server";
    };
    users.groups.www.gid = 67;

    systemd.tmpfiles.rules = [
      "d /var/www 0755 root root - -"
      "d /var/www/htdocs 0755 root root - -"
      "d /var/www/logs 0755 www www - -"
    ];

    init.services.httpd = {
      description = "OpenBSD HTTP daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = with pkgs; [
        coreutils
        openbsd.ifconfig
      ];
      startCommand = [
        httpd
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        ifconfig lo0 inet 127.0.0.1 netmask 255.0.0.0 up
        rm -rf /var/www/htdocs
        mkdir -p /var/www/htdocs /var/www/logs
        cp -R ${cfg.documentRoot}/. /var/www/htdocs/
        chown -R root:www /var/www/htdocs
        chmod -R u=rwX,go=rX /var/www/htdocs
        chown www:www /var/www/logs
        ${httpd} -n -f ${configPath}
      '';
    };
  };
}
