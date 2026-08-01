{
  lib,
  mkDerivation,
  libevent,
}:

mkDerivation {
  path = "usr.sbin/traceroute";
  buildInputs = [ libevent ];

  postPatch = ''
    sed -i '/DPADD/d; /BINMODE/d' \
      "$BSDSRCDIR/usr.sbin/traceroute/Makefile"
  '';

  meta.mainProgram = "traceroute";
  meta.platforms = lib.platforms.openbsd;
}
