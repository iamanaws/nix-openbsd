{
  lib,
  mkDerivation,
  byacc,
  libevent,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/rad";
  buildInputs = [
    libevent
    libutil
  ];
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/rad/Makefile"
    sed -i '/#include <stdio.h>/a#include <stdlib.h>' \
      "$BSDSRCDIR/usr.sbin/rad/parse.y"
  '';

  meta.mainProgram = "rad";
  meta.platforms = lib.platforms.openbsd;
}
