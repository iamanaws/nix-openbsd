{
  lib,
  mkDerivation,
  libutil,
}:
mkDerivation {
  path = "sbin/dump";
  buildInputs = [ libutil ];
  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/sbin/dump/Makefile"
  '';
  meta.mainProgram = "dump";
  meta.platforms = lib.platforms.openbsd;
}
