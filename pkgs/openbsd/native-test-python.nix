{ pkgs }:
let
  python =
    (pkgs.python3Minimal.override {
      self = python;
      # Packaging hooks must use this interpreter too, including its zlib module.
      __splices = {
        pythonOnBuildForBuild = python;
        pythonOnBuildForHost = python;
        pythonOnBuildForTarget = python;
        pythonOnHostForHost = python;
        pythonOnTargetForTarget = python;
      };
      packageOverrides = import ./python-package-overrides.nix;
    }).overrideAttrs
      (old: {
        # Wheels need compression; psutil's tests need ctypes.
        buildInputs = old.buildInputs ++ [
          pkgs.zlib
          pkgs.libffi
        ];
        allowedReferences = old.allowedReferences ++ [
          pkgs.zlib
          pkgs.libffi
        ];
      });
in
python.withPackages (ps: [ ps.psutil ])
