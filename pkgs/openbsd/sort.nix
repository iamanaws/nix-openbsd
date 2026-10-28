{ lib, mkDerivation }:
mkDerivation {
  path = "usr.bin/sort";
  meta.mainProgram = "sort";
  meta.platforms = lib.platforms.openbsd;
}
