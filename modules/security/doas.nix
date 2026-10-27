{ nixpkgs }:
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Reuse the NixOS options and rules; the native binary uses BSD authentication.
  imports = [ "${nixpkgs}/nixos/modules/security/doas.nix" ];

  security.doas.package = lib.mkDefault pkgs.openbsd.doas;

  init.services = lib.mkIf config.security.doas.enable {
    doas-check = {
      description = "Validate doas permissions";
      dependencies = [ "FILESYSTEMS" ];
      before = [ "LOGIN" ];
      startType = "oneshot";
      startCommand = [
        "${config.security.doas.package}/bin/doas"
        "-C"
        "/etc/doas.conf"
      ];
    };
  };
}
