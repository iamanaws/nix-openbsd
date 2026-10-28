{
  flakeRef ? "path:" + toString ../..,
  pkgs ? (builtins.getFlake flakeRef).legacyPackages.x86_64-openbsd,
  nonce ? "",
}:
let
  suffix = pkgs.lib.optionalString (nonce != "") "-${nonce}";
  pure = pkgs.buildGoModule {
    pname = "openbsd-go-pure${suffix}";
    version = "1";
    src = ./pure;
    vendorHash = null;
    env.CGO_ENABLED = 0;
    postCheck = ''
      test "$EUID" -ne 0
      "$GOPATH/bin/openbsd-go-pure" | grep -Fx 'Go openbsd/amd64: HÉLLO'
    '';
  };
  cgo = pkgs.buildGoModule {
    pname = "openbsd-go-cgo${suffix}";
    version = "1";
    src = ./cgo;
    vendorHash = null;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.sqlite ];
    postCheck = ''
      test "$EUID" -ne 0
      "$GOPATH/bin/openbsd-go-cgo" | grep -Fx 'SQLite through cgo: 42'
    '';
  };
  standard =
    pkgs.runCommand "openbsd-go-standard-tests"
      {
        nativeBuildInputs = [
          pkgs.go
          pkgs.stdenv.cc
        ];
      }
      ''
        test "$EUID" -ne 0
        export GOCACHE="$TMPDIR/go-cache" GOPATH="$TMPDIR/go"
        export GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GOMAXPROCS="$NIX_BUILD_CORES"
        mkdir -p "$out"
        set -o pipefail
        go test -short -p "$NIX_BUILD_CORES" -timeout 10m std 2>&1 | tee "$out/results.log"
      '';
  application =
    pkgs.runCommand "openbsd-shfmt-checks"
      {
        nativeBuildInputs = [ pkgs.shfmt ];
      }
      ''
        shfmt --version
        printf 'if true;then echo hello;fi\n' | shfmt -ln posix > actual
        printf 'if true; then echo hello; fi\n' > expected
        diff -u expected actual
        shfmt -ln posix < actual > repeated
        cmp actual repeated
        touch "$out"
      '';
in
{
  inherit
    pure
    cgo
    standard
    application
    ;
  all = pkgs.linkFarm "openbsd-go-tests" [
    {
      name = "toolchain";
      path = pkgs.go;
    }
    {
      name = "bootstrap";
      path = pkgs.go.goBootstrap;
    }
    {
      name = "shfmt";
      path = pkgs.shfmt;
    }
    {
      name = "patchelf";
      path = pkgs.patchelf;
    }
    {
      name = "go-source";
      path = pkgs.go.src;
    }
    {
      name = "bootstrap-source";
      path = pkgs.go.goBootstrap.src;
    }
    {
      name = "shfmt-source";
      path = pkgs.shfmt.src;
    }
    {
      name = "shfmt-modules";
      path = pkgs.shfmt.goModules;
    }
    {
      name = "pure";
      path = pure;
    }
    {
      name = "cgo";
      path = cgo;
    }
    {
      name = "standard";
      path = standard;
    }
    {
      name = "application";
      path = application;
    }
  ];
}
