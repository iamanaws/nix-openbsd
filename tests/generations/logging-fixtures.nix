{ flake }:
let
  base = flake.nixosConfigurations.openbsd-native.extendModules {
    modules = [ ({ pkgs, ... }: { environment.systemPackages = [ pkgs.python3 ]; }) ];
  };
  pkgs = base.pkgs;
  settings = name: count: { lib, ... }: {
    services.syslogd.config = lib.mkAfter ''
      local0.notice /var/log/logging-${name}
    '';
    services.newsyslog = {
      config = lib.mkForce "/var/log/logging-${name} root:wheel 640 ${toString count} 1 *\n";
      createLogFiles = base.config.services.newsyslog.createLogFiles ++ [ "/var/log/logging-${name}" ];
    };
  };
  system = modules: (base.extendModules { inherit modules; }).config.system.build.toplevel;
  a = settings "a" 1;
  b = settings "b" 2;
  systems = {
    a = system [ a ];
    b = system [ b ];
    rotation = system [
      (settings "a" 2)
      { services.newsyslog.createLogFiles = [ "/var/log/logging-new" ]; }
    ];
    without-rotation = system [
      a
      ({ lib, ... }: { services.newsyslog.enable = lib.mkForce false; })
    ];
    invalid = system [
      b
      ({ lib, ... }: {
        services.newsyslog.config = lib.mkForce "this is not a newsyslog configuration\n";
      })
    ];
    failed-start = system [
      b
      ({ lib, ... }: {
        init.services.syslogd.preStart = lib.mkAfter "false";
      })
    ];
    failed-activation = system [
      b
      { system.activationScripts.loggingFailure.text = "false"; }
    ];
  };
in
systems
// {
  all = pkgs.linkFarm "openbsd-logging-generation-tests" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) systems
  );
}
