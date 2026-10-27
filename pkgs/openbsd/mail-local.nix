{ lib, mkDerivation }:
mkDerivation {
  path = "libexec/mail.local";
  postPatch = ''
    substituteInPlace "$BSDSRCDIR/libexec/mail.local/pathnames.h" \
      --replace-fail '"/usr/libexec/lockspool"' '"/run/wrappers/bin/lockspool"'
  '';
  meta.mainProgram = "mail.local";
  meta.platforms = lib.platforms.openbsd;
}
