{
  lib,
  mkDerivation,
}:

mkDerivation {
  path = "usr.sbin/arp";

  meta.mainProgram = "arp";
  meta.platforms = lib.platforms.openbsd;
}
