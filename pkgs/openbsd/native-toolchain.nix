{ pkgs, python3 }:
let
  inherit (pkgs) lib;
  tools = pkgs.stdenv.__bootPackages;
  buildTools = {
    inherit python3;
    python3Minimal = python3;
    cmake = tools.cmakeMinimal;
    ninja = tools.ninja.override {
      python3 = tools.python3Minimal;
      buildDocs = false;
      re2c = tools.re2c.override { python3 = tools.python3Minimal; };
    };
  };
  llvmPackages = (pkgs.llvmPackages.override buildTools).overrideScope (
    final: previous: {
      # TableGen must use this native scope's build tools too.
      buildLlvmPackages = final;
      tblgen = previous.tblgen.overrideAttrs (old: {
        # config.guess requires OpenBSD's arch command, absent from the build environment.
        cmakeFlags = old.cmakeFlags ++ [
          (lib.cmakeFeature "LLVM_HOST_TRIPLE" pkgs.stdenv.hostPlatform.config)
        ];
      });
      libllvm = (previous.libllvm.override { enablePolly = false; }).overrideAttrs (old: {
        patches = old.patches ++ [
          ./llvm-interpreter-roundeven.patch
          ./llvm-openbsd-wait-timeout.patch
        ];
        # Use the tested interpreter with psutil for LLVM's test runner.
        nativeBuildInputs =
          builtins.filter (input: !(lib.hasPrefix "python3" (lib.getName input))) old.nativeBuildInputs
          ++ [ python3 ];
        cmakeFlags = old.cmakeFlags ++ [
          "-DLLVM_TARGETS_TO_BUILD=X86"
          "-DLLVM_PARALLEL_LINK_JOBS=1"
        ];
      });
      libclang = (previous.libclang.override { enableClangToolsExtra = false; }).overrideAttrs (old: {
        cmakeFlags = old.cmakeFlags ++ [ "-DLLVM_PARALLEL_LINK_JOBS=1" ];
      });
      lld = previous.lld.overrideAttrs (old: {
        patches = old.patches ++ [ ./lld-openbsd-nopie.patch ];
        cmakeFlags = old.cmakeFlags ++ [ "-DLLVM_PARALLEL_LINK_JOBS=1" ];
      });
    }
  );
in
{
  inherit (llvmPackages) llvm lld;
  clang = llvmPackages.clang-unwrapped;
  bintools = llvmPackages.bintools-unwrapped;
}
