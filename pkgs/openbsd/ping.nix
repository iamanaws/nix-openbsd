{
  lib,
  mkDerivation,
  libm,
}:

mkDerivation {
  path = "sbin/ping";
  buildInputs = [ libm ];

  postPatch = ''
    sed -i '/DPADD/d; /BINMODE/d' "$BSDSRCDIR/sbin/ping/Makefile"
  '';

  meta.mainProgram = "ping";
  meta.platforms = lib.platforms.openbsd;
}
