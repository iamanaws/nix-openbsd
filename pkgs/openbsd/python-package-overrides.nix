_: previous: {
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
}
