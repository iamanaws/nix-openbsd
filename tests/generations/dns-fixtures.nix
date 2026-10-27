{ flake }:
let
  base = flake.nixosConfigurations.openbsd-native.extendModules {
    modules = [
      ({ lib, pkgs, ... }: {
        environment.systemPackages = [ pkgs.python3 ];
        services.ntpd.config = lib.mkForce "server 127.0.0.2\n";
        services.unwind.enable = true;
        # Fail once for recovery; preserve unwind's usual SIGHUP reload below.
        openbsd.rc.services = lib.genAttrs [ "resolvd" "unwind" ] (name: {
          hooks.rc_reload = lib.mkBefore ''
            if [ -f /run/dns-fail-${name}-reload ]; then
              rm /run/dns-fail-${name}-reload
              return 1
            fi
            ${lib.optionalString (name == "unwind") "_rc_sendsig HUP"}
          '';
        });
      })
    ];
  };
  pkgs = base.pkgs;
  # libunbound answers .test locally; use a domain served by our test forwarder.
  settings = name: { lib, ... }: {
    services.resolvd.config = lib.mkForce ''
      search ${name}.dns.example.com
      nameserver 10.0.2.3
      lookup bind file
    '';
    services.unwind.config = ''
      forwarder { 127.0.0.1 port 15353 }
      preference { forwarder }
      force accept bogus forwarder { dns.example.com }
      block list "${pkgs.writeText "dns-blocklist-${name}" "blocked-${name}.dns.example.com\n"}"
    '';
  };
  system =
    name: modules:
    (base.extendModules {
      modules = [ (settings name) ] ++ modules;
    }).config.system.build.toplevel;
  systems = {
    a = system "a" [ ];
    b = system "b" [ ];
    invalid = system "b" [
      ({ lib, ... }: {
        services.unwind.config = lib.mkForce "this is not an unwind configuration";
      })
    ];
    failed-activation = system "b" [
      { system.activationScripts.dnsFailure.text = "false"; }
    ];
  }
  // pkgs.lib.genAttrs [ "failed-resolvd-start" "failed-unwind-start" ] (
    name:
    let
      service = if name == "failed-resolvd-start" then "resolvd" else "unwind";
    in
    system "b" [
      ({ lib, ... }: {
        services.${service}.extraFlags = [ "-v" ];
        init.services.${service}.preStart = lib.mkAfter "false";
      })
    ]
  );
in
systems
// {
  all = pkgs.linkFarm "openbsd-dns-generation-tests" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) systems
  );
}
