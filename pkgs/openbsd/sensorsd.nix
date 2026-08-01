{
  lib,
  mkDerivation,
}:

mkDerivation {
  path = "usr.sbin/sensorsd";

  meta.mainProgram = "sensorsd";
  meta.platforms = lib.platforms.openbsd;
}
