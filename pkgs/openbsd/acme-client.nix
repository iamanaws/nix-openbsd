{
  lib,
  mkDerivation,
  byacc,
  libressl,
}:

mkDerivation {
  path = "usr.sbin/acme-client";
  buildInputs = [ libressl ];
  extraNativeBuildInputs = [ byacc ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/usr.sbin/acme-client/Makefile"
  '';

  meta.mainProgram = "acme-client";
  meta.platforms = lib.platforms.openbsd;
}
