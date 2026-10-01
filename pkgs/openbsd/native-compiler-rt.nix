{
  pkgs,
  libc ? null,
}:
# First build without libc, then include the libc-dependent builtins for C++ TLS.
pkgs.llvmPackages.compiler-rt-no-libc.override (
  (import ./bootstrap-build-tools.nix { inherit pkgs; })
  // {
    stdenv =
      if libc == null then
        pkgs.mkStdenvNoLibs pkgs.stdenv
      else
        pkgs.overrideCC pkgs.stdenv (
          pkgs.stdenv.cc.override {
            inherit libc;
            bintools = pkgs.stdenv.cc.bintools.override { inherit libc; };
          }
        );
    libcxx = pkgs.stdenv.cc.libcxx;
    withAtomics = false;
    devExtraCmakeFlags = pkgs.lib.optionals (libc != null) (
      map (name: pkgs.lib.cmakeBool "COMPILER_RT_BUILD_${name}" false) [
        "SANITIZERS"
        "PROFILE"
        "CTX_PROFILE"
        "XRAY"
        "LIBFUZZER"
        "MEMPROF"
        "ORC"
      ]
    );
  }
)
