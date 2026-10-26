{
  lib,
  mkDerivation,
  byacc,
  libm,
  libressl,
  libutil,
}:

mkDerivation {
  path = "usr.sbin/ntpd";
  buildInputs = [
    libm
    libressl
    libutil
  ];
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/ntpd/Makefile"
  '';

  meta.mainProgram = "ntpd";
  meta.platforms = lib.platforms.openbsd;
}
