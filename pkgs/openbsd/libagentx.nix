{
  lib,
  mkDerivation,
}:

mkDerivation {
  path = "lib/libagentx";

  preInstall = ''
    mkdir -p "$out/include"
  '';

  meta.platforms = lib.platforms.openbsd;
}
