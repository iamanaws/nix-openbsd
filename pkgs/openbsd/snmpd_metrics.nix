{
  lib,
  mkDerivation,
  libagentx,
  libevent,
  libkvm,
}:

mkDerivation {
  path = "libexec/snmpd/snmpd_metrics";
  extraPaths = [ "sys/net" ];

  buildInputs = [
    libagentx
    libevent
    libkvm
  ];

  postPatch = ''
    sed -i '/DPADD/d' "$BSDSRCDIR/libexec/snmpd/snmpd_metrics/Makefile"
    sed -i '/^BINDIR/d' "$BSDSRCDIR/libexec/snmpd/snmpd_metrics/Makefile"
  '';

  postInstall = ''
    mkdir -p "$out/libexec/snmpd"
    mv "$out/bin/snmpd_metrics" "$out/libexec/snmpd/"
    rmdir "$out/bin"
  '';

  meta.platforms = lib.platforms.openbsd;
}
