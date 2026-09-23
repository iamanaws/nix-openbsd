# OpenBSD integration fixes kept here until they can be tested upstream.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.networking;
  interfaces = builtins.attrValues cfg.interfaces;
  mtuInterfaces = builtins.filter (i: i.mtu != null) interfaces;
  gateway = cfg.defaultGateway6;
  hasGateway = gateway != null && gateway.address != "";
  dhcp = cfg.dhcpcd.enable && (cfg.useDHCP || lib.any (i: i.useDHCP == true) interfaces);
  networkOptions = pkgs.writeShellScript "openbsd-network-options" ''
    set -e
    ${lib.concatMapStringsSep "\n" (i: ''
      ${pkgs.openbsd.ifconfig}/bin/ifconfig ${lib.escapeShellArg i.name} mtu ${toString i.mtu}
    '') mtuInterfaces}
    ${lib.optionalString hasGateway (
      let
        args = lib.escapeShellArgs (
          [
            "-inet6"
            "default"
            gateway.address
          ]
          ++ lib.optionals (gateway.interface != null) [
            "-ifp"
            gateway.interface
          ]
          ++ lib.optionals (gateway.metric != null) [
            "-priority"
            (toString gateway.metric)
          ]
        );
      in
      ''
        ${pkgs.openbsd.route}/bin/route -n add ${args} ||
          ${pkgs.openbsd.route}/bin/route -n change ${args}
      ''
    )}
  '';
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isOpenBSD {
    # Without a ruleset, rc leaves its temporary outbound block rules active.
    openbsd.rc.conf.pf = lib.mkDefault false;
    system.switch.enable = lib.mkDefault false;
    assertions = [
      {
        assertion = !config.system.switch.enable;
        message = "OpenBSD live switching is not supported; set system.switch.enable = false.";
      }
    ];
    # rc.subr must match the manager's changed title, not dhcpcd's original argv.
    openbsd.rc.services = lib.mkIf dhcp {
      dhcpcd.shellVariables.pexp = "dhcpcd: \\[manager\\].*";
    };
    system.build.openbsdNetworkOptions = networkOptions;
    # NixBSD configures the addresses; apply the missing options afterward.
    init.services.network_interfaces.postStart =
      lib.mkIf (mtuInterfaces != [ ] || hasGateway)
        "${networkOptions}";
  };
}
