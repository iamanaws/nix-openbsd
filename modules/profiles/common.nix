{ lib, pkgs, ... }:
{
  imports = [
    ../security/acme-client.nix
    ../services/bgpd.nix
    ../services/cron.nix
    ../services/dhcpd.nix
    ../services/httpd.nix
    ../services/iked.nix
    ../services/ipsec.nix
    ../services/isakmpd.nix
    ../services/newsyslog.nix
    ../services/ntpd.nix
    ../services/ospfd.nix
    ../services/pf.nix
    ../services/pflogd.nix
    ../services/rad.nix
    ../services/relayd.nix
    ../services/resolvd.nix
    ../services/ripd.nix
    ../services/sensorsd.nix
    ../services/snmpd.nix
    ../services/syslogd.nix
    ../services/unwind.nix
  ];

  nixpkgs.overlays = [ (import ../../overlays/openbsd.nix) ];
  # Use the maintained caches; the inherited NixBSD cache no longer resolves.
  nixbsd.enableExtraSubstituters = false;
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = lib.mkBefore [ "https://nix-openbsd.cachix.org" ];
    trusted-public-keys = [
      "nix-openbsd.cachix.org-1:IbN25q8l3NyIq8L16AWaJ1MNTxZRiYdzO5eYFQv1J+4="
    ];
    fallback = true;
  };
  environment.systemPackages = [ pkgs.openbsd.netstat ];
  fonts.fontconfig.enable = false;
  systemd.tmpfiles.rules = [
    "d /var/authpf 0700 root wheel - -"
    "d /var/db 0755 root wheel - -"
    "f /var/db/host.random 0600 root wheel - -"
  ];
}
