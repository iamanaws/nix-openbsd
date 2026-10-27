{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.smtpd;
  smtpd = "${cfg.package}/bin/smtpd";
  # Text tables avoid a writable aliases database and become part of each generation.
  aliases = pkgs.writeText "smtpd-aliases" cfg.aliases;
in
{
  imports = [ ../system/tempfiles.nix ];
  options.services.smtpd = {
    enable = lib.mkEnableOption "OpenBSD local mail delivery";
    package = lib.mkPackageOption pkgs [ "openbsd" "smtpd" ] { };
    aliases = lib.mkOption {
      type = lib.types.lines;
      default = "postmaster: root\nMAILER-DAEMON: postmaster\n";
      example = "root: alice\npostmaster: root\n";
      description = "Local aliases in aliases(5) format. These are read as a text table.";
    };
    config = lib.mkOption {
      type = lib.types.lines;
      default = ''
        table aliases file:${aliases}
        listen on socket
        action "local_mail" mbox alias <aliases>
        match from local for local action "local_mail"
      '';
      defaultText = lib.literalExpression ''
        Local submission through the Unix socket, delivering to /var/mail
        with services.smtpd.aliases. No TCP listener or outbound relay.
      '';
      description = "Verbatim smtpd.conf(5) configuration. The default reads the generation's aliases file directly.";
    };
    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to smtpd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."mail/smtpd.conf".text = cfg.config;
    environment.etc."mail/aliases".source = aliases;
    environment.systemPackages = [ cfg.package ];

    users.users._smtpd = {
      uid = 95;
      isSystemUser = true;
      group = "_smtpd";
      home = "/var/empty";
      description = "OpenBSD SMTP daemon";
    };
    users.groups._smtpd.gid = 95;
    users.users._smtpq = {
      uid = 103;
      isSystemUser = true;
      group = "_smtpq";
      home = "/var/empty";
      description = "OpenBSD SMTP queue";
    };
    users.groups._smtpq.gid = 103;

    # smtpctl uses its invocation name to provide sendmail compatibility.
    security.wrappers.sendmail = {
      source = "${cfg.package}/bin/sendmail";
      owner = "root";
      group = "_smtpq";
      setgid = true;
    };
    security.wrappers.lockspool = {
      source = "${pkgs.openbsd.lockspool}/bin/lockspool";
      owner = "root";
      group = "wheel";
      setuid = true;
    };

    services.tempfiles.directories = {
      "/var/empty".mode = "0555";
      "/var/mail" = {
        mode = "0755";
        group = "root";
      };
      "/var/spool" = { };
      # smtpd checks numeric gid 0; NixBSD's wheel group has gid 1.
      "/var/spool/smtpd" = {
        mode = "0711";
        group = "root";
      };
      "/var/spool/smtpd/offline" = {
        mode = "0770";
        group = "_smtpq";
      };
    }
    //
      lib.genAttrs
        (map (name: "/var/spool/smtpd/${name}") [
          "corrupt"
          "incoming"
          "purge"
          "queue"
          "temporary"
        ])
        (_: {
          mode = "0700";
          user = "_smtpq";
          group = "root";
        });

    openbsd.rc.services.smtpd.shellVariables.rc_reload = false;
    init.services.smtpd = {
      description = "OpenBSD local mail daemon";
      dependencies = [
        "NETWORKING"
        # The OpenBSD backend matches the generated rc.d name.
        "suid_sgid_wrappers"
      ];
      before = [ "SERVERS" ];
      startType = "forking";
      path = [ pkgs.coreutils ];
      startCommand = [
        smtpd
        "-f"
        "/etc/mail/smtpd.conf"
      ]
      ++ cfg.extraFlags;
      preStart = ''
        ${smtpd} -n -f /etc/mail/smtpd.conf
      '';
    };
  };
}
