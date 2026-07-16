{
  lib,
  mkDerivation,
  libressl,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/relayctl";
  extraPaths = [ "usr.sbin/relayd" ];

  buildInputs = [
    libressl
    libutil
  ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/relayctl/Makefile"
  '';

  meta.mainProgram = "relayctl";
  meta.platforms = lib.platforms.openbsd;
}
