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
  options.services.iked = {
    enable = lib.mkEnableOption "OpenBSD iked";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.iked;
      defaultText = lib.literalExpression "pkgs.openbsd.iked";
      description = "The OpenBSD iked package to use.";
    };

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

    systemd.tmpfiles.rules = [
      "d /var/empty 0555 root root - -"
      "d /var/run 0755 root wheel - -"
      "d /etc/iked 0755 root wheel - -"
      "d /etc/iked/ca 0755 root wheel - -"
      "d /etc/iked/certs 0755 root wheel - -"
      "d /etc/iked/crls 0755 root wheel - -"
      "d /etc/iked/ocsp 0755 root wheel - -"
      "d /etc/iked/private 0700 root wheel - -"
      "d /etc/iked/pubkeys 0755 root wheel - -"
    ];

    # iked replaces its command line with a process title after starting.
    openbsd.rc.services.iked.shellVariables.pexp = "iked: parent.*";

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
        mkdir -p /var/empty /var/run /etc/iked/{ca,certs,crls,ocsp,private,pubkeys}
        chown root:wheel /etc/iked /etc/iked/{ca,certs,crls,ocsp,private,pubkeys}
        chmod 0700 /etc/iked/private
        # The unprivileged CA process must traverse its /etc/iked chroot.
        chmod 0755 /etc/iked /etc/iked/{ca,certs,crls,ocsp,pubkeys}
        # iked loads a local private key even with pre-shared-key authentication.
        if [ ! -f /etc/iked/private/local.key ]; then
          (umask 077; ${lib.getExe' pkgs.libressl "openssl"} ecparam \
            -genkey -name prime256v1 -out /etc/iked/private/local.key) || return 1
        fi
        rm -f /var/run/iked.sock
        ${iked} -n -f ${configPath}
      '';
    };
  };
}
