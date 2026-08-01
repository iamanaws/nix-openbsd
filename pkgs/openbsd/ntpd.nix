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
    substituteInPlace "$BSDSRCDIR/usr.sbin/ntpd/ntpd.c" \
      --replace-fail '"/usr/sbin/ntpd"' "\"$out/bin/ntpd\""
  '';

  meta.mainProgram = "ntpd";
  meta.platforms = lib.platforms.openbsd;
}
