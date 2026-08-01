{
  lib,
  mkDerivation,
}:

mkDerivation {
  pname = "snmp-mibs";
  path = "share/snmp";

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/snmp/mibs"
    install -m 0444 "$BSDSRCDIR/share/snmp/"*.txt "$out/share/snmp/mibs/"
    runHook postInstall
  '';

  meta.platforms = lib.platforms.openbsd;
}
