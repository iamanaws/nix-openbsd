{
  flakeRef ? "path:" + toString ../..,
  flake ? builtins.getFlake flakeRef,
}:
let
  base = flake.nixosConfigurations.openbsd-native;
  pkgs = base.pkgs;
  packages = (import ./packages.nix { inherit pkgs; }).packages;
  inputs = builtins.mapAttrs (_: package: package.inputDerivation) packages;
in
assert pkgs.stdenv.buildPlatform.isOpenBSD;
assert base.config.nix.settings.sandbox == false;
assert base.config.nix.settings.sandbox-fallback == false;
assert builtins.all pkgs.lib.isDerivation (builtins.attrValues packages);
{
  passed = true;
  # Nixpkgs' inputDerivation retains complete build inputs without building the
  # package itself. Fresh outputs are requested only by the runtime suite.
  all = pkgs.linkFarm "openbsd-sandbox-package-inputs" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) {
      inherit (pkgs) python3 sqlite;
      cc = pkgs.stdenv.cc;
      libcxx = pkgs.lib.getLib pkgs.stdenv.cc.libcxx;
      inherit (pkgs.openbsd) ifconfig;
      source = flake.outPath;
      build-inputs = pkgs.linkFarm "openbsd-sandbox-package-build-inputs" (
        pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) inputs
      );
    }
  );
}
