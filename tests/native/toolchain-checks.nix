{
  stdenv,
  lib,
  nonce,
  compiler-rt,
  toolchain,
}:
(import ./libraries.nix {
  inherit
    stdenv
    lib
    nonce
    compiler-rt
    ;
}).overrideAttrs
  (old: {
    name = "openbsd-native-toolchain-checks-${nonce}";
    buildPhase = old.buildPhase + ''
      test "$(readlink -f ${stdenv.cc}/resource-root/include)" = \
        "$(readlink -f ${lib.getLib toolchain.clang}/lib/clang/${lib.versions.major toolchain.clang.version}/include)"
      "$CC" --version
      "$LD" --version
      printf 'int main(void) { return 0; }\n' > nopie.c
      # OpenBSD's Clang driver sends -nopie to LLD for -no-pie.
      "$CC" -no-pie nopie.c -o nopie
      "$READELF" -h nopie | grep 'Type:.*EXEC'
      ./nopie
      "$CC" -Wl,-nopie nopie.c -o linker-nopie
      "$READELF" -h linker-nopie | grep 'Type:.*EXEC'
      ./linker-nopie
    '';
    installPhase = old.installPhase + ''
      cp nopie linker-nopie "$out/bin/"
    '';
  })
