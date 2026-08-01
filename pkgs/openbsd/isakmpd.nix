{
  lib,
  mkDerivation,
  buildPackages,
  libkeynote,
  libm,
  libressl,
}:

mkDerivation {
  path = "sbin/isakmpd";
  buildInputs = [
    libkeynote
    libm
    libressl
  ];
  extraNativeBuildInputs = [ buildPackages.bash ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/sbin/isakmpd/Makefile"
    substituteInPlace "$BSDSRCDIR/sbin/isakmpd/Makefile" \
      --replace-fail "/bin/sh" "${buildPackages.bash}/bin/bash"
  '';

  meta.mainProgram = "isakmpd";
  meta.platforms = lib.platforms.openbsd;
}
