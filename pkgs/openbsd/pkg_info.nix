{
  lib,
  mkDerivation,
  perl,
}:
mkDerivation {
  path = "usr.sbin/pkg_add";
  noCC = true;
  dontConfigure = true;
  dontBuild = true;
  skipIncludesPhase = true;
  # security(8) queries the traditional package database; install only its reader.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/libdata/perl5"
    cp -R "$BSDSRCDIR/usr.sbin/pkg_add/OpenBSD" "$out/libdata/perl5/"
    install -m755 "$BSDSRCDIR/usr.sbin/pkg_add/pkg_add" "$out/bin/pkg_info"
    substituteInPlace "$out/bin/pkg_info" \
      --replace-fail '#! /usr/bin/perl' '#!${perl}/bin/perl' \
      --replace-fail 'use v5.36;' "use lib '$out/libdata/perl5'; use v5.36;"
    runHook postInstall
  '';
  meta.mainProgram = "pkg_info";
  meta.platforms = lib.platforms.openbsd;
}
