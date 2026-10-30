{
  flakeRef ? "path:" + toString ../..,
  flake ? builtins.getFlake flakeRef,
}:
let
  base = flake.nixosConfigurations.openbsd-native;
  pkgs = base.pkgs;
  buildUsers = map (nr: "nixbld${toString nr}") (pkgs.lib.range 1 base.config.nix.nrBuildUsers);
  probe =
    pkgs.runCommandCC "openbsd-isolation-exec-probe" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        mkdir -p "$out/bin"
        $CC -UNDEBUG -Wall -Wextra -Werror ${./exec.c} -o "$out/bin/exec-probe"
        python3 -B ${./snapshot-copy.py} --cxx "$CXX" \
          --template ${./snapshot-copy.cc} --patch ${../../pkgs/openbsd/nix-openbsd-sandbox.patch}
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
  && base.config.users.users.${name}.class == "nixbld"
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
      sandboxPatch = ../../pkgs/openbsd/nix-openbsd-sandbox.patch;
      ptyPatch = ../../pkgs/openbsd/nix-openbsd-builder-pty.patch;
      builderSource = pkgs.nix.src + "/src/libstore/unix/build/derivation-builder.cc";
      processSource = pkgs.runCommand "nix-process-source" { nativeBuildInputs = [ pkgs.patch ]; } ''
        mkdir -p unix
        cp ${pkgs.nix.src}/src/libutil/unix/processes.cc unix/processes.cc
        patch -p1 --fuzz=0 < ${../../pkgs/openbsd/nix-openbsd-kill-user.patch}
        cp unix/processes.cc "$out"
      '';
      descriptorSource =
        pkgs.runCommand "nix-descriptor-source" { nativeBuildInputs = [ pkgs.patch ]; }
          ''
            mkdir -p unix
            cp ${pkgs.nix.src}/src/libutil/unix/file-descriptor.cc unix/file-descriptor.cc
            patch -p1 --fuzz=0 < ${../../pkgs/openbsd/nix-openbsd-closefrom.patch}
            cp unix/file-descriptor.cc "$out"
          '';
      inherit (pkgs.openbsd)
        ifconfig
        route
        pwd_mkdb
        cap_mkdb
        ;
    }
  );
}
