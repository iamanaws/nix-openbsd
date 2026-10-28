{
  lib,
  mkDerivation,
  libutil,
}:
mkDerivation {
  path = "sbin/bioctl";
  buildInputs = [ libutil ];
  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/sbin/bioctl/Makefile"
  '';
  meta.mainProgram = "bioctl";
  meta.platforms = lib.platforms.openbsd;
}
