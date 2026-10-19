_: previous: {
  # Skip pip's documentation dependencies in the native runtime.
  pip =
    (previous.pip.override {
      sphinx = {
        disabled = true;
      };
    }).overridePythonAttrs
      (old: {
        # The recipe still installs man pages when Sphinx documentation is disabled.
        postInstall = builtins.replaceStrings [ "installManPage docs/build/man/*" ] [ "" ] old.postInstall;
      });
  sqlite-utils = (previous.sqlite-utils.override { hypothesis = null; }).overridePythonAttrs (old: {
    # Wait for the batch commit instead of assuming the child starts within one second.
    patches = (old.patches or [ ]) ++ [ ./sqlite-utils-batch-test.patch ];
    # Hypothesis now requires Rust, whose native OpenBSD bootstrap is unavailable.
    disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
      "tests/test_hypothesis.py"
      "tests/test_create_table_parser.py"
    ];
  });
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
