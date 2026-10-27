{ flake }:
let
  base = flake.nixosConfigurations.openbsd-native.extendModules {
    modules = [
      ({ pkgs, ... }: {
        environment.systemPackages = [ pkgs.python3 ];
        security.sudo.enable = false;
        users.users.doas-test.isNormalUser = true;
        security.doas.extraRules = [
          {
            users = [ "bestie" ];
            runAs = "daemon";
            cmd = "${pkgs.coreutils}/bin/id";
            args = [ "-u" ];
            noPass = true;
          }
          {
            users = [ "bestie" ];
            runAs = "daemon";
            cmd = "${pkgs.coreutils}/bin/env";
            args = [ ];
            noPass = true;
          }
        ];
      })
    ];
  };
  pkgs = base.pkgs;
  system = modules: (base.extendModules { inherit modules; }).config.system.build.toplevel;
  rule = name: {
    security.doas.extraRules = [
      {
        users = [ "bestie" ];
        runAs = "root";
        cmd = "${pkgs.coreutils}/bin/echo";
        args = [ name ];
        noPass = true;
      }
    ];
  };
  systems = {
    a = system [ (rule "a") ];
    b = system [ (rule "b") ];
    nopass-wheel = system [
      (rule "a")
      { security.doas.wheelNeedsPassword = false; }
    ];
    without-doas = system [
      ({ lib, ... }: { security.doas.enable = lib.mkForce false; })
    ];
    invalid = system [
      (rule "b")
      ({ lib, ... }: {
        # Bypass the build-time check to exercise validation before activation.
        environment.etc."doas.conf".source = lib.mkForce (
          pkgs.writeText "invalid-doas.conf" "permit nopass\n"
        );
      })
    ];
    failed-activation = system [
      (rule "b")
      { system.activationScripts.doasFailure.text = "false"; }
    ];
  };
in
systems
// {
  all = pkgs.linkFarm "openbsd-doas-generation-tests" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) systems
    ++ [
      {
        # doas matches command paths literally, before resolving binary symlinks.
        name = "coreutils";
        path = pkgs.coreutils;
      }
    ]
  );
}
