{
  lib,
  mkDerivation,
  libm,
}:
mkDerivation {
  path = "usr.bin/lastcomm";
  buildInputs = [ libm ];
  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.bin/lastcomm/Makefile"
  '';
  meta.mainProgram = "lastcomm";
  meta.platforms = lib.platforms.openbsd;
}
