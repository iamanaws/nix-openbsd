{
  lib,
  mkDerivation,
  byacc,
}:

mkDerivation {
  path = "usr.bin/doas";
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/BINMODE/d' "$BSDSRCDIR/usr.bin/doas/Makefile"
  '';

  meta.mainProgram = "doas";
  meta.platforms = lib.platforms.openbsd;
}
