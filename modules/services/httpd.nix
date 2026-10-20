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
  imports = [ ../system/tempfiles.nix ];
  options.services.httpd = {
    enable = lib.mkEnableOption "OpenBSD httpd";

    package = lib.mkPackageOption pkgs [ "openbsd" "httpd" ] { };

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

    services.tempfiles.directories = {
      "/var/www" = { };
      "/var/www/htdocs".group = "www";
      "/var/www/logs" = {
        user = "www";
        group = "www";
      };
    };

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
        mkdir /var/www/htdocs
        cp -R ${cfg.documentRoot}/. /var/www/htdocs/
        chown -R root:www /var/www/htdocs
        chmod -R u=rwX,go=rX /var/www/htdocs
        ${httpd} -n -f ${configPath}
      '';
    };
  };
}
