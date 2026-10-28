{
  flakeRef ? "path:" + toString ../..,
  flake ? builtins.getFlake flakeRef,
}:
let
  inherit (flake.inputs.nixbsd.inputs.nixpkgs) lib;
  base = flake.nixosConfigurations.openbsd-native;
  pkgs = base.pkgs;
  advertisements = prefix: dns: ''
    interface vio1 {
      no auto prefix
      router lifetime 30
      prefix ${prefix}::/64 {
        preferred lifetime 20
        valid lifetime 40
      }
      dns {
        nameserver 2001:db8:100::${dns}
        search slaac.example.com
        lifetime 30
      }
    }
    interface vio2 {
      no auto prefix
      prefix 2001:db8:300::/64
    }
  '';
  common = { lib, pkgs, ... }: {
    networking.useDHCP = false;
    networking.interfaces.vio0 = {
      useDHCP = true;
      useSLAAC = false;
    };
    services.resolvd.config = lib.mkForce "";
    services.ntpd.config = lib.mkForce "server 127.0.0.2\n";
    environment.systemPackages = [
      pkgs.python3
      pkgs.openbsd.route
      pkgs.openbsd.pkill
    ];
  };
  client = base.extendModules {
    modules = [
      common
      {
        networking.dhcpleased.config = "interface vio0 { ignore dns }\n";
        networking.interfaces = {
          # Static IPv4 must not suppress IPv6 SLAAC discovery.
          vio1.ipv4.addresses = [
            {
              address = "192.0.2.2";
              prefixLength = 24;
            }
          ];
          vio2.ipv6.addresses = [
            {
              address = "2001:db8:300::2";
              prefixLength = 64;
            }
          ];
        };
      }
    ];
  };
  server = base.extendModules {
    modules = [
      common
      {
        networking.useSLAAC = false;
        boot.kernel.sysctl."net.inet6.ip6.forwarding" = 1;
        networking.interfaces = {
          vio1.ipv6.addresses =
            map
              (address: {
                inherit address;
                prefixLength = 64;
              })
              [
                "2001:db8:100::1"
                "2001:db8:100::53"
                "2001:db8:100::54"
                "2001:db8:200::1"
              ];
          vio2.ipv6.addresses = [
            {
              address = "2001:db8:300::1";
              prefixLength = 64;
            }
          ];
        };
        services.rad = {
          enable = true;
          config = advertisements "2001:db8:100" "53";
        };
      }
    ];
  };
  noSLAAC = base.extendModules { modules = [ { networking.useSLAAC = false; } ]; };
  explicit = noSLAAC.extendModules {
    modules = [ { networking.interfaces.vio1.useSLAAC = true; } ];
  };
  disabled = base.extendModules { modules = [ { networking.slaacd.enable = false; } ]; };
  noIPv6 = base.extendModules { modules = [ { networking.enableIPv6 = false; } ]; };
  legacy = base.extendModules { modules = [ { networking.dhcpcd.enable = true; } ]; };
  conflicting = legacy.extendModules {
    modules = [ { networking.slaacd.enable = true; } ];
  };
  withoutResolver = client.extendModules {
    modules = [ { services.resolvd.enable = lib.mkForce false; } ];
  };
  noTemporary = client.extendModules {
    modules = [ { networking.tempAddresses = "disabled"; } ];
  };
  staticOverride = client.extendModules {
    modules = [ { networking.interfaces.vio2.useSLAAC = true; } ];
  };
in
assert base.config.openbsd.rc.services ? slaacd;
assert !(noSLAAC.config.openbsd.rc.services ? slaacd);
assert !(disabled.config.openbsd.rc.services ? slaacd);
assert !(noIPv6.config.openbsd.rc.services ? slaacd);
assert !(legacy.config.openbsd.rc.services ? slaacd);
assert explicit.config.openbsd.rc.services ? slaacd;
assert
  base.config.init.services.slaacd.dependencies == [
    "FILESYSTEMS"
    "resolvd"
  ];
assert base.config.openbsd.rc.services.slaacd.shellVariables.rc_reload == false;
assert
  server.config.init.services.sysctl.startCommand == [
    "${pkgs.openbsd.sysctl}/bin/sysctl"
    "-f"
    "/etc/sysctl.conf"
  ];
assert
  server.config.init.services.sysctl-lastload.startCommand
  == server.config.init.services.sysctl.startCommand;
assert !(lib.elem "resolvd" withoutResolver.config.init.services.slaacd.dependencies);
assert lib.hasInfix "inet6 -autoconf -temporary"
  client.config.init.services.network_interfaces.postStart;
assert lib.hasInfix "inet6 autoconf -temporary up"
  noTemporary.config.init.services.network_interfaces.postStart;
assert lib.hasInfix "vio2) ;;" staticOverride.config.init.services.network_interfaces.postStart;
assert lib.any (
  a: !a.assertion && lib.hasInfix "only one SLAAC client" a.message
) conflicting.config.assertions;
{
  passed = true;
  inherit client server;
  all = pkgs.linkFarm "openbsd-slaac-tests" [
    {
      name = "client";
      path = client.config.system.build.toplevel;
    }
    {
      name = "server";
      path = server.config.system.build.toplevel;
    }
    {
      name = "changed";
      path = pkgs.writeText "rad-changed.conf" (advertisements "2001:db8:200" "54");
    }
    {
      name = "no-temporary";
      path = noTemporary.config.system.build.toplevel;
    }
    {
      name = "explicit-static";
      path = staticOverride.config.system.build.toplevel;
    }
    {
      name = "daemon-source";
      path = pkgs.openbsd.slaacd.src;
    }
    {
      name = "control-source";
      path = pkgs.openbsd.slaacctl.src;
    }
  ];
}
