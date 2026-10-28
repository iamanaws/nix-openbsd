{ lib, mkDerivation }:
mkDerivation {
  path = "usr.sbin/sa";
  meta.mainProgram = "sa";
  meta.platforms = lib.platforms.openbsd;
}
