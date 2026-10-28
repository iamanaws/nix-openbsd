{
  flakeRef ? "path:" + toString ../..,
  flake ? builtins.getFlake flakeRef,
}:
let
  inherit (flake.inputs.nixbsd.inputs.nixpkgs) lib;
  base = flake.nixosConfigurations.openbsd-native;
  pkgs = base.pkgs;
  dhcpConfig = dns: ''
    authoritative;
    default-lease-time 30;
    max-lease-time 30;
    subnet 192.0.2.0 netmask 255.255.255.0 {
      range 192.0.2.100 192.0.2.100;
      option routers 192.0.2.1;
      option domain-name-servers ${dns};
    }
  '';
  common = { lib, pkgs, ... }: {
    networking.useDHCP = false;
    networking.interfaces.vio0.useDHCP = true;
    services.resolvd.config = lib.mkForce "";
    services.ntpd.config = lib.mkForce "server 127.0.0.2\n";
    environment.systemPackages = [
      pkgs.python3
      pkgs.openbsd.pkill
    ];
  };
  client = base.extendModules {
    modules = [
      common
      {
        networking.interfaces.vio1.useDHCP = true;
        networking.dhcpleased.config = ''
          interface vio0 { ignore dns }
          interface vio1 { ignore routes }
        '';
      }
    ];
  };
  server = base.extendModules {
    modules = [
      common
      {
        networking.interfaces.vio1 = {
          useDHCP = false;
          ipv4.addresses = [
            {
              address = "192.0.2.1";
              prefixLength = 24;
            }
            {
              address = "192.0.2.254";
              prefixLength = 24;
            }
          ];
        };
        services.dhcpd = {
          enable = true;
          interfaces = [ "vio1" ];
          config = dhcpConfig "192.0.2.1";
        };
      }
    ];
  };
  static = base.extendModules {
    modules = [
      {
        networking.interfaces.vio0.ipv4.addresses = [
          {
            address = "192.0.2.2";
            prefixLength = 24;
          }
        ];
      }
    ];
  };
  conflicting = base.extendModules {
    modules = [
      {
        networking.dhcpcd.enable = true;
        networking.dhcpleased.enable = true;
      }
    ];
  };
  withoutResolver = client.extendModules {
    modules = [ { services.resolvd.enable = lib.mkForce false; } ];
  };
in
assert base.config.networking.dhcpleased.enable;
assert !base.config.networking.dhcpcd.enable;
assert
  base.config.init.services.dhcpleased.dependencies == [
    "FILESYSTEMS"
    "resolvd"
  ];
assert base.config.init.services.resolvd.dependencies == [ "FILESYSTEMS" ];
assert base.config.openbsd.rc.services.dhcpleased.shellVariables.rc_reload == false;
assert lib.hasInfix "inet -autoconf" static.config.init.services.network_interfaces.postStart;
assert lib.hasInfix "vio0" static.config.init.services.network_interfaces.postStart;
assert lib.hasInfix "vio1" client.config.init.services.network_interfaces.postStart;
assert lib.hasInfix "continue" client.config.init.services.network_interfaces.postStart;
assert !(lib.elem "resolvd" withoutResolver.config.init.services.dhcpleased.dependencies);
assert lib.any (
  a: !a.assertion && lib.hasInfix "only one DHCP client" a.message
) conflicting.config.assertions;
{
  passed = true;
  inherit client server;
  all = pkgs.linkFarm "openbsd-dhcp-tests" [
    {
      name = "client";
      path = client.config.system.build.toplevel;
    }
    {
      name = "server";
      path = server.config.system.build.toplevel;
    }
    {
      name = "renewal";
      path = pkgs.writeText "dhcpd-renewal.conf" (dhcpConfig "192.0.2.254");
    }
    {
      name = "invalid";
      path = pkgs.writeText "dhcpleased-invalid.conf" "invalid dhcpleased configuration\n";
    }
    {
      name = "daemon-source";
      path = pkgs.openbsd.dhcpleased.src;
    }
    {
      name = "control-source";
      path = pkgs.openbsd.dhcpleasectl.src;
    }
  ];
}
