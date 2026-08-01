{
  lib,
  mkDerivation,
  libcurses,
}:

mkDerivation {
  path = "lib/libedit";
  buildInputs = [ libcurses ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/lib/libedit/Makefile"
  '';

  preInstall = ''
    mkdir -p "$out/include"
  '';

  meta.platforms = lib.platforms.openbsd;
}
