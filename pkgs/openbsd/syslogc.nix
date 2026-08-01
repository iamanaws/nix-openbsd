{
  lib,
  mkDerivation,
}:

mkDerivation {
  path = "usr.sbin/syslogc";

  meta.mainProgram = "syslogc";
  meta.platforms = lib.platforms.openbsd;
}
