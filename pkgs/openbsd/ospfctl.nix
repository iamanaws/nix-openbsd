{
  lib,
  mkDerivation,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/ospfctl";
  extraPaths = [ "usr.sbin/ospfd" ];
  buildInputs = [ libutil ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/ospfctl/Makefile"
  '';

  meta.mainProgram = "ospfctl";
  meta.platforms = lib.platforms.openbsd;
}
