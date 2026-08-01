{
  lib,
  mkDerivation,
  byacc,
  libevent,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/ospfd";
  buildInputs = [
    libevent
    libutil
  ];
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/ospfd/Makefile"
    sed -i '/#include <stdio.h>/a#include <stdlib.h>' \
      "$BSDSRCDIR/usr.sbin/ospfd/parse.y"
  '';

  meta.mainProgram = "ospfd";
  meta.platforms = lib.platforms.openbsd;
}
