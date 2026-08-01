{
  lib,
  mkDerivation,
  libpcap,
  libressl,
}:

mkDerivation {
  path = "usr.sbin/tcpdump";
  extraPaths = [
    "lib/libpcap"
    "sbin/pfctl"
    "sys/net"
    "usr.sbin/hostapd"
  ];
  buildInputs = [
    libpcap
    libressl
  ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/tcpdump/Makefile"
  '';

  meta.mainProgram = "tcpdump";
  meta.platforms = lib.platforms.openbsd;
}
