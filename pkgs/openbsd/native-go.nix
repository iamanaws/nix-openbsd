{ pkgs, go }:
let
  bootstrap = pkgs.callPackage ./go-bootstrap.nix { };
  runtimeLibraryPath = pkgs.lib.makeLibraryPath [
    pkgs.stdenv.cc.libc
    pkgs.stdenv.cc.libunwind
  ];
in
go.overrideAttrs (old: {
  env = old.env // {
    GOROOT_BOOTSTRAP = "${bootstrap}/share/go";
  };
  postPatch = old.postPatch + ''
    # Internal links need the compiler wrapper's libc and unwind runtime paths.
    substituteInPlace src/cmd/link/internal/ld/elf.go \
      --replace-fail 'if rpath.val != "" {' \
        'if ctxt.IsOpenbsd() && buildcfg.GOOS == runtime.GOOS && buildcfg.GOARCH == runtime.GOARCH {
          if rpath.val == "" { rpath.val = "${runtimeLibraryPath}" } else {
            rpath.val = "${runtimeLibraryPath}:" + rpath.val
          }
        }
        if rpath.val != "" {'
    # This direct linker option bypasses Clang's translation of -no-pie.
    substituteInPlace src/cmd/link/internal/ld/lib.go \
      --replace-fail '"-Wl,-nopie"' '"-Wl,-no-pie"'
    ${bootstrap}/share/go/bin/gofmt -w src/cmd/link/internal/ld/elf.go src/cmd/link/internal/ld/lib.go
  '';
  disallowedReferences = [ bootstrap ];
  passthru = old.passthru // {
    goBootstrap = bootstrap;
  };
  meta = old.meta // {
    platforms = old.meta.platforms ++ [ "x86_64-openbsd" ];
  };
})
