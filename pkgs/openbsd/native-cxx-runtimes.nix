{
  pkgs,
  stdenv,
  compiler-rt,
}:
let
  buildTools = {
    # config.guess relies on OpenBSD's arch command, which is not in the seed.
    devExtraCmakeFlags = [ "-DLLVM_DEFAULT_TARGET_TRIPLE=${stdenv.hostPlatform.config}" ];
    python3 = pkgs.python3Minimal;
    cmake = pkgs.cmakeMinimal;
    ninja = pkgs.ninja.override {
      python3 = pkgs.python3Minimal;
      buildDocs = false;
      re2c = pkgs.re2c.override { python3 = pkgs.python3Minimal; };
    };
  };
  # Do not link a runtime against its seed copy while rebuilding it.
  withoutCxx =
    unwind:
    pkgs.overrideCC stdenv (
      stdenv.cc.override (old: {
        libcxx = null;
        extraPackages = [ compiler-rt ] ++ pkgs.lib.optional (unwind != null) unwind;
        nixSupport = old.nixSupport // {
          cc-cflags = [
            "-nostdlib++"
          ]
          ++ map (
            flag: if flag == "--unwindlib=libunwind" && unwind == null then "--unwindlib=none" else flag
          ) (builtins.filter (flag: flag != "-lunwind" || unwind != null) old.nixSupport.cc-cflags);
          cc-ldflags = pkgs.lib.optional (unwind != null) "-L${unwind}/lib";
        };
      })
    );
  libunwind =
    (pkgs.llvmPackages.libunwind.override (
      buildTools
      // {
        stdenv = withoutCxx null;
        # The test installation must redirect headers along with the library.
        devExtraCmakeFlags = buildTools.devExtraCmakeFlags ++ [
          "-DLIBUNWIND_INSTALL_INCLUDE_DIR=include"
        ];
      }
    )).overrideAttrs
      {
        doCheck = true;
        checkTarget = "check-unwind";
        preConfigure = ''
          cmakeFlagsArray+=("-DLLVM_LIT_ARGS=-sv -j$NIX_BUILD_CORES")
        '';
      };
  libcxx =
    (pkgs.llvmPackages.libcxx.override (
      buildTools
      // {
        inherit libunwind;
        stdenv = withoutCxx libunwind;
      }
    )).overrideAttrs
      (old: {
        # OpenBSD's futex operation numbers differ from Linux's.
        patches = (old.patches or [ ]) ++ [
          ./libcxxabi-openbsd-futex.patch
          ./libcxx-openbsd-mbstate.patch
          ./libcxx-openbsd-locale-headers.patch
        ];
      });
in
{
  inherit libunwind libcxx;
}
