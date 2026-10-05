{ lib, mkDerivation }:

mkDerivation {
  path = "usr.bin/arch";

  meta.mainProgram = "arch";
  meta.platforms = lib.platforms.openbsd;
}
