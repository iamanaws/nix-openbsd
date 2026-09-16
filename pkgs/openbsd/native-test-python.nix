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
      packageOverrides = _: previous: {
        # Run psutil's tests without optional pytest UI/worker plugins.
        psutil =
          (previous.psutil.override {
            pytest-instafail = null;
            pytest-xdist = null;
          }).overrideAttrs
            (old: {
              patches = (old.patches or [ ]) ++ [ ./psutil-openbsd-no-swap.patch ];
              postPatch = old.postPatch + ''
                substituteInPlace pyproject.toml \
                  --replace-fail '    "--instafail",' "" \
                  --replace-fail '    "-p instafail",' "" \
                  --replace-fail '    "-p xdist",' ""
              '';
            });
      };
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
