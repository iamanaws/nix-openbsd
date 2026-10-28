{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.networking.slaacd;
  network = config.networking;
  interfaces = builtins.attrValues network.interfaces;
  enabled =
    cfg.enable
    && network.enableIPv6
    && (network.useSLAAC || lib.any (i: i.useSLAAC == true) interfaces);
  excluded = builtins.filter (
    i: i.useSLAAC == false || (i.useSLAAC == null && i.ipv6.addresses != [ ])
  ) interfaces;
  included = builtins.filter (i: i.useSLAAC == true) interfaces;
  ifconfig = "${pkgs.openbsd.ifconfig}/bin/ifconfig";
  grep = "${pkgs.gnugrep}/bin/grep";
  configure = ''
    slaac_interfaces=
    interface_status=$(${ifconfig} -a) || exit $?
    interface_names=$(printf '%s\n' "$interface_status" |
      ${pkgs.gnused}/bin/sed -nE 's/^([^[:space:]:]+): flags=.*/\1/p')
    for interface in $interface_names; do
      case "$interface" in
        lo[0-9]*) continue ;;
        ${lib.optionalString (excluded != [ ]) ''
          ${lib.concatMapStringsSep "|" (i: lib.escapeShellArg i.name) excluded})
            # -autoconf alone leaves OpenBSD's temporary-address flag enabled.
            ${ifconfig} "$interface" inet6 -autoconf -temporary
            continue ;;
        ''}
        ${lib.optionalString (included != [ ]) ''
          ${lib.concatMapStringsSep "|" (i: lib.escapeShellArg i.name) included}) ;;
        ''}
        *)
          ${
            if network.useSLAAC then
              ''
                ${ifconfig} "$interface" | ${grep} -q '^[[:space:]]*lladdr ' || continue
              ''
            else
              "continue"
          }
          ;;
      esac
      ${ifconfig} "$interface" inet6 autoconf ${
        lib.optionalString (network.tempAddresses == "disabled") "-temporary"
      } up
      slaac_interfaces="$slaac_interfaces $interface"
    done
    # Match netstart's bounded wait for an autoconfigured default route.
    if [ -n "$slaac_interfaces" ]; then
      attempt=0
      while [ "$attempt" -lt 20 ]; do
        ${pkgs.openbsd.route}/bin/route -n show -inet6 | ${grep} -q '^default[[:space:]]' && break
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

  options.networking = {
    useSLAAC = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Use OpenBSD SLAAC on Ethernet interfaces without static IPv6 addresses.
        Individual interfaces can override this with useSLAAC. Requires
        networking.enableIPv6 and networking.slaacd.enable.
      '';
    };
    interfaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.useSLAAC = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = ''
              Whether to configure this interface with IPv6 SLAAC. Overrides
              networking.useSLAAC. With null, use the global setting unless
              this interface has static IPv6 addresses.
            '';
          };
        }
      );
    };
    slaacd = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = !network.dhcpcd.enable;
        defaultText = lib.literalExpression "!config.networking.dhcpcd.enable";
        description = "Use OpenBSD slaacd for interfaces selected by useSLAAC.";
      };
      package = lib.mkPackageOption pkgs [ "openbsd" "slaacd" ] { };
      controlPackage = lib.mkPackageOption pkgs [ "openbsd" "slaacctl" ] { };
      extraFlags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional command-line flags passed to slaacd.";
      };
    };
  };

  config = lib.mkIf (pkgs.stdenv.hostPlatform.isOpenBSD && enabled) {
    assertions = [
      {
        assertion = !network.dhcpcd.enable;
        message = "Enable only one SLAAC client: networking.slaacd or networking.dhcpcd.";
      }
    ];
    services.resolvd.enable = lib.mkDefault true;
    environment.systemPackages = [
      cfg.package
      cfg.controlPackage
    ];
    users.users._slaacd = {
      uid = 115;
      isSystemUser = true;
      group = "_slaacd";
      home = "/var/empty";
      description = "OpenBSD SLAAC daemon";
    };
    users.groups._slaacd.gid = 115;
    services.tempfiles.directories."/var/empty".mode = "0555";
    openbsd.rc.services.slaacd.shellVariables.rc_reload = false;
    init.services.slaacd = {
      description = "OpenBSD IPv6 SLAAC client";
      dependencies = [ "FILESYSTEMS" ] ++ lib.optional config.services.resolvd.enable "resolvd";
      before = [
        "network_interfaces"
        "NETWORKING"
      ];
      startType = "forking";
      startCommand = [ "${cfg.package}/bin/slaacd" ] ++ cfg.extraFlags;
    };
    init.services.network_interfaces.postStart = lib.mkAfter configure;
  };
}
