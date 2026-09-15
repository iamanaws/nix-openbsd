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
    # Static linking checks the builtins archive, not libc++abi's exported copy.
    "$CXX" -static -pie -Wall -Wextra -Werror -femulated-tls ${./tls.cc} -pthread \
      -Wl,-Map,tls.map -o tls
    grep -F '${compiler-rt}/lib/' tls.map | grep -F 'emutls.c.o'
    ./tls
    mkdir -p "$out/lib"
    "$CXX" -DSHARED_THROW -fPIC -c ${./cxx.cc} -o throws.o
    "$CXX" -shared throws.o -o "$out/lib/libthrows.so"
    "$AR" rcs libthrows.a throws.o
    "$CXX" ${./cxx.cc} -pthread -L"$out/lib" -Wl,-rpath,"$out/lib" -lthrows -o cxx-dynamic
    ./cxx-dynamic
    "$CXX" -static -pie ${./cxx.cc} libthrows.a -pthread -o cxx-static
    ./cxx-static
    LD_TRACE_LOADED_OBJECTS=1 ./cxx-dynamic > cxx-loaded-libraries
    cat cxx-loaded-libraries
    grep -F '${stdenv.cc.libunwind}/lib/libunwind.so' cxx-loaded-libraries
    for library in libc++ libc++abi; do
      grep -F '${stdenv.cc.libcxx}/lib/'"$library.so" cxx-loaded-libraries
    done
    if "$READELF" -d ${stdenv.cc.libunwind}/lib/libunwind.so | grep 'NEEDED.*libunwind'; then
      echo 'libunwind must not depend on itself' >&2
      exit 1
    fi
    if "$READELF" -l cxx-static | grep INTERP || "$READELF" -d cxx-static | grep NEEDED; then
      exit 1
    fi
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp dynamic static builtins tls cxx-dynamic cxx-static "$out/bin/"
    cp loaded-libraries cxx-loaded-libraries link.map tls.map "$out/"
    echo "$EUID" > "$out/build-uid"
    runHook postInstall
  '';
}
