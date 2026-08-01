{
  lib,
  mkDerivation,
}:

mkDerivation {
  path = "sbin/resolvd";

  meta.mainProgram = "resolvd";
  meta.platforms = lib.platforms.openbsd;
}
