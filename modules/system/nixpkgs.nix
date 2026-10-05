{ nixbsd }:
{ lib, ... }:
let
  nixosModules = "${nixbsd.inputs.nixpkgs}/nixos/modules";
  daemon = "${nixbsd}/modules/services/system/nix-daemon.nix";
in
{
  disabledModules = [
    "${nixosModules}/system/boot/loader/efi.nix"
    daemon
  ];
  imports = [
    # Keep the shared EFI options without NixOS's systemd random-seed service.
    (
      { config, lib, ... }@args:
      removeAttrs (import "${nixosModules}/system/boot/loader/efi.nix" args) [ "config" ]
    )
    # The shared Nix module now declares these options itself.
    (
      {
        config,
        lib,
        pkgs,
        ...
      }@args:
      let
        original = import daemon args;
      in
      original
      // {
        options = original.options // {
          nix = removeAttrs original.options.nix [
            "enable"
            "package"
            "nrBuildUsers"
          ];
        };
      }
    )
    (lib.mkAliasOptionModule
      [ "services" "displayManager" "hiddenUsers" ]
      [ "services" "xserver" "displayManager" "hiddenUsers" ]
    )
    # The portal module refers to FUSE even when disabled.
    (lib.mkRemovedOptionModule [
      "programs"
      "fuse"
      "enable"
    ] "FUSE integration is not supported on OpenBSD.")
  ];
  nixpkgs.overlays = lib.mkAfter [ (import ../../overlays/nixbsd.nix) ];
}
