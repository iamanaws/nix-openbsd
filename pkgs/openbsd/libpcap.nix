{
  lib,
  mkDerivation,
  byacc,
  flex,
}:

mkDerivation {
  path = "lib/libpcap";
  extraPaths = [ "sys/net" ];
  extraNativeBuildInputs = [
    byacc
    flex
  ];

  preInstall = ''
    mkdir -p "$out/include"
  '';

  meta.platforms = lib.platforms.openbsd;
}
