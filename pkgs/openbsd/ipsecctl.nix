{
  lib,
  mkDerivation,
  byacc,
}:

mkDerivation {
  path = "sbin/ipsecctl";
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/#include <stdio.h>/a#include <stdlib.h>' \
      "$BSDSRCDIR/sbin/ipsecctl/parse.y"
  '';

  meta.mainProgram = "ipsecctl";
  meta.platforms = lib.platforms.openbsd;
}
