{
  lib,
  mkDerivation,
  libressl,
}:

mkDerivation {
  path = "lib/libradius";
  buildInputs = [ libressl ];

  preInstall = ''
    mkdir -p "$out/include"
  '';

  meta.platforms = lib.platforms.openbsd;
}
