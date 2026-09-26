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
  networkPostStart = config.init.services.network_interfaces.postStart;
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
    # Activation checks root before mounting it writable. rc must not fsck it again.
    fileSystems."/".noCheck = true;
    # Without a ruleset, rc leaves its temporary outbound block rules active.
    openbsd.rc.conf.pf = lib.mkDefault false;
    system.switch.enable = lib.mkDefault false;
    # mount finds filesystem helpers through PATH before the login environment exists.
    environment.etc."rc".text = lib.mkBefore ''
      export PATH="${lib.makeBinPath config.system.fsPackages}:$PATH"
    '';
    # dev_mkdb creates dev.db as a file. Only its parent directory is needed here.
    environment.etc."rc".source = lib.mkForce (
      pkgs.writeText "rc" (
        lib.replaceStrings
          [ "mkdir -p /var/run/dev.db   # make su work" ]
          [ "mkdir -p /var/run" ]
          config.environment.etc."rc".text
      )
    );
    assertions = [
      {
        assertion = !config.system.switch.enable;
        message = "OpenBSD live switching is not supported; set system.switch.enable = false.";
      }
    ];
    # rc.subr must match the manager's changed title, not dhcpcd's original argv.
    openbsd.rc.services = lib.mkMerge [
      (lib.mkIf dhcp {
        dhcpcd.shellVariables.pexp = "dhcpcd: \\[manager\\].*";
      })
      (lib.mkIf (networkPostStart != null) {
        # The upstream hook lets postStart hide an address-setup failure.
        network_interfaces.hooks.rc_start = lib.mkForce ''
          rc_exec "''${daemon} ''${daemon_flags}" || return $?
          ${networkPostStart}
        '';
      })
    ];
    system.build.openbsdNetworkOptions = networkOptions;
    # NixBSD configures the addresses; apply the missing options afterward.
    init.services.network_interfaces.postStart =
      lib.mkIf (mtuInterfaces != [ ] || hasGateway)
        "${networkOptions}";
  };
}
