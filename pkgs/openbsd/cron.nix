{
  lib,
  mkDerivation,
}:

mkDerivation {
  path = "usr.sbin/cron";

  postPatch = ''
    substituteInPlace "$BSDSRCDIR/usr.sbin/cron/config.h" \
      --replace-fail '#define MAILARG _PATH_SENDMAIL' '#define MAILARG "/run/wrappers/bin/sendmail"'
  '';

  meta.mainProgram = "cron";
  meta.platforms = lib.platforms.openbsd;
}
