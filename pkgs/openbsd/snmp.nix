{
  lib,
  mkDerivation,
  libressl,
  libutil,
}:

mkDerivation {
  path = "usr.bin/snmp";

  buildInputs = [
    libressl
    libutil
  ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.bin/snmp/Makefile"
    substituteInPlace "$BSDSRCDIR/usr.bin/snmp/snmpc.c" \
      --replace-fail \
        'errx(1, "setlocale(LC_CTYPE, \"en_US.UTF-8\") failed");' \
        'warnx("setlocale(LC_CTYPE, \"en_US.UTF-8\") failed; using current locale");'
  '';

  meta.mainProgram = "snmp";
  meta.platforms = lib.platforms.openbsd;
}
