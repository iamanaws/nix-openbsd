{
  lib,
  mkDerivation,
  runtimeShell,
}:

mkDerivation {
  path = "sbin/init";

  postPatch = ''
    substituteInPlace "$BSDSRCDIR/sbin/init/pathnames.h" \
      --replace-fail '#include <paths.h>' \
        $'#include <paths.h>\\n\\n#undef _PATH_BSHELL\\n#define _PATH_BSHELL "${runtimeShell}"'
    substituteInPlace "$BSDSRCDIR/sbin/init/init.c" \
      --replace-fail '	setenv("PATH", _PATH_STDPATH, 1);' ""
  '';

  meta.mainProgram = "init";
  meta.platforms = lib.platforms.openbsd;
}
