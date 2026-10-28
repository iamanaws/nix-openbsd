{
  lib,
  mkDerivation,
  buildPackages,
  libm,
}:
mkDerivation {
  path = "usr.bin/awk";
  buildInputs = [ libm ];
  extraNativeBuildInputs = [ buildPackages.byacc ];
  makeFlags = [ "YACC=${buildPackages.byacc}/bin/yacc" ];
  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.bin/awk/Makefile"
  '';
  meta.mainProgram = "awk";
  meta.platforms = lib.platforms.openbsd;
}
