{
  lib,
  mkDerivation,
  libressl,
}:

mkDerivation {
  path = "usr.sbin/dhcpd";
  buildInputs = [ libressl ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/dhcpd/Makefile"
  '';

  meta.mainProgram = "dhcpd";
  meta.platforms = lib.platforms.openbsd;
}
