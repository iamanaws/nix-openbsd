{
  lib,
  mkDerivation,
  byacc,
  libevent,
  libressl,
  libutil,
  snmp_mibs,
  snmpd_metrics,
}:

mkDerivation {
  path = "usr.sbin/snmpd";

  buildInputs = [
    libevent
    libressl
    libutil
  ];
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/snmpd/Makefile"
    sed -i \
      -e '/#include <stdio.h>/a#include <stdlib.h>' \
      -e '/#include <strings.h>/a#include <string.h>' \
      "$BSDSRCDIR/usr.sbin/snmpd/parse.y"
    sed -i \
      -e '/#include <sys\/tree.h>/a#include <sys/types.h>' \
      -e '/#include <assert.h>/a#include <stdlib.h>\n#include <string.h>' \
      "$BSDSRCDIR/usr.sbin/snmpd/mib.y"
    substituteInPlace "$BSDSRCDIR/usr.sbin/snmpd/snmpd.h" \
      --replace-fail '#define SNMPD_BACKEND		"/usr/libexec/snmpd"' \
      "#define SNMPD_BACKEND		\"${snmpd_metrics}/libexec/snmpd\""
    substituteInPlace "$BSDSRCDIR/usr.sbin/snmpd/parse.y" \
      --replace-fail 'mib_parsedir("/usr/share/snmp/mibs");' \
      'mib_parsedir("${snmp_mibs}/share/snmp/mibs");'

    # NixBSD does not currently install OpenBSD's en_US.UTF-8 locale archive.
    # Keep the inherited C locale instead of terminating the SNMP engine.
    substituteInPlace "$BSDSRCDIR/usr.sbin/snmpd/snmpe.c" \
      --replace-fail 'fatal("setlocale(LC_CTYPE, \"en_US.UTF-8\")");' \
      'log_warnx("setlocale(LC_CTYPE, \"en_US.UTF-8\") failed; using current locale");'
  '';

  meta.mainProgram = "snmpd";
  meta.platforms = lib.platforms.openbsd;
}
