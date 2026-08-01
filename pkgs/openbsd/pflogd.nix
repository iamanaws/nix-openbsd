{
  lib,
  mkDerivation,
  libpcap,
}:

mkDerivation {
  path = "sbin/pflogd";
  extraPaths = [ "lib/libpcap" ];
  buildInputs = [ libpcap ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/sbin/pflogd/Makefile"
  '';

  meta.mainProgram = "pflogd";
  meta.platforms = lib.platforms.openbsd;
}
