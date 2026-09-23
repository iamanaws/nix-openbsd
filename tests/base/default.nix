# Run with: nix eval --impure --json --file tests/base/default.nix passed
{
  flakeRef ? "path:" + toString ../..,
}:
let
  flake = builtins.getFlake flakeRef;
  inherit (flake.inputs.nixbsd.inputs.nixpkgs) lib;
  base = flake.inputs.nixbsd.nixosConfigurations.openbsd-base.extendModules {
    modules = [
      ../../modules/system/openbsd.nix
      { nixpkgs.buildPlatform = "x86_64-linux"; }
    ];
  };
  network = base.extendModules {
    modules = [
      {
        networking.interfaces.vio0 = {
          mtu = 1400;
          ipv6.addresses = [
            {
              address = "2001:db8::2";
              prefixLength = 64;
            }
          ];
        };
        networking.defaultGateway6 = {
          address = "2001:db8::1";
          interface = "vio0";
          metric = 10;
        };
      }
    ];
  };
  script =
    (builtins.head network.config.init.services.network_interfaces.startCommand).text
    + "\n"
    + network.config.system.build.openbsdNetworkOptions.text;
  extra = base.extendModules {
    modules = [
      {
        # MTU must also apply to interfaces without static addresses.
        networking.interfaces.vio1.mtu = 1450;
        networking.defaultGateway = "192.0.2.1";
      }
    ];
  };
  extraScript =
    (builtins.head extra.config.init.services.network_interfaces.startCommand).text
    + "\n"
    + extra.config.system.build.openbsdNetworkOptions.text;
  noDHCP = base.extendModules { modules = [ { networking.useDHCP = false; } ]; };
  disabledDhcpcd = base.extendModules { modules = [ { networking.dhcpcd.enable = false; } ]; };
  interfaceDHCP = noDHCP.extendModules {
    modules = [ { networking.interfaces.vio0.useDHCP = true; } ];
  };
  enabledSwitch = base.extendModules { modules = [ { system.switch.enable = true; } ]; };
in
assert base.config.openbsd.rc.conf.pf == false;
assert base.config.system.switch.enable == false;
assert lib.any (
  a: !a.assertion && lib.hasPrefix "OpenBSD live switching" a.message
) enabledSwitch.config.assertions;
assert base.config.openbsd.rc.services.dhcpcd.shellVariables.pexp == "dhcpcd: \\[manager\\].*";
assert !(noDHCP.config.openbsd.rc.services ? dhcpcd);
assert !(disabledDhcpcd.config.openbsd.rc.services ? dhcpcd);
assert
  interfaceDHCP.config.openbsd.rc.services.dhcpcd.shellVariables.pexp == "dhcpcd: \\[manager\\].*";
assert lib.hasInfix "ifconfig vio0 mtu 1400" script;
assert lib.hasInfix "ifconfig vio1 mtu 1450" extraScript;
assert lib.hasInfix "inet6 2001:db8::2/64 alias" script;
assert lib.hasInfix "add -inet default 192.0.2.1" extraScript;
assert lib.hasInfix "add -inet6 default 2001:db8::1 -ifp vio0 -priority 10" script;
assert lib.hasInfix "change -inet6 default 2001:db8::1 -ifp vio0 -priority 10" script;
{
  passed = true;
  # Check boot configuration, then exercise the service's repeat-start path.
  probe = ''
    if bash -eu <<'OPENBSD_NETWORK_PROBE'
      check_network() {
        ${network.pkgs.openbsd.ifconfig}/bin/ifconfig vio0 | grep 'mtu 1400'
        ${network.pkgs.openbsd.ifconfig}/bin/ifconfig vio0 | grep 'inet6 2001:db8::2 '
        ${network.pkgs.openbsd.route}/bin/route -n get -inet6 default | grep 'gateway: 2001:db8::1'
      }
      check_network
      /etc/rc.d/network_interfaces start
      check_network
    OPENBSD_NETWORK_PROBE
    then
      printf '\nOPENBSD_NETWORK_%s\n' PASS
    else
      printf '\nOPENBSD_NETWORK_%s\n' FAIL
    fi
  '';
  vm = network.config.system.build.vm;
}
