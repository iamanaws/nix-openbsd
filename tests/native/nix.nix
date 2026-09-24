{ pkgs, nixbsdSource }:
let
  tools = pkgs.stdenv.__bootPackages;
  overrides = _: previous: {
    python3 = pkgs.nativeTestPython.python;
    python3Packages = pkgs.nativeTestPython.python.pkgs;
    cmake = tools.cmakeMinimal;
    ninja = tools.ninja.override {
      python3 = tools.python3Minimal;
      buildDocs = false;
      re2c = tools.re2c.override { python3 = tools.python3Minimal; };
    };
    curl = pkgs.stdenv.openbsdBootstrap.curl;
    doctest = previous.doctest.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./doctest-openbsd.patch ];
    });
    toml11 = previous.toml11.overrideAttrs (old: {
      patches = old.patches ++ [ ./toml11-openbsd-hexfloat.patch ];
    });
    boehmgc = previous.boehmgc.overrideAttrs (old: {
      # Some test executables have no .data; define its start even when empty.
      postConfigure = builtins.replaceStrings
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
      env = old.env // { NIX_CFLAGS_COMPILE = "-std=gnu89"; };
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
    meson = previous.meson.overrideAttrs {
      doCheck = false;
      doInstallCheck = false;
    };
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
  _: prev: {
    nix-store = (prev.nix-store.override { withAWS = false; }).overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        # Meson detects OpenBSD's CPU model string instead of its architecture.
        substituteInPlace meson.build \
          --replace-fail "nix_system_cpu + '-' + host_machine.system()" \
            "'${pkgs.stdenv.hostPlatform.system}'"
      '';
      patches = (old.patches or [ ]) ++ [
        (nixbsdSource + "/overlays/nix-openbsd-builder-pty.patch")
        (nixbsdSource + "/overlays/nix-openbsd-build-users.patch")
      ];
    });
    nix-main = prev.nix-main.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        (nixbsdSource + "/overlays/nix-openbsd-atfork.patch")
      ];
    });
    nix-util = prev.nix-util.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace terminal.cc \
          --replace-fail '#  ifdef __APPLE__' \
            '#  if defined(__APPLE__) || defined(__OpenBSD__)'
      '';
    });
    nix-cli = prev.nix-cli.overrideAttrs (old: {
      env = (old.env or { }) // {
        NIX_CFLAGS_COMPILE_x86_64_unknown_openbsd =
          (old.env.NIX_CFLAGS_COMPILE_x86_64_unknown_openbsd or "")
          + " -DBOOST_STACKTRACE_GNU_SOURCE_NOT_REQUIRED";
      };
    });
  }
)).nix-cli
