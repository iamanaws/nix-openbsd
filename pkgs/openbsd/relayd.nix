{
  lib,
  mkDerivation,
  byacc,
  libagentx,
  libevent,
  libressl,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/relayd";
  extraPaths = [ "sys/net" ];

  buildInputs = [
    libagentx
    libevent
    libressl
    libutil
  ];

  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/relayd/Makefile"
    sed -i '/#include <stdio.h>/a#include <stdlib.h>' \
      "$BSDSRCDIR/usr.sbin/relayd/parse.y"
  '';

  meta.mainProgram = "relayd";
  meta.platforms = lib.platforms.openbsd;
}
