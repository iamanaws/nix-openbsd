{ lib, mkDerivation }:
mkDerivation {
  path = "usr.bin/mail";
  postPatch = ''
    substituteInPlace "$BSDSRCDIR/usr.bin/mail/pathnames.h" \
      --replace-fail '"/usr/libexec/lockspool"' '"/run/wrappers/bin/lockspool"' \
      --replace-fail '"/usr/share/misc/' '"'"$out/share/misc/"
    substituteInPlace "$BSDSRCDIR/usr.bin/mail/send.c" \
      --replace-fail '_PATH_SENDMAIL;' '"/run/wrappers/bin/sendmail";'
  '';
  postInstall = ''
    mkdir -p "$out/etc" "$out/share/misc"
    cp "$BSDSRCDIR/usr.bin/mail/misc/mail.rc" "$out/etc/mail.rc"
    cp "$BSDSRCDIR/usr.bin/mail/misc/"mail.*help "$out/share/misc/"
  '';
  meta.mainProgram = "mail";
  meta.platforms = lib.platforms.openbsd;
}
