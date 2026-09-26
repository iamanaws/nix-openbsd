{ flake }:
let
  base = flake.nixosConfigurations.openbsd-native;
  pkgs = base.pkgs;
  system = modules: (base.extendModules { inherit modules; }).config.system.build.toplevel;
  changed = { lib, pkgs, ... }: {
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
    a = base.config.system.build.toplevel;
    b = system [ changed ];
    invalid = system [
      ({ lib, ... }: {
        services.httpd.config = lib.mkForce "this is not an httpd configuration";
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
  };
in
systems
// {
  all = pkgs.linkFarm "openbsd-generation-test-systems" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) systems
  );
}
