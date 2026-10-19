{
  mkDerivation,
  byacc,
  flex,
}:
mkDerivation {
  path = "usr.bin/mklocale";
  extraPaths = [
    "lib/libc/locale/runetype.h"
    "lib/libc/include/ctype_private.h"
  ];
  extraNativeBuildInputs = [
    byacc
    flex
  ];
}
