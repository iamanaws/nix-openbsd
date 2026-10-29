{
  flakeRef ? "path:" + toString ../..,
  flake ? builtins.getFlake flakeRef,
}:
let
  base = flake.nixosConfigurations.openbsd-native;
  pkgs = base.pkgs;
  buildUsers = map (nr: "nixbld${toString nr}") (pkgs.lib.range 1 base.config.nix.nrBuildUsers);
  probe = pkgs.runCommandCC "openbsd-isolation-exec-probe" { } ''
    mkdir -p "$out/bin"
    $CC -UNDEBUG -Wall -Wextra -Werror ${./exec.c} -o "$out/bin/exec-probe"
  '';
  inputs = {
    inherit probe;
    tests = ./.;
    inherit (pkgs)
      bash
      coreutils
      python3
      curl
      ;
    input = pkgs.writeText "isolation-read-only-input" "declared input\n";
  };
  fixtures =
    name: paths:
    pkgs.linkFarm name (pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) paths);
in
assert pkgs.stdenv.buildPlatform.isOpenBSD;
assert base.config.nix.settings.sandbox == false;
assert base.config.nix.settings.sandbox-fallback == false;
assert builtins.all (
  name:
  base.config.users.users.${name}.group == name
  && builtins.elem "nixbld" base.config.users.users.${name}.extraGroups
  && builtins.hasAttr name base.config.users.groups
) buildUsers;
{
  passed = true;
  all = fixtures "openbsd-isolation-tests" (
    inputs
    // {
      builder = fixtures "openbsd-isolation-builder-inputs" inputs;
      inherit (pkgs) go;
      cc = pkgs.stdenv.cc;
      libcxx = pkgs.lib.getLib pkgs.stdenv.cc.libcxx;
      inherit (pkgs.openbsd) ifconfig route pwd_mkdb;
    }
  );
}
