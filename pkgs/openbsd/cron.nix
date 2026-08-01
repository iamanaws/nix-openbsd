{
  lib,
  mkDerivation,
}:

mkDerivation {
  path = "usr.sbin/cron";

  meta.mainProgram = "cron";
  meta.platforms = lib.platforms.openbsd;
}
