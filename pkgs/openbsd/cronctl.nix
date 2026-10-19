{ lib, mkDerivation }:
mkDerivation {
  pname = "cronctl-openbsd";
  path = "usr.sbin/cron";
  postPatch = ''
    cp ${./cronctl.c} "$BSDSRCDIR/usr.sbin/cron/cronctl.c"
    cat > "$BSDSRCDIR/usr.sbin/cron/Makefile" <<'EOF'
    PROG=cronctl
    SRCS=cronctl.c entry.c env.c misc.c
    NOMAN=1
    .include <bsd.prog.mk>
    EOF
  '';
  meta = {
    description = "Validate and reload OpenBSD system crontabs";
    mainProgram = "cronctl";
    platforms = lib.platforms.openbsd;
  };
}
