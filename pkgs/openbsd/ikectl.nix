{
  lib,
  mkDerivation,
  gnutar,
  libressl,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/ikectl";
  extraPaths = [ "sbin/iked" ];
  buildInputs = [
    gnutar
    libressl
    libutil
  ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/ikectl/Makefile"
    substituteInPlace "$BSDSRCDIR/usr.sbin/ikectl/ikeca.c" \
      --replace-fail '"/usr/bin/openssl"' '"${libressl}/bin/openssl"' \
      --replace-fail '"/bin/tar"' '"${gnutar}/bin/tar"'
  '';

  meta.mainProgram = "ikectl";
  meta.platforms = lib.platforms.openbsd;
}
