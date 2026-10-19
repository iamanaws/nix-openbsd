{
  pkgs,
  bootstrap,
  python,
}:
{
  packages = import ./consumer.nix {
    inherit pkgs;
    python = python.withPackages (ps: [
      ps.cffi
      ps.setuptools
    ]);
    # Compare paths without making the cross-built seeds test dependencies.
    disallowedRequisites = pkgs.lib.unique (
      builtins.concatMap (
        p:
        map builtins.unsafeDiscardStringContext (
          builtins.filter (v: builtins.isString v && pkgs.lib.hasPrefix "/nix/store/" v) (
            builtins.attrValues p
          )
        )
      ) (builtins.attrValues bootstrap)
    );
  };
  # Keep upstream test adjustments separate from the cached package recipes.
  libevent = pkgs.libevent.overrideAttrs (old: {
    doCheck = true;
    patches = old.patches ++ [
      ./libevent-getaddrinfo.patch
      ./libevent-dns.patch
    ];
    nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ pkgs.python3 ];
    preCheck = ''
      patchShebangs test/check-dumpevents.py
    '';
  });
  cffi-callbacks = python.pkgs.cffi.overridePythonAttrs {
    doCheck = true;
    # Legacy ffi.callback() needs writable executable memory, rejected by OpenBSD.
    enabledTestPaths = [ "testing/cffi1/test_recompiler.py" ];
    enabledTests = [ "extern_python" ];
  };
}
