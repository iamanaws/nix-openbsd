{
  lib,
  mkDerivation,
  libkvm,
  libutil,
}:

mkDerivation {
  path = "usr.bin/netstat";
  buildInputs = [
    libkvm
    libutil
  ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.bin/netstat/Makefile"
  '';

  meta.mainProgram = "netstat";
  meta.platforms = lib.platforms.openbsd;
}
