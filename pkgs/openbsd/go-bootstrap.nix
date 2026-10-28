{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  patchelf,
  makeWrapper,
}:
stdenvNoCC.mkDerivation {
  pname = "go-openbsd-bootstrap";
  version = "1.26.7";
  # The bootstrap archive and checksum used by OpenBSD ports, lang/go/distinfo.
  src = fetchurl {
    url = "https://download.exigere.com.au/pub/go/go-openbsd-amd64-bootstrap-1.26.7.tar.gz";
    hash = "sha256-axdjC5eMPrhaaZ5eGiwqwDk9bYKfhhbpk9r1TxhA3v4=";
  };
  nativeBuildInputs = [
    patchelf
    makeWrapper
  ];
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/go" "$out/bin"
    cp -R . "$out/share/go/"
    for program in "$out/share/go/bin/"* "$out/share/go/pkg/tool/openbsd_amd64/"*; do
      # Adding DT_RUNPATH moves .dynamic into an RX segment in these Go binaries.
      # Keep .dynamic writable and resolve the two libraries directly instead.
      patchelf --set-interpreter '${stdenv.cc.libc}/libexec/ld.so' \
        --replace-needed libc.so '${stdenv.cc.libc}/lib/libc.so' \
        --replace-needed libpthread.so '${stdenv.cc.libc}/lib/libpthread.so' "$program"
    done
    # The bootstrap linker must also produce runnable temporary build tools.
    wrapProgram "$out/share/go/pkg/tool/openbsd_amd64/link" \
      --add-flags '-I ${stdenv.cc.libc}/libexec/ld.so -r ${stdenv.cc.libc}/lib'
    ln -s "$out/share/go/bin/go" "$out/bin/go"
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    "$out/bin/go" version
    "$out/bin/go" tool compile -V
    "$out/bin/go" tool link -V
    export GOCACHE="$TMPDIR/go-cache" GOTOOLCHAIN=local CGO_ENABLED=0
    printf 'package main\nfunc main() { println("bootstrap ready") }\n' > smoke.go
    "$out/bin/go" build -o smoke smoke.go
    ./smoke
  '';
  meta = {
    description = "OpenBSD Go bootstrap compiler used to build native Go";
    license = lib.licenses.bsd3;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-openbsd" ];
  };
}
