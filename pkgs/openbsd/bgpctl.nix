{
  lib,
  mkDerivation,
  libm,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/bgpctl";
  extraPaths = [ "usr.sbin/bgpd" ];
  buildInputs = [
    libm
    libutil
  ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/bgpctl/Makefile"
  '';

  meta.mainProgram = "bgpctl";
  meta.platforms = lib.platforms.openbsd;
}
