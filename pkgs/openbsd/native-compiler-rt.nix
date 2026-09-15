{
  pkgs,
  libc ? null,
}:
# First build without libc, then include the libc-dependent builtins for C++ TLS.
pkgs.llvmPackages.compiler-rt-no-libc.override {
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
  python3 = pkgs.python3Minimal;
  libcxx = pkgs.stdenv.cc.libcxx;
  cmake = pkgs.cmakeMinimal;
  ninja = pkgs.ninja.override {
    python3 = pkgs.python3Minimal;
    buildDocs = false;
    re2c = pkgs.re2c.override { python3 = pkgs.python3Minimal; };
  };
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
