{
  flakeRef ? "path:" + toString ../..,
  flake ? builtins.getFlake flakeRef,
}:
let
  base = flake.nixosConfigurations.openbsd-native;
  pkgs = base.pkgs;
  probe = pkgs.runCommandCC "openbsd-isolation-exec-probe" { } ''
    mkdir -p "$out/bin"
    $CC -UNDEBUG -Wall -Wextra -Werror ${./exec.c} -o "$out/bin/exec-probe"
  '';
in
assert pkgs.stdenv.buildPlatform.isOpenBSD;
assert base.config.nix.settings.sandbox == false;
assert base.config.nix.settings.sandbox-fallback == false;
{
  passed = true;
  all = pkgs.linkFarm "openbsd-isolation-tests" (
    pkgs.lib.mapAttrsToList (name: path: { inherit name path; }) {
      inherit probe;
      tests = ./.;
      inherit (pkgs)
        bash
        coreutils
        python3
        curl
        go
        ;
      cc = pkgs.stdenv.cc;
      libcxx = pkgs.lib.getLib pkgs.stdenv.cc.libcxx;
      inherit (pkgs.openbsd) ifconfig route;
      input = pkgs.writeText "isolation-read-only-input" "declared input\n";
    }
  );
}
