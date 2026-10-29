{
  flakeRef ? "path:" + toString ../..,
  flake ? builtins.getFlake flakeRef,
  pkgs ? flake.legacyPackages.x86_64-openbsd,
  nonce ? "",
  outside ? "",
  ports ? "[]",
}:
let
  native = pkgs.nix.nativePackageSet;
  baseline = native.nixVersions.nix_2_35.overrideScope (
    import ../../pkgs/openbsd/nix-runtime-overrides.nix {
      nixbsdSource = flake.inputs.nixbsd;
    }
  );
  scope = baseline.overrideAllMesonComponents (
    final: old: {
      allowSubstitutes = false;
      preferLocalBuild = true;
      preUnpack = ''
        ${pkgs.python3}/bin/python3 -B ${../sandbox-packages/guard.py} ${
          pkgs.lib.escapeShellArgs [
            final.pname
            nonce
            outside
            ports
            "START"
          ]
        }
      ''
      + (old.preUnpack or "");
      postFixup = (old.postFixup or "") + ''
        ${pkgs.python3}/bin/python3 -B ${../sandbox-packages/guard.py} ${
          pkgs.lib.escapeShellArgs [
            final.pname
            nonce
            outside
            ports
            "END"
          ]
        }
      '';
    }
  );
  components = set: set.libs // { nix = set.nix-cli; };
  packages = components scope;
in
{
  inherit packages;
  baselineOutputs = builtins.mapAttrs (_: package: package.outPath) (components baseline);
  # Retain the existing component inputs. Using the fresh scope here would
  # build internal libraries during preparation, outside the test daemon.
  inputs = builtins.mapAttrs (_: package: package.inputDerivation) (components baseline);
  metadata = builtins.mapAttrs (_: package: {
    inherit (package) drvPath version;
    buildSystem = "Meson";
    outputs = pkgs.lib.genAttrs package.outputs (output: (pkgs.lib.getOutput output package).outPath);
    checks = package.doCheck or false;
    installChecks = package.doInstallCheck or false;
  }) packages;
}
