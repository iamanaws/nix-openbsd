{ lib, mkDerivation }:
mkDerivation {
  path = "usr.bin/find";
  meta.mainProgram = "find";
  meta.platforms = lib.platforms.openbsd;
}
