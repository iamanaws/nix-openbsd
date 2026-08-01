{
  lib,
  mkDerivation,
}:

mkDerivation {
  path = "usr.bin/crontab";
  extraPaths = [ "usr.sbin/cron" ];

  postPatch = ''
    sed -i '/BINOWN/d; /BINGRP/d; /BINMODE/d' \
      "$BSDSRCDIR/usr.bin/crontab/Makefile"
  '';

  meta.mainProgram = "crontab";
  meta.platforms = lib.platforms.openbsd;
}
