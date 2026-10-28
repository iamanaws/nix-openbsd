{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.networking.dhcpleased;
  network = config.networking;
  interfaces = builtins.attrValues network.interfaces;
  enabled = cfg.enable && (network.useDHCP || lib.any (i: i.useDHCP == true) interfaces);
  excluded = builtins.filter (
    i: i.useDHCP == false || (i.useDHCP == null && i.ipv4.addresses != [ ])
  ) interfaces;
  included = builtins.filter (i: i.useDHCP == true) interfaces;
  ifconfig = "${pkgs.openbsd.ifconfig}/bin/ifconfig";
  route = "${pkgs.openbsd.route}/bin/route";
  grep = "${pkgs.gnugrep}/bin/grep";
  daemon = "${cfg.package}/bin/dhcpleased";
  configure = ''
    dhcp_interfaces=
    interface_status=$(${ifconfig} -a) || exit $?
    interface_names=$(printf '%s\n' "$interface_status" |
      ${pkgs.gnused}/bin/sed -nE 's/^([^[:space:]:]+): flags=.*/\1/p')
    for interface in $interface_names; do
      case "$interface" in
        lo[0-9]*) continue ;;
        ${lib.optionalString (excluded != [ ]) ''
          ${lib.concatMapStringsSep "|" (i: lib.escapeShellArg i.name) excluded})
            ${ifconfig} "$interface" inet -autoconf
            continue ;;
        ''}
        ${lib.optionalString (included != [ ]) ''
          ${lib.concatMapStringsSep "|" (i: lib.escapeShellArg i.name) included}) ;;
        ''}
        *)
          ${
            if network.useDHCP then
              ''
                # Discover Ethernet interfaces, including wireless and VLAN devices.
                ${ifconfig} "$interface" | ${grep} -q '^[[:space:]]*lladdr ' || continue
              ''
            else
              "continue"
          }
          ;;
      esac
      ${ifconfig} "$interface" inet autoconf up
      dhcp_interfaces="$dhcp_interfaces $interface"
    done
    # Match netstart's bounded wait for an autoconfigured default route.
    if [ -n "$dhcp_interfaces" ]; then
      attempt=0
      while [ "$attempt" -lt 20 ]; do
        ${route} -n show -inet | ${grep} -q '^default[[:space:]]' && break
        ${pkgs.coreutils}/bin/sleep .5
        attempt=$((attempt + 1))
      done
    fi
  '';
in
{
  imports = [
    ../system/tempfiles.nix
    ./resolvd.nix
  ];

  options.networking.dhcpleased = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = !network.dhcpcd.enable;
      defaultText = lib.literalExpression "!config.networking.dhcpcd.enable";
      description = ''
        Use OpenBSD dhcpleased for interfaces selected by networking.useDHCP
        and networking.interfaces.<name>.useDHCP.
      '';
    };
    package = lib.mkPackageOption pkgs [ "openbsd" "dhcpleased" ] { };
    controlPackage = lib.mkPackageOption pkgs [ "openbsd" "dhcpleasectl" ] { };
    config = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Verbatim contents of dhcpleased.conf(5). Most systems need no configuration.";
    };
    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional command-line flags passed to dhcpleased.";
    };
  };

  config = lib.mkIf pkgs.stdenv.hostPlatform.isOpenBSD (
    lib.mkMerge [
      { networking.dhcpcd.enable = lib.mkDefault false; }
      (lib.mkIf enabled {
        assertions = [
          {
            assertion = !network.dhcpcd.enable;
            message = "Enable only one DHCP client: networking.dhcpleased or networking.dhcpcd.";
          }
        ];
        services.resolvd.enable = lib.mkDefault true;
        environment.etc."dhcpleased.conf".text = cfg.config;
        environment.systemPackages = [
          cfg.package
          cfg.controlPackage
        ];
        users.users._dhcp = {
          uid = 77;
          isSystemUser = true;
          group = "_dhcp";
          home = "/var/empty";
          description = "OpenBSD DHCP programs";
        };
        users.groups._dhcp.gid = 77;
        services.tempfiles.directories = {
          "/var/empty".mode = "0555";
          "/var/db/dhcpleased" = { };
        };
        openbsd.rc.services.dhcpleased = {
          shellVariables.rc_reload = false;
          hooks.rc_configtest = ''
            rc_exec "''${daemon} -n ''${daemon_flags}"
          '';
        };
        init.services.dhcpleased = {
          description = "OpenBSD DHCP client";
          dependencies = [ "FILESYSTEMS" ] ++ lib.optional config.services.resolvd.enable "resolvd";
          before = [
            "network_interfaces"
            "NETWORKING"
          ];
          startType = "forking";
          startCommand = [
            daemon
            "-f"
            "/etc/dhcpleased.conf"
          ]
          ++ cfg.extraFlags;
        };
        init.services.network_interfaces.postStart = lib.mkAfter configure;
      })
    ]
  );
}
