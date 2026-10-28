{
  lib,
  mkDerivation,
  oksh,
}:
mkDerivation {
  path = "usr.sbin/rcctl";
  noCC = true;
  dontConfigure = true;
  dontBuild = true;
  skipIncludesPhase = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m755 "$BSDSRCDIR/usr.sbin/rcctl/rcctl.sh" "$out/bin/rcctl"
    substituteInPlace "$out/bin/rcctl" --replace-fail '#!/bin/ksh' '#!${oksh}/bin/oksh'
    runHook postInstall
  '';
  meta.mainProgram = "rcctl";
  meta.platforms = lib.platforms.openbsd;
}
