{
  lib,
  mkDerivation,
  byacc,
  libevent,
  libressl,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/httpd";

  buildInputs = [
    libevent
    libressl
    libutil
  ];

  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/httpd/Makefile"
    sed -i '/#include <stdio.h>/a#include <stdlib.h>' \
      "$BSDSRCDIR/usr.sbin/httpd/parse.y"
  '';

  meta.mainProgram = "httpd";
  meta.platforms = lib.platforms.openbsd;
}
