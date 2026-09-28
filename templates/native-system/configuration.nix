{ pkgs, ... }:
{
  networking.hostName = "my-openbsd";
  environment.systemPackages = [
    pkgs.hello
    pkgs.jq
  ];

  # QEMU's user network supplies DNS at this address.
  services.resolvd = {
    enable = true;
    config = "nameserver 10.0.2.3";
  };

  # This example keeps the existing VM's root/bestie logins and disk layout.
  # Set your own account credentials before using it beyond the local VM.
}
