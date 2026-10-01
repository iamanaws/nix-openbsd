# Keep Ninja and re2c on the stage's minimal Python even when LLVM needs test modules.
{
  pkgs,
  python3 ? pkgs.python3Minimal,
}:
{
  inherit python3;
  cmake = pkgs.cmakeMinimal;
  ninja = pkgs.ninja.override {
    python3 = pkgs.python3Minimal;
    buildDocs = false;
    re2c = pkgs.re2c.override { python3 = pkgs.python3Minimal; };
  };
}
