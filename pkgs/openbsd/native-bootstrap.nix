# Cross-built seed metadata shared by native builds and the test VM.
{ pkgs }:
let
  libc = pkgs.openbsd.libc.override {
    librthread = pkgs.openbsd.librthread.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./librthread-private-semaphores.patch ];
    });
    libcMinimal = pkgs.openbsd.libcMinimal.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./libc-difftime.patch ];
      postInstall = (old.postInstall or "") + ''
        # Nixpkgs rewrites this private guard to "true", which becomes active in C23.
        substituteInPlace "$dev/include/sys/time.h" \
          --replace-fail 'defined(_STANDALONE) || true' \
            'defined(_STANDALONE) || defined (_LIBC)'
      '';
    });
  };
  # Preserve output selection and compiler metadata when passing seed packages to the guest.
  package =
    p:
    {
      inherit (p) name;
      pname = pkgs.lib.getName p;
      path = p.outPath;
      version = p.version or "";
      meta = pkgs.lib.optionalAttrs (p.meta ? mainProgram) { inherit (p.meta) mainProgram; };
    }
    // pkgs.lib.genAttrs (builtins.filter (
      output:
      builtins.elem output [
        "out"
        "bin"
        "dev"
        "lib"
      ]
    ) (p.outputs or [ "out" ])) (output: p.${output}.outPath)
    // pkgs.lib.filterAttrs (
      name: _:
      builtins.elem name [
        "isClang"
        "isLLVM"
        "isGNU"
        "langC"
        "langCC"
        "shellPath"
      ]
    ) p;
in
pkgs.lib.mapAttrs (_: package) {
  inherit (pkgs)
    bashNonInteractive
    coreutils
    diffutils
    findutils
    gnugrep
    gnused
    gawk
    gnumake
    gnutar
    gzip
    bzip2
    xz
    patch
    patchelf
    file
    curl
    expand-response-params
    ;
  inherit (pkgs.llvmPackages) libcxx compiler-rt libunwind;
  clang = pkgs.llvmPackages.clang-unwrapped;
  bintools = pkgs.llvmPackages.bintools-unwrapped;
  inherit libc;
}
