{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.resolvd;
  resolvd = "${cfg.package}/bin/resolvd";
in
{
  options.services.resolvd = {
    enable = lib.mkEnableOption "OpenBSD resolvd";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.resolvd;
      defaultText = lib.literalExpression "pkgs.openbsd.resolvd";
      description = "The OpenBSD resolvd package to use.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Initial user-managed contents of resolv.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to resolvd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."resolv.conf.resolvd".text = cfg.config;
    environment.systemPackages = [ cfg.package ];

    init.services.resolvd = {
      description = "OpenBSD resolver configuration daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [ resolvd ] ++ cfg.extraFlags;
      preStart = ''
        rm -f /etc/resolv.conf /etc/resolv.conf.new /dev/resolvd.lock
        cp /etc/resolv.conf.resolvd /etc/resolv.conf
        chmod 0644 /etc/resolv.conf
      '';
    };
  };
}
