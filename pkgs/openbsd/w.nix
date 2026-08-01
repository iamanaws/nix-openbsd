{
  lib,
  mkDerivation,
  libkvm,
}:

mkDerivation {
  path = "usr.bin/w";
  buildInputs = [ libkvm ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.bin/w/Makefile"
  '';

  meta.mainProgram = "w";
  meta.platforms = lib.platforms.openbsd;
}
