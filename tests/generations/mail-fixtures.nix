{ flake }:
let
  base = flake.nixosConfigurations.openbsd-native.extendModules {
    modules = [
      ({ pkgs, ... }: {
        environment.systemPackages = [ pkgs.python3 ];
        users.users.mail-test.isNormalUser = true;
      })
    ];
  };
  pkgs = base.pkgs;
  settings = name: recipient: {
    services.smtpd.aliases = ''
      root: ${recipient}
      postmaster: root
      MAILER-DAEMON: postmaster
      cron-report: root
    '';
    services.cron.systemCronJobs = [
      "MAILTO=cron-report"
      "* * * * * daemon echo mail-cron-${name}"
    ];
  };
  a = settings "a" "bestie";
  b = settings "b" "mail-test";
  system = modules: (base.extendModules { inherit modules; }).config.system.build.toplevel;
  systems = {
    a = system [ a ];
    b = system [ b ];
    invalid = system [
      b
      ({ lib, ... }: {
        services.smtpd.config = lib.mkForce "not an smtpd configuration\n";
      })
    ];
    failed-start = system [
      b
      ({ lib, ... }: {
        init.services.smtpd.preStart = lib.mkAfter "false";
      })
    ];
    failed-activation = system [
      b
      {
        system.activationScripts.mailFailure.text = "false";
      }
    ];
    without-mail = system [
      ({ lib, ... }: {
        services.smtpd.enable = lib.mkForce false;
      })
    ];
  };
in
systems
// {
  all = pkgs.linkFarm "openbsd-mail-generation-tests" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) systems
  );
}
