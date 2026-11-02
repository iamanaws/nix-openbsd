{ lib, pkgs, ... }:
{
  networking.hostName = "my-openbsd";
  # Use a keyboard and display instead of the reference VM's serial console.
  # boot.loader.stand-openbsd.console = lib.mkForce "pc0";
  # For a new image, choose a DUID and use it for both filesystems.
  # fileSystems."/".device = lib.mkForce "0123456789abcdef.a";
  # fileSystems."/boot/efi".device = lib.mkForce "0123456789abcdef.i";
  environment.systemPackages = [
    pkgs.hello
    pkgs.jq
  ];

  # QEMU's user network supplies DNS at this address.
  services.resolvd = {
    enable = true;
    config = "nameserver 10.0.2.3";
  };

  # This example uses the reference VM's root/bestie logins and disk layout.
  # Set your own account credentials before using it beyond the local VM.
}
