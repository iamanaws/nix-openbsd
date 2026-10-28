{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.iked;
  configPath = "/etc/iked.conf";
  iked = "${cfg.package}/bin/iked";
in
{
  imports = [ ../system/tempfiles.nix ];
  options.services.iked = {
    enable = lib.mkEnableOption "OpenBSD iked";

    package = lib.mkPackageOption pkgs [ "openbsd" "iked" ] { };

    controlPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.ikectl;
      defaultText = lib.literalExpression "pkgs.openbsd.ikectl";
      description = "The OpenBSD ikectl package to install.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of iked.conf(5).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to iked.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."iked.conf" = {
      text = cfg.config;
      # iked refuses configuration files readable by other users.
      mode = "0600";
    };
    environment.systemPackages = [
      cfg.package
      cfg.controlPackage
    ];

    users.users._iked = {
      uid = 101;
      isSystemUser = true;
      group = "_iked";
      home = "/var/empty";
      description = "OpenBSD IKEv2 daemon";
    };
    users.groups._iked.gid = 101;

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/run" = { };
      # The unprivileged CA process must traverse its chroot.
      "/etc/iked" = { };
      "/etc/iked/ca" = { };
      "/etc/iked/certs" = { };
      "/etc/iked/crls" = { };
      "/etc/iked/ocsp" = { };
      "/etc/iked/private".mode = "0700";
      "/etc/iked/pubkeys" = { };
    };

    # iked replaces its command line with a process title after starting.
    openbsd.rc.services.iked.shellVariables.pexp = "iked: parent.*";
    openbsd.rc.services.iked.hooks.rc_configtest = ''
      rc_exec "''${daemon} -n ''${daemon_flags}"
    '';

    init.services.iked = {
      description = "OpenBSD IKEv2 daemon";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [
        iked
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        # iked loads a local private key even with pre-shared-key authentication.
        if [ ! -f /etc/iked/private/local.key ]; then
          (umask 077; ${lib.getExe' pkgs.libressl "openssl"} ecparam \
            -genkey -name prime256v1 -out /etc/iked/private/local.key) || return 1
        fi
        rm -f /var/run/iked.sock
      '';
    };
  };
}
