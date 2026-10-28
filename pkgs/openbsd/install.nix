{ lib, mkDerivation }:
mkDerivation {
  path = "usr.bin/xinstall";
  meta.mainProgram = "install";
  meta.platforms = lib.platforms.openbsd;
}
