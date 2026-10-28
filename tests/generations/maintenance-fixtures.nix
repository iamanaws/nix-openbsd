{ flake }:
let
  base = flake.nixosConfigurations.openbsd-native.extendModules {
    modules = [
      ({ pkgs, ... }: {
        environment.systemPackages = [ pkgs.python3 ];
        services.smtpd.aliases = "root: bestie\npostmaster: root\nMAILER-DAEMON: postmaster\n";
        environment.etc."locate.rc".text = ''
          SEARCHPATHS=/var/lib/maintenance-test/locate
          PRUNEPATHS=""
        '';
        services.tempfiles.directories."/var/lib/maintenance-test".group = "root";
      })
    ];
  };
  pkgs = base.pkgs;
  settings = name: {
    services.maintenance = {
      enable = true;
      daily = {
        schedule = "0 0 31 2 *";
        config = ''
          CALENDAR=0
          SUIDSKIP="/nix /tmp /var/tmp"
          echo native-${name}-daily-$(cat /var/lib/maintenance-test/token)
        '';
      };
      weekly = {
        schedule = "0 0 31 2 *";
        config = ''
          MAKEWHATISARGS=/var/lib/maintenance-test/man
          echo native-${name}-weekly-$(cat /var/lib/maintenance-test/token)
        '';
      };
      monthly = {
        schedule = "* * * * *";
        config = "echo native-${name}-monthly-$(cat /var/lib/maintenance-test/token)";
      };
    };
  };
  a = settings "a";
  b = settings "b";
  system = modules: (base.extendModules { inherit modules; }).config.system.build.toplevel;
  systems = {
    a = system [ a ];
    b = system [ b ];
    invalid = system [
      b
      ({ lib, ... }: { services.maintenance.daily.config = lib.mkForce "if then\n"; })
    ];
    invalid-schedule = system [
      b
      ({ lib, ... }: { services.maintenance.daily.schedule = lib.mkForce "99 99 * * *"; })
    ];
    failed-activation = system [
      b
      { system.activationScripts.maintenanceFailure.text = "false"; }
    ];
    without-monthly = system [
      a
      { services.maintenance.monthly.enable = false; }
    ];
    disabled = system [ ];
  };
in
systems
// {
  all = pkgs.linkFarm "openbsd-maintenance-generation-tests" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) (
      systems // { inherit (pkgs.openbsd) calendar locate; }
    )
  );
}
