{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.security.acme-client;
  configPath = "/etc/acme-client.conf";
  acmeClient = "${cfg.package}/bin/acme-client";
  renewalHook = lib.concatStringsSep "; " (
    lib.filter (hook: hook != "") [
      (lib.optionalString cfg.reloadHttpd "/etc/rc.d/httpd reload")
      cfg.postRenewalHook
    ]
  );
  renewalCommand =
    domain:
    "${acmeClient} -f ${configPath} ${lib.escapeShellArg domain}"
    + lib.optionalString (renewalHook != "") " && { ${renewalHook}; }";
in
{
  options.security.acme-client = {
    enable = lib.mkEnableOption "OpenBSD acme-client renewal";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbsd.acme-client;
      defaultText = lib.literalExpression "pkgs.openbsd.acme-client";
      description = "The OpenBSD acme-client package to use.";
    };

    config = lib.mkOption {
      type = lib.types.lines;
      description = "Verbatim contents of acme-client.conf(5).";
    };

    domains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "example.com" ];
      description = "Domain handles from acme-client.conf to renew.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "0 0 * * *";
      description = "Five-field cron schedule used for every domain.";
    };

    accountDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/etc/acme";
      description = "Directory for ACME account private keys.";
    };

    challengeDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/www/acme";
      description = "Directory served for HTTP-01 challenges.";
    };

    certificateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssl/acme";
      description = "Directory for issued certificates and keys.";
    };

    reloadHttpd = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Reload the OpenBSD httpd service after successful renewal.";
    };

    postRenewalHook = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Shell command run after a certificate is renewed.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (lib.hasPrefix "/") [
          cfg.accountDirectory
          cfg.challengeDirectory
          cfg.certificateDirectory
        ];
        message = "OpenBSD acme-client directories must use absolute paths.";
      }
    ];

    environment.etc."acme-client.conf".text = cfg.config;
    environment.systemPackages = [ cfg.package ];

    services.cron.enable = lib.mkDefault true;
    services.cron.systemCronJobs = map (
      domain: "${cfg.schedule} root ${renewalCommand domain}"
    ) cfg.domains;

    systemd.tmpfiles.rules = [
      "d ${cfg.accountDirectory} 0700 root wheel - -"
      "d ${cfg.challengeDirectory} 0755 root wheel - -"
      "d ${cfg.certificateDirectory} 0700 root wheel - -"
    ];

    init.services.acme-client-check = {
      description = "Validate OpenBSD acme-client configuration";
      dependencies = [ "FILESYSTEMS" ];
      before = [ "cron" ];
      startType = "oneshot";
      startCommand = [
        acmeClient
        "-n"
        "-f"
        configPath
      ];
    };
  };
}
