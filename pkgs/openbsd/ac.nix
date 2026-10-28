{ lib, mkDerivation }:
mkDerivation {
  path = "usr.sbin/ac";
  meta.mainProgram = "ac";
  meta.platforms = lib.platforms.openbsd;
}
