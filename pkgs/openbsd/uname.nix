{ lib, mkDerivation }:

mkDerivation {
  path = "usr.bin/uname";

  meta.mainProgram = "uname";
  meta.platforms = lib.platforms.openbsd;
}
