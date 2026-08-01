{
  lib,
  mkDerivation,
  byacc,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/bgpd";
  buildInputs = [ libutil ];
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/bgpd/Makefile"
  '';

  meta.mainProgram = "bgpd";
  meta.platforms = lib.platforms.openbsd;
}
