{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.unwind;
  configPath = "/etc/unwind.conf";
  unwind = "${cfg.package}/bin/unwind";
in
{
  imports = [ ../system/tempfiles.nix ];
  options.services.unwind = {
    enable = lib.mkEnableOption "OpenBSD unwind";

    package = lib.mkPackageOption pkgs [ "openbsd" "unwind" ] { };

    config = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Verbatim contents of unwind.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to unwind.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."unwind.conf".text = cfg.config;
    environment.etc."ssl/cert.pem".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    environment.systemPackages = [ cfg.package ];

    users.users._unwind = {
      uid = 48;
      isSystemUser = true;
      group = "_unwind";
      home = "/var/empty";
      description = "OpenBSD validating resolver daemon";
    };
    users.groups._unwind.gid = 48;

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/db" = { };
    };

    openbsd.rc.services.unwind.hooks.rc_configtest = ''
      rc_exec "''${daemon} -n ''${daemon_flags}"
    '';

    init.services.unwind = {
      description = "OpenBSD validating resolver daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [
        unwind
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        rm -f /dev/unwind.sock
      '';
    };
  };
}
