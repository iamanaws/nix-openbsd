{
  lib,
  mkDerivation,
  byacc,
  flex,
  libressl,
}:

mkDerivation {
  path = "lib/libkeynote";
  buildInputs = [ libressl ];
  extraNativeBuildInputs = [
    byacc
    flex
  ];

  preInstall = ''
    mkdir -p "$out/include"
  '';

  meta.platforms = lib.platforms.openbsd;
}
