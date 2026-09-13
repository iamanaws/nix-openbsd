{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.pf;
  configPath = "/etc/pf.conf";
  pfctl = "${cfg.package}/bin/pfctl";
  commonArgs = cfg.extraFlags ++ [ "-f" configPath ];
in
{
  options.services.pf = {
    enable = lib.mkEnableOption "OpenBSD packet filter rules";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.pfctl;
      defaultText = lib.literalExpression "pkgs.openbsd.pfctl";
      description = "The OpenBSD pfctl package to use.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of pf.conf(5).";
    };

    fingerprints = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Verbatim contents of pf.os(5), or empty when OS fingerprint matching is unused.";
    };

    enableFilter = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable PF while loading the configured ruleset.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to pfctl.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."pf.conf".text = cfg.config;
    environment.etc."pf.os".text = cfg.fingerprints;
    environment.systemPackages = [ cfg.package ];

    init.services.pf = {
      description = "Load OpenBSD packet filter rules";
      dependencies = [ "NETWORKING" ];
      before = [ "SERVERS" ];
      startType = "oneshot";
      startCommand = [ pfctl ] ++ commonArgs;
      preStart = ''
        ${pfctl} -n ${lib.escapeShellArgs commonArgs}
        ${lib.optionalString cfg.enableFilter "${pfctl} -e 2>/dev/null || true"}
      '';
    };
  };
}
