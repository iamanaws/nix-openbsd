{
  flake,
  withCronctl ? true,
}:
let
  base = flake.nixosConfigurations.openbsd-native.extendModules {
    modules = [ cron ];
  };
  pkgs = base.pkgs;
  system = modules: (base.extendModules { inherit modules; }).config.system.build.toplevel;
  job =
    name:
    pkgs.writeShellScript "cron-job-${name}" ''
      set -eu
      umask 077
      test "$(id -un)" = daemon
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/cron-test/jobs.db \
        "create table if not exists runs (generation text, uid integer); insert into runs values ('${name}', $(id -u));"
    '';
  cron = { lib, pkgs, ... }: {
    environment.systemPackages = [ pkgs.sqlite ];
    services.cron = {
      enable = true;
      systemCronJobs = lib.mkBefore [
        ''MAILTO=""''
        "@reboot daemon ${pkgs.coreutils}/bin/echo boot >> /var/lib/cron-test/boots"
      ];
    }
    // lib.optionalAttrs (!withCronctl) { controlPackage = null; };
    services.tempfiles.directories = {
      "/var/lib/cron-test" = {
        mode = "0700";
        user = "daemon";
        group = "daemon";
      };
      "/var/lib/directory-test" = {
        mode = "0700";
        user = "daemon";
        group = "daemon";
      };
    };
    # Fail one reload so recovery can reload the previous configuration.
    openbsd.rc.services.cron.hooks.rc_reload = lib.mkIf withCronctl (
      lib.mkBefore ''
        if [ -f /run/cron-fail-reload ]; then
          rm /run/cron-fail-reload
          return 1
        fi
      ''
    );
  };
  changed = { lib, pkgs, ... }: {
    services.ntpd.config = lib.mkForce "server 127.0.0.3\n";
    services.tempfiles.directories = {
      "/var/lib/directory-test" = {
        mode = lib.mkForce "0750";
        user = lib.mkForce "root";
        group = lib.mkForce "wheel";
      };
      "/var/lib/directory-test/new" = { };
    };
    environment.systemPackages = [ pkgs.hello ];
    services.httpd.documentRoot = lib.mkForce (pkgs.writeTextDir "index.html" "NixBSD generation B\n");
    init.services.generation_probe = {
      description = "Generation test daemon";
      dependencies = [ "DAEMON" ];
      startType = "foreground";
      startCommand = [
        "${pkgs.coreutils}/bin/sleep"
        "12345"
      ];
    };
    openbsd.system.services.generation_probe = { };
  };
  systems = {
    a = system [
      ({ lib, ... }: {
        services.cron.systemCronJobs = [ "* * * * * daemon ${job "a"}" ];
        services.ntpd.config = lib.mkForce "server 127.0.0.2\n";
      })
    ];
    b = system [
      changed
      { services.cron.systemCronJobs = [ "* * * * * daemon ${job "b"}" ]; }
    ];
    invalid-cron = system [
      ({ lib, ... }: {
        services.cron.systemCronJobs = [ "60 * * * * daemon true" ];
        services.ntpd.config = lib.mkForce "server 127.0.0.2\n";
      })
    ];
    invalid-ntpd = system [
      ({ lib, ... }: {
        services.ntpd.config = lib.mkForce "this is not an ntpd configuration";
      })
    ];
    invalid = system [
      ({ lib, ... }: {
        services.httpd.config = lib.mkForce "this is not an httpd configuration";
        services.ntpd.config = lib.mkForce "server 127.0.0.2\n";
      })
    ];
    failed-ntpd-start = system [
      changed
      ({ lib, ... }: {
        init.services.ntpd.preStart = lib.mkAfter "false";
      })
    ];
    failed-start = system [
      changed
      ({ lib, ... }: {
        init.services.httpd.preStart = lib.mkAfter "false";
      })
    ];
    failed-activation = system [
      changed
      {
        system.activationScripts.generationFailure.text = "false";
      }
    ];
    failed-directories = system [
      changed
      { services.tempfiles.directories."/var/lib/directory-test/blocker/child" = { }; }
    ];
  };
in
systems
// {
  all = pkgs.linkFarm "openbsd-generation-test-systems" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) systems
  );
}
