{ lib, mkDerivation }:
mkDerivation {
  path = "libexec/lockspool";
  extraPaths = [ "libexec/mail.local" ];
  meta.mainProgram = "lockspool";
  meta.platforms = lib.platforms.openbsd;
}
