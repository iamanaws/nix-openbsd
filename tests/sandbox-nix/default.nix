{
  flakeRef ? "path:" + toString ../..,
  flake ? builtins.getFlake flakeRef,
}:
let
  pkgs = flake.legacyPackages.x86_64-openbsd;
  inputs = (import ./packages.nix { inherit flake pkgs; }).inputs;
  nativeTests = import ../native {
    nixbsd = flake.inputs.nixbsd;
    scriptPkgs = pkgs;
    cores = 2;
    memorySize = 4096;
  };
in
assert flake.nixosConfigurations.openbsd-native.config.nix.settings.sandbox == false;
assert flake.nixosConfigurations.openbsd-native.config.nix.settings.sandbox-fallback == false;
{
  passed = true;
  all = pkgs.linkFarm "openbsd-sandbox-nix-inputs" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) {
      inherit (pkgs) python3 coreutils;
      inherit (pkgs.openbsd) ifconfig;
      source = flake.outPath;
      native-tests = nativeTests.guestTest;
      pty-script = flake.inputs.nixbsd + "/scripts/smoke-test-nix-openbsd-pty.sh";
      pty-fixtures = pkgs.callPackage (
        flake.inputs.nixbsd + "/configurations/openbsd-nix/pty-fixtures.nix"
      ) { };
      isolation = (import ../isolation { inherit flake; }).all;
      sandbox-packages = (import ../sandbox-packages { inherit flake; }).all;
      build-inputs = pkgs.linkFarm "openbsd-sandbox-nix-build-inputs" (
        pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) inputs
      );
    }
  );
}
