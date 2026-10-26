{
  pkgs,
  libc ? null,
}:
# First build without libc, then include the libc-dependent builtins for C++ TLS.
(pkgs.llvmPackages.compiler-rt-no-libc.override (
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
)).overrideAttrs
  (
    old:
    pkgs.lib.optionalAttrs (libc == null) {
      # Keep OpenBSD's assert/static_assert macros when bootstrapping without libc.
      env = old.env // {
        NIX_CFLAGS_COMPILE = old.env.NIX_CFLAGS_COMPILE + " -idirafter ${pkgs.openbsd.include}/include";
      };
      # The pinned Nixpkgs recipe removes these includes on OpenBSD too.
      postPatch = (old.postPatch or "") + ''
        sed -i '1i#include <assert.h>' lib/builtins/cpu_model/x86.c lib/builtins/clear_cache.c
      '';
    }
  )
