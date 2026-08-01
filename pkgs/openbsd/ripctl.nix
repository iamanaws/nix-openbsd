{
  lib,
  mkDerivation,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/ripctl";
  extraPaths = [ "usr.sbin/ripd" ];
  buildInputs = [ libutil ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/ripctl/Makefile"
  '';

  meta.mainProgram = "ripctl";
  meta.platforms = lib.platforms.openbsd;
}
