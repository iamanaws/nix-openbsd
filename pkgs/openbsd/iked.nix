{
  lib,
  mkDerivation,
  buildPackages,
  byacc,
  libevent,
  libradius,
  libressl,
  libutil,
}:

mkDerivation {
  path = "sbin/iked";
  buildInputs = [
    libevent
    libradius
    libressl
    libutil
  ];
  extraNativeBuildInputs = [
    buildPackages.bash
    byacc
  ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/sbin/iked/Makefile"
    substituteInPlace "$BSDSRCDIR/sbin/iked/Makefile" \
      --replace-fail "/bin/sh" "${buildPackages.bash}/bin/bash"
  '';

  meta.mainProgram = "iked";
  meta.platforms = lib.platforms.openbsd;
}
