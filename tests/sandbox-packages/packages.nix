{
  flakeRef ? "path:" + toString ../..,
  pkgs ? (builtins.getFlake flakeRef).legacyPackages.x86_64-openbsd,
  nonce ? "",
  outside ? "",
  ports ? "[]",
}:
let
  recipes = {
    hello = {
      package = pkgs.hello;
      buildSystem = "Make";
    };
    fmt = {
      package = pkgs.fmt;
      buildSystem = "CMake";
    };
    inih = {
      package = pkgs.inih;
      buildSystem = "Meson";
    };
    markupsafe = {
      package = pkgs.python3Packages.markupsafe;
      buildSystem = "Python C extension";
    };
    shfmt = {
      package = pkgs.shfmt;
      buildSystem = "Go";
    };
    dbmate = {
      package = pkgs.dbmate;
      buildSystem = "Go/SQLite cgo";
    };
  };
  hook = name: event: ''
    ${pkgs.python3}/bin/python3 -B ${./guard.py} ${
      pkgs.lib.escapeShellArgs [
        name
        nonce
        outside
        ports
        event
      ]
    }
  '';
  packages = builtins.mapAttrs (
    name: recipe:
    recipe.package.overrideAttrs (old: {
      # Preserve the recipe's phases and checks. The hook's nonce forces a fresh
      # package output without invalidating source or Go module downloads.
      allowSubstitutes = false;
      preferLocalBuild = true;
      preUnpack = hook name "START" + (old.preUnpack or "");
      postFixup = (old.postFixup or "") + hook name "END";
    })
  ) recipes;
in
{
  inherit packages;
  metadata = builtins.mapAttrs (name: package: {
    inherit (package) drvPath version;
    inherit (recipes.${name}) buildSystem;
    outputs = pkgs.lib.genAttrs package.outputs (output: (pkgs.lib.getOutput output package).outPath);
    checks = package.doCheck or false;
    installChecks = package.doInstallCheck or false;
  }) packages;
}
