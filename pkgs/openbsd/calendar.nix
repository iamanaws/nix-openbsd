{
  lib,
  mkDerivation,
  stdenv,
  smtpd,
}:
mkDerivation {
  path = "usr.bin/calendar";
  postPatch = ''
    substituteInPlace "$BSDSRCDIR/usr.bin/calendar/pathnames.h" \
      --replace-fail '"/usr/bin/cpp"' '"${stdenv.cc.cc}/bin/clang-cpp"' \
      --replace-fail '-I/usr/share/calendar' "-I$out/share/calendar"
    substituteInPlace "$BSDSRCDIR/usr.bin/calendar/calendar.c" \
      --replace-fail 'unveil(_PATH_SENDMAIL, "x")' 'unveil("/run/wrappers/bin/sendmail", "x")' \
      --replace-fail 'if (unveil(_PATH_CPP, "x") == -1)' \
        'if (unveil("${smtpd}/bin/smtpctl", "x") == -1) err(1, "unveil smtpctl");
        if (unveil(_PATH_CPP, "x") == -1)'
    substituteInPlace "$BSDSRCDIR/usr.bin/calendar/io.c" \
      --replace-fail '_PATH_SENDMAIL' '"/run/wrappers/bin/sendmail"'
  '';
  # The Makefile's beforeinstall target uses /usr/share/calendar and root:wheel.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share"
    install -m755 calendar "$out/bin/calendar"
    cp -R "$BSDSRCDIR/usr.bin/calendar/calendars" "$out/share/calendar"
    runHook postInstall
  '';
  meta.mainProgram = "calendar";
  meta.platforms = lib.platforms.openbsd;
}
