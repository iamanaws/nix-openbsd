{
  stdenv,
  lib,
  nonce,
  compiler-rt,
}:
stdenv.mkDerivation {
  name = "openbsd-native-libraries-${nonce}";
  dontUnpack = true;
  dontConfigure = true;
  strictDeps = true;
  buildPhase = ''
    runHook preBuild
    test "$EUID" -ne 0
    printf '#define _XOPEN_SOURCE 700\n#include <sys/types.h>\n#include <sys/stat.h>\n' \
      | "$CC" -std=c23 -Werror -x c -fsyntax-only -
    for mode in dynamic static; do
      flags=()
      if test "$mode" = static; then flags=(-static -pie); fi
      "$CC" -Wall -Wextra -Werror "''${flags[@]}" ${./libc.c} -o "$mode" -pthread -lm
      ./"$mode"
    done
    LD_TRACE_LOADED_OBJECTS=1 ./dynamic > loaded-libraries
    cat loaded-libraries
    for library in libc libm libpthread; do
      grep -F '${lib.getLib stdenv.cc.libc}/lib/'"$library.so." loaded-libraries
    done
    grep -F '${lib.getLib stdenv.cc.libc}/libexec/ld.so' loaded-libraries
    "$READELF" -h static | grep 'Type:.*DYN'
    if "$READELF" -l static | grep INTERP || "$READELF" -d static | grep NEEDED; then
      echo 'Static PIE unexpectedly depends on a dynamic loader or shared libraries' >&2
      exit 1
    fi
    # Let the wrapper select the builtins archive; check where each helper came from.
    "$CC" -Wall -Wextra -Werror ${./compiler-rt.c} -Wl,-Map,link.map -o builtins
    for helper in divti3 modti3 udivti3 umodti3 fixunsdfti; do
      grep -F '${compiler-rt}/lib/' link.map | grep -F "$helper.c.o"
    done
    ./builtins
    "$CXX" -Wall -Wextra -Werror -femulated-tls ${./tls.cc} -pthread \
      -Wl,-Map,tls.map -o tls
    grep -F '${compiler-rt}/lib/' tls.map | grep -F 'emutls.c.o'
    ./tls
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp dynamic static builtins tls "$out/bin/"
    cp loaded-libraries link.map tls.map "$out/"
    echo "$EUID" > "$out/build-uid"
    runHook postInstall
  '';
}
