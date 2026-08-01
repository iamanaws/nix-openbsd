{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.ipsec;
  configPath = "/etc/ipsec.conf";
  ipsecctl = "${cfg.package}/bin/ipsecctl";
in
{
  options.services.ipsec = {
    enable = lib.mkEnableOption "OpenBSD IPsec policy loading";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.ipsecctl;
      defaultText = lib.literalExpression "pkgs.openbsd.ipsecctl";
      description = "The OpenBSD ipsecctl package to use.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of ipsec.conf(5).";
    };

    ikeService = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [
        "iked"
        "isakmpd"
      ]);
      default = null;
      description = "IKE daemon that must start before policies are loaded.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to ipsecctl.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."ipsec.conf".text = cfg.config;
    environment.systemPackages = [ cfg.package ];

    init.services.ipsec = {
      description = "Load OpenBSD IPsec policy";
      dependencies = [ "NETWORKING" ] ++ lib.optional (cfg.ikeService != null) cfg.ikeService;
      before = [ "SERVERS" ];
      startType = "oneshot";
      startCommand = [
        ipsecctl
        "-f"
        configPath
      ]
      ++ cfg.extraFlags;
      preStart = ''
        ${ipsecctl} -n -f ${configPath} ${lib.escapeShellArgs cfg.extraFlags}
      '';
    };
  };
}
