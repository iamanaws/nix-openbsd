{
  mkDerivation,
  mklocale,
}:
mkDerivation {
  pname = "locale-data-openbsd";
  path = "share/locale/ctype";
  noCC = true;
  extraNativeBuildInputs = [ mklocale ];
  buildPhase = ''
    runHook preBuild
    mklocale -o LC_CTYPE en_US.UTF-8.src
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/share/locale/UTF-8"
    cp LC_CTYPE "$out/share/locale/UTF-8/LC_CTYPE"
    runHook postInstall
  '';
}
