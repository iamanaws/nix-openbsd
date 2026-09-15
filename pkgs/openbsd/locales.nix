{
  lib,
  stdenv,
  byacc,
  flex,
  source,
  version,
}:

stdenv.mkDerivation {
  pname = "openbsd-locales";
  inherit version;
  src = source;

  nativeBuildInputs = [
    byacc
    flex
  ];
  strictDeps = true;
  unpackPhase = ''
    runHook preUnpack
    mkdir source
    cp "$src/usr.bin/mklocale/"{yacc.y,lex.l,ldef.h} source/
    chmod u+w source/yacc.y
    sourceRoot=source
    runHook postUnpack
  '';
  patches = [ ./mklocale-pledge.patch ];
  dontConfigure = true;

  # The generator includes OpenBSD's private rune-format headers.
  env.NIX_CFLAGS_COMPILE = lib.optionalString (!stdenv.hostPlatform.isOpenBSD) (toString [
    "-D__BEGIN_HIDDEN_DECLS="
    "-D__END_HIDDEN_DECLS="
    "-D__packed=__attribute__((__packed__))"
  ]);

  buildPhase = ''
    runHook preBuild
    byacc -d -o yacc.c yacc.y
    flex -o lex.c lex.l
    "$CC" -I. -I"$src/lib/libc" -I"$src/lib/libc/include" \
      yacc.c lex.c -o mklocale
    # The rune file uses network byte order, regardless of the build platform.
    ./mklocale -o LC_CTYPE "$src/share/locale/ctype/en_US.UTF-8.src"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm644 LC_CTYPE "$out/share/locale/UTF-8/LC_CTYPE"
    mkdir -p "$out/share/doc/openbsd-locales"
    sed -n '/COPYRIGHT AND PERMISSION NOTICE/,/^ \*\//p' \
      "$src/share/locale/ctype/en_US.UTF-8.src" \
      > "$out/share/doc/openbsd-locales/COPYING"
    runHook postInstall
  '';

  meta = {
    description = "OpenBSD UTF-8 character classification data";
    license = with lib.licenses; [
      bsd3
      unicode-dfs-2016
    ];
    platforms = lib.platforms.linux ++ lib.platforms.openbsd;
  };
}
