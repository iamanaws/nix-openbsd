{
  lib,
  mkDerivation,
  byacc,
  libevent,
  libressl,
  libutil,
}:

mkDerivation {
  path = "sbin/unwind";
  buildInputs = [
    libevent
    libressl
    libutil
  ];
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/sbin/unwind/Makefile"
    sed -i '/#include <stdio.h>/a#include <stdlib.h>\n#include <string.h>' \
      "$BSDSRCDIR/sbin/unwind/parse.y"
  '';

  preBuild = ''
    yacc -o parse.c parse.y
  '';

  meta.mainProgram = "unwind";
  meta.platforms = lib.platforms.openbsd;
}
