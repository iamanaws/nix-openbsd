{
  lib,
  mkDerivation,
  byacc,
  libevent,
  libressl,
  libutil,
  zlib,
  coreutils,
  gzip,
  mail-local,
}:

mkDerivation {
  path = "usr.sbin/smtpd";
  buildInputs = [
    libevent
    libressl
    libutil
    zlib
  ];
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    for smtpdMakefile in "$BSDSRCDIR"/usr.sbin/smtpd/*/Makefile*; do
      sed -i '/DPADD/d; /^RELINK=/d' "$smtpdMakefile"
    done
    # All native programs are installed in bin, including the 8.0 privsep helpers.
    for program in smtpd smtpd-ca smtpd-control smtpd-dispatcher smtpd-lka smtpd-queue smtpd-scheduler smtpctl smtp; do
      echo ".NOPATH: $program" >> "$BSDSRCDIR/usr.sbin/smtpd/$program/Makefile"
    done
    substituteInPlace "$BSDSRCDIR/usr.sbin/smtpd/smtpd.c" \
      --replace-fail '"/sbin/smtpd", "/libexec/smtpd"' '"/bin/smtpd", "/bin/smtpd"'
    substituteInPlace "$BSDSRCDIR/usr.sbin/smtpd/smtpd.h" \
      --replace-fail '"/usr/sbin/smtpctl"' "\"$out/bin/smtpctl\"" \
      --replace-fail '"/usr/local/libexec/smtpd"' "\"$out/bin\""
    substituteInPlace "$BSDSRCDIR/usr.sbin/smtpd/smtpd-defines.h" \
      --replace-fail '"/usr/libexec/mail.local"' '"${mail-local}/bin/mail.local"' \
      --replace-fail '"/usr/sbin/makemap"' "\"$out/bin/makemap\""
    substituteInPlace "$BSDSRCDIR/usr.sbin/smtpd/smtpctl.c" \
      --replace-fail '"/bin/cat"' '"${coreutils}/bin/cat"' \
      --replace-fail '"/usr/bin/gzcat"' '"${gzip}/bin/zcat"'
  '';

  postInstall = ''
    for program in sendmail mailq makemap newaliases; do
      ln -s smtpctl "$out/bin/$program"
    done
  '';

  meta.mainProgram = "smtpd";
  meta.platforms = lib.platforms.openbsd;
}
