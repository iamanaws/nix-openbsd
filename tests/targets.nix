{
  flakeRef,
  system ? builtins.currentSystem,
  cores ? 8,
  memorySize ? 16384,
}:
let
  flake = builtins.getFlake flakeRef;
  host = flake.inputs.nixbsd.inputs.nixpkgs.legacyPackages.${system};
  pkgs = flake.legacyPackages.x86_64-openbsd;
  firmwarePath = builtins.unsafeDiscardStringContext (
    flake.nixosConfigurations.openbsd-webserver.pkgs.buildPackages.OVMF.fd.outPath
  );
in
{
  nativeTargets = {
    base = flake.packages.x86_64-openbsd.native-system;
    dhcpleased = pkgs.openbsd.dhcpleased;
    dhcp = (import ./dhcp { inherit flake; }).all;
    slaac = (import ./slaac { inherit flake; }).all;
    network = (import ./network { inherit flake; }).all;
    isolation = (import ./isolation { inherit flake; }).all;
    sandbox-nix = (import ./sandbox-nix { inherit flake; }).all;
    sandbox-packages = (import ./sandbox-packages { inherit flake; }).all;
    go-bootstrap = pkgs.go.goBootstrap;
    go-toolchain = pkgs.go;
    shfmt = pkgs.shfmt;
    go = (import ./go { inherit pkgs; }).all;
    packages = pkgs.linkFarm "openbsd-package-test-results" (
      pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) flake.checks.x86_64-openbsd
    );
    generations = (import ./generations/fixtures.nix { inherit flake; }).all;
    dns = (import ./generations/dns-fixtures.nix { inherit flake; }).all;
    logging = (import ./generations/logging-fixtures.nix { inherit flake; }).all;
    doas = (import ./generations/doas-fixtures.nix { inherit flake; }).all;
    mail = (import ./generations/mail-fixtures.nix { inherit flake; }).all;
    maintenance-scripts = pkgs.openbsd.maintenance-scripts;
    maintenance = (import ./generations/maintenance-fixtures.nix { inherit flake; }).all;
    cron-fallback =
      (import ./generations/fixtures.nix {
        inherit flake;
        withCronctl = false;
      }).all;
  };
  qemu = if host.stdenv.hostPlatform.isx86_64 then host.qemu_kvm else host.qemu;
  native =
    (import ./native {
      nixbsd = flake.inputs.nixbsd;
      inherit cores memorySize;
    }).test;
  # Boot a private copy of a prepared disk without assembling another image.
  preparedLauncher = import ../vm/launcher.nix {
    pkgs = host;
    firmware = builtins.appendContext firmwarePath { "${firmwarePath}".path = true; };
  };
}
