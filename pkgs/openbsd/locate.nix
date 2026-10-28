{
  lib,
  mkDerivation,
  awk,
  find,
  sort,
  coreutils,
  gnused,
}:
let
  runtimePath = lib.makeBinPath [
    awk
    find
    sort
    coreutils
    gnused
  ];
in
mkDerivation {
  path = "usr.bin/locate";
  extraPaths = [ "usr.bin/Makefile.inc" ];
  # Install the helper programs together with the database update scripts.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/libexec"
    install -m755 locate/locate "$out/bin/locate"
    for name in bigram code; do
      install -m755 "$name/locate.$name" "$out/libexec/locate.$name"
    done
    for name in updatedb mklocatedb; do
      install -m755 "locate/$name.sh" "$out/libexec/locate.$name"
      substituteInPlace "$out/libexec/locate.$name" \
        --replace-fail 'LIBEXECDIR=/usr/libexec' "LIBEXECDIR=$out/libexec" \
        --replace-fail 'PATH=$LIBEXECDIR:/bin:/usr/bin:$PATH' \
          'PATH=$LIBEXECDIR:${runtimePath}:/bin:/usr/bin:$PATH'
    done
    patchShebangs "$out/libexec/locate."*
    runHook postInstall
  '';
  meta.mainProgram = "locate";
  meta.platforms = lib.platforms.openbsd;
}
