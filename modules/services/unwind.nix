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
  options.services.unwind = {
    enable = lib.mkEnableOption "OpenBSD unwind";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.unwind;
      defaultText = lib.literalExpression "pkgs.openbsd.unwind";
      description = "The OpenBSD unwind package to use.";
    };

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

    systemd.tmpfiles.rules = [ "d /var/empty 0555 root root - -" ];

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
        mkdir -p /var/empty
        chmod 0555 /var/empty
        rm -f /dev/unwind.sock
        ${unwind} -n -f ${configPath}
      '';
    };
  };
}
