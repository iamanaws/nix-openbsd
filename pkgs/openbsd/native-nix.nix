{ pkgs, nixbsdSource }:
let
  tools = pkgs.stdenv.__bootPackages;
  overrides =
    final: previous:
    (import ./bootstrap-build-tools.nix {
      pkgs = tools;
      python3 = pkgs.nativeTestPython.python;
    })
    // {
      python3Packages = pkgs.nativeTestPython.python.pkgs;
      openbsd = previous.openbsd.overrideScope (
        openbsdFinal: _: {
          uname = openbsdFinal.callPackage ./uname.nix { };
        }
      );
      curl = pkgs.stdenv.openbsdBootstrap.curl;
      icu = previous.icu.overrideAttrs (old: {
        # Match OpenBSD ports: the generated data library fails ICU's format checks.
        configureFlags = (old.configureFlags or [ ]) ++ [ "--with-data-packaging=archive" ];
        # ICU's native-archive rule writes its file list before creating this directory.
        preBuild = (old.preBuild or "") + ''
          mkdir -p data/out/tmp
        '';
      });
      doctest = previous.doctest.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./doctest-openbsd.patch ];
      });
      toml11 = previous.toml11.overrideAttrs (old: {
        patches = old.patches ++ [ ./toml11-openbsd-hexfloat.patch ];
      });
      boehmgc = previous.boehmgc.overrideAttrs (old: {
        # Some test executables have no .data; define its start even when empty.
        postConfigure =
          builtins.replaceStrings
            [ "__data_start = ADDR(.data);" ]
            [ "SECTIONS { .data : { __data_start = .; *(.data .data.*) } } INSERT BEFORE .bss;" ]
            old.postConfigure;
      });
      # TBB's OpenBSD tests fail; BLAKE3 also supports hashing without it.
      libblake3 = previous.libblake3.override { useTBB = false; };
      bmake = previous.bmake.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          # OpenBSD supports junk filling (J), but not jemalloc's A option.
          substituteInPlace unit-tests/Makefile \
            --replace-fail 'MALLOC_OPTIONS="JA"' 'MALLOC_OPTIONS="J"'
        '';
      });
      unzip = previous.unzip.overrideAttrs (old: {
        postPatch = old.postPatch + ''
          # OpenBSD uses the BSD4_4 time path and no longer ships this header.
          substituteInPlace unix/unxcfg.h \
            --replace-fail '#  include <sys/timeb.h>' ""
        '';
        # Its legacy configure probes rely on implicit function declarations.
        env = old.env // {
          NIX_CFLAGS_COMPILE = "-std=gnu89";
        };
        doCheck = true;
        checkTarget = "check";
      });
      boost-build = previous.boost-build.overrideAttrs (old: {
        # The compiler wrapper exports WINDRES even on OpenBSD; B2 treats it as Windows.
        env = (old.env or { }) // {
          B2_DONT_EMBED_MANIFEST = "1";
        };
      });
      # Meson's compiler tests pull in another Clang and OpenMP build.
      meson = previous.meson.overrideAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          # Python's processor() runs uname -p; GNU uname returns a CPU model on OpenBSD.
          # Keep this a Python entry point: Meson also invokes it through Python.
          substituteInPlace "$out/bin/meson" \
            --replace-fail 'from mesonbuild.mesonmain import main' \
              'import os; os.environ["PATH"] = "${final.openbsd.uname}/bin" + os.pathsep + os.environ.get("PATH", "")
          from mesonbuild.mesonmain import main'
        '';
        doCheck = false;
        doInstallCheck = false;
      });
    };
  # Apply Nix's dependencies only after bootstrapping the tested stdenv.
  native = import pkgs.path {
    localSystem = pkgs.stdenv.hostPlatform;
    inherit (pkgs) config;
    overlays = pkgs.overlays ++ [ overrides ];
    stdenvStages = { config, overlays, ... }: [
      (_: {
        inherit config overlays;
        inherit (pkgs) stdenv;
      })
    ];
  };
in
# Use the same runtime fixes as the Nix daemon in the test VM.
(native.nix.overrideScope (
  import ./nix-runtime-overrides.nix {
    inherit nixbsdSource;
  }
)).nix-cli.overrideAttrs
  (old: {
    passthru = (old.passthru or { }) // {
      nativePackageSet = native;
    };
  })
