{ base }:
let
  pkgs = base.pkgs;
  common = { lib, ... }: {
    nix.settings = {
      sandbox = lib.mkForce true;
      sandbox-fallback = false;
      sandbox-rdomains = [
        "201"
        "202"
        "203"
        "204"
      ];
      trusted-users = lib.mkForce [ "root" ];
    };
    services.pf.enable = lib.mkForce false;
    openbsd.rc.conf.pf = lib.mkForce false;
    system.activationScripts.managedSandboxFailure.text = ''
      if [ -e /run/nix-managed-fail-activation ]; then
        rm /run/nix-managed-fail-activation
        echo 'managed sandbox activation failure' >&2
        exit 1
      fi
    '';
  };
  system =
    name:
    base.extendModules {
      modules = [
        common
        ({ lib, ... }: {
          services.httpd.documentRoot = lib.mkForce (
            pkgs.writeTextDir "index.html" "Managed sandbox generation ${name}\n"
          );
        })
      ];
    };
  a = system "a";
  b = system "b";
  changed = a.extendModules {
    modules = [ ({ lib, ... }: { nix.settings.max-jobs = lib.mkForce 2; }) ];
  };
  systems = builtins.mapAttrs (_: value: value.config.system.build.toplevel) {
    inherit a b;
    changed-nix = changed;
  };
in
assert builtins.all (value: builtins.all (item: item.assertion) value.config.assertions) [
  a
  b
  changed
];
assert !a.config.services.pf.enable;
assert a.config.openbsd.rc.conf.pf == false;
assert
  a.config.environment.etc."nix/nix.conf".source == b.config.environment.etc."nix/nix.conf".source;
assert
  a.config.environment.etc."rc.d/nix_daemon".source
  == b.config.environment.etc."rc.d/nix_daemon".source;
systems
// {
  passed = true;
  all = pkgs.linkFarm "openbsd-managed-sandbox-systems" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) systems
  );
}
