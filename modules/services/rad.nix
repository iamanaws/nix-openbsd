{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.rad;
  configPath = "/etc/rad.conf";
  rad = "${cfg.package}/bin/rad";
in
{
  imports = [ ../system/tempfiles.nix ];
  options.services.rad = {
    enable = lib.mkEnableOption "OpenBSD rad";

    package = lib.mkPackageOption pkgs [ "openbsd" "rad" ] { };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of rad.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to rad.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."rad.conf".text = cfg.config;
    environment.systemPackages = [ cfg.package ];

    users.users._rad = {
      uid = 94;
      isSystemUser = true;
      group = "_rad";
      home = "/var/empty";
      description = "OpenBSD router advertisement daemon";
    };
    users.groups._rad.gid = 94;

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/run" = { };
    };

    init.services.rad = {
      description = "OpenBSD router advertisement daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [
        rad
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        rm -f /var/run/rad.sock
        ${rad} -n -f ${configPath}
      '';
    };
  };
}
