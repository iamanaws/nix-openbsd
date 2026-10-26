{
  pkgs,
  python3,
  llvmPackages ? pkgs.llvmPackages,
  tools ? pkgs.stdenv.__bootPackages,
}:
let
  inherit (pkgs) lib;
  buildTools =
    (import ./bootstrap-build-tools.nix {
      pkgs = tools;
      inherit python3;
    })
    // {
      python3Minimal = python3;
    };
  isLLVM22 = lib.versionAtLeast llvmPackages.libllvm.version "22";
  llvm22Patches = [
    ./llvm-openbsd-cas-sync.patch
    ./llvm-lit-resource-limits.patch
  ];
  packages = (llvmPackages.override buildTools).overrideScope (
    final: previous:
    {
      # TableGen must use this native scope's build tools too.
      buildLlvmPackages = final;
      tblgen = previous.tblgen.overrideAttrs (old: {
        # TableGen does not use CAS or lit; keep its build independent of these fixes.
        patches = builtins.filter (
          patch: !(builtins.elem (toString patch) (map toString llvm22Patches))
        ) old.patches;
        # config.guess requires OpenBSD's arch command, absent from the build environment.
        cmakeFlags = old.cmakeFlags ++ [
          (lib.cmakeFeature "LLVM_HOST_TRIPLE" pkgs.stdenv.hostPlatform.config)
        ];
      });
      libllvm = (previous.libllvm.override { enablePolly = false; }).overrideAttrs (old: {
        patches =
          old.patches
          ++ [
            ./llvm-interpreter-roundeven.patch
            (if isLLVM22 then ./llvm-openbsd-wait-timeout-22.patch else ./llvm-openbsd-wait-timeout.patch)
          ]
          ++ lib.optionals isLLVM22 llvm22Patches;
        # Use the tested interpreter with psutil for LLVM's test runner.
        nativeBuildInputs =
          builtins.filter (input: !(lib.hasPrefix "python3" (lib.getName input))) old.nativeBuildInputs
          ++ [ python3 ];
        cmakeFlags = old.cmakeFlags ++ [
          "-DLLVM_TARGETS_TO_BUILD=X86"
          "-DLLVM_PARALLEL_LINK_JOBS=1"
        ];
        postPatch =
          (old.postPatch or "")
          + lib.optionalString isLLVM22 ''
            # Allow worker startup in an I/O-limited VM; the slow input sleeps 60 seconds.
            substituteInPlace utils/lit/tests/max-time.py \
              --replace-fail '--max-time=5' '--max-time=30'
          '';
      });
      libclang = (previous.libclang.override { enableClangToolsExtra = false; }).overrideAttrs (old: {
        patches = old.patches ++ [
          ./clang-openbsd-static-pie.patch
          ./clang-openbsd-no-pie.patch
          ./clang-openbsd-lld-emulation.patch
        ];
        cmakeFlags = old.cmakeFlags ++ [
          "-DLLVM_PARALLEL_LINK_JOBS=1"
          "-DCLANG_DEFAULT_LINKER=lld"
        ];
      });
      lld = previous.lld.overrideAttrs (old: {
        patches = old.patches ++ [ ./lld-openbsd-library-search.patch ];
        cmakeFlags = old.cmakeFlags ++ [ "-DLLVM_PARALLEL_LINK_JOBS=1" ];
      });
    }
    // lib.optionalAttrs isLLVM22 {
      compiler-rt-no-libc = previous.compiler-rt-no-libc.overrideAttrs (old: {
        # The pinned recipe removes OpenBSD's assert/static_assert macros.
        env = old.env // {
          NIX_CFLAGS_COMPILE = old.env.NIX_CFLAGS_COMPILE + " -idirafter ${pkgs.openbsd.include}/include";
        };
        postPatch = (old.postPatch or "") + ''
          sed -i '1i#include <assert.h>' lib/builtins/cpu_model/x86.c lib/builtins/clear_cache.c
        '';
      });
    }
  );
in
{
  inherit packages;
  inherit (packages) llvm lld;
  clang = packages.clang-unwrapped;
  bintools = packages.bintools-unwrapped;
}
