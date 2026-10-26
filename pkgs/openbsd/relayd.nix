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
    # LibreSSL 4.3 exposes the same unverified certificate bundle under the old name.
    substituteInPlace "$BSDSRCDIR/usr.sbin/relayd/relay.c" \
      --replace-fail tls_peer_cert_unverified_bundle_pem tls_peer_cert_chain_pem
    sed -i '/#include <stdio.h>/a#include <stdlib.h>' \
      "$BSDSRCDIR/usr.sbin/relayd/parse.y"
  '';

  meta.mainProgram = "relayd";
  meta.platforms = lib.platforms.openbsd;
}
