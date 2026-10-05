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
      # Both driver spellings must work with upstream LLD's -no-pie option.
      "$CC" -no-pie nopie.c -o nopie
      "$READELF" -h nopie | grep 'Type:.*EXEC'
      ./nopie
      "$CC" -nopie nopie.c -o driver-nopie
      "$READELF" -h driver-nopie | grep 'Type:.*EXEC'
      ./driver-nopie
      "$CC" -Wl,-no-pie nopie.c -o linker-nopie
      "$READELF" -h linker-nopie | grep 'Type:.*EXEC'
      ./linker-nopie
      "$CXX" -std=c++17 -pthread ${./llvm-wait.cc} \
        -I${lib.getDev toolchain.llvm}/include \
        -L${lib.getLib toolchain.llvm}/lib -Wl,-rpath,${lib.getLib toolchain.llvm}/lib \
        -lLLVM -o llvm-wait
      timeout 30 ./llvm-wait
    '';
    installPhase = old.installPhase + ''
      cp nopie driver-nopie linker-nopie llvm-wait "$out/bin/"
    '';
  })
