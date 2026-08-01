{
  lib,
  mkDerivation,
  byacc,
  libevent,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/ripd";
  buildInputs = [
    libevent
    libutil
  ];
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/ripd/Makefile"
    sed -i '/#include <stdio.h>/a#include <stdlib.h>' \
      "$BSDSRCDIR/usr.sbin/ripd/parse.y"
  '';

  meta.mainProgram = "ripd";
  meta.platforms = lib.platforms.openbsd;
}
