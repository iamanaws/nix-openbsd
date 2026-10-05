# A native package set seeded with the cross-built OpenBSD tools.
{
  nixpkgs,
  bootstrap,
  localSystem ? "x86_64-openbsd",
  config ? { },
  overlays ? [ ],
}:
let
  toolsFor =
    stage:
    bootstrap
    // {
      bashNonInteractive = stage.bashNative or stage.bashNonInteractive;
      coreutils = stage.coreutilsNative or stage.coreutils;
      curl = stage.curlMinimal;
      inherit (stage)
        diffutils
        findutils
        gnugrep
        gnused
        gawk
        gnutar
        gzip
        bzip2
        file
        gnumake
        xz
        patch
        patchelf
        expand-response-params
        perl
        ;
    };
in
import nixpkgs {
  inherit localSystem;
  overlays = [
    (import ./package-overrides.nix)
  ]
  ++ overlays;
  # config.guess on OpenBSD otherwise needs arch from the base system.
  config = {
    configurePlatformsByDefault = true;
  }
  // config;
  stdenvStages =
    {
      lib,
      localSystem,
      config,
      overlays,
      ...
    }:
    [
      (_: {
        inherit config overlays;
        stdenv =
          (import ./native-stdenv.nix {
            inherit
              nixpkgs
              bootstrap
              lib
              localSystem
              config
              ;
          }).override
            {
              # Keep fetchers and setup hooks on seed tools until their dependencies can rebuild.
              overrides = final: prev: {
                inherit (bootstrap) bashNonInteractive coreutils;
                # Rebuild diff before XZ: xzdiff's tests compare anonymous pipes.
                diffutils = prev.diffutils.override { xz = bootstrap.xz; };
                xz = prev.xz.overrideAttrs (old: {
                  nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ final.diffutils ];
                });
                # Bootstrap Perl before libxcrypt, which itself needs Perl.
                perl =
                  let
                    perl = prev.perl5.override {
                      enableCrypt = false;
                      self = perl;
                    };
                  in
                  perl;
                bashNative = prev.bashNonInteractive;
                coreutilsNative = prev.coreutils;
                fetchurl = final.stdenv.fetchurlBoot;
              };
            };
      })
      (
        prevStage:
        let
          tools = toolsFor prevStage;
        in
        {
          inherit config overlays;
          stdenv =
            (import ./native-stdenv.nix {
              inherit
                nixpkgs
                lib
                localSystem
                config
                ;
              bootstrap = tools;
            }).override
              {
                name = "stdenv-openbsd-native-tools";
                overrides = final: prev: {
                  inherit (tools) bashNonInteractive coreutils perl;
                  fetchurl = final.stdenv.fetchurlBoot;
                  compilerRtBootstrap = import ./native-compiler-rt.nix { pkgs = final; };
                  compilerRtNative = import ./native-compiler-rt.nix {
                    pkgs = final;
                    libc = final.openbsd.libc;
                  };
                  rsync = prev.rsync.override {
                    python3 = final.python3Minimal.overrideAttrs (old: {
                      # Rsync's tests need ctypes. Use the previous stage to avoid a libc cycle.
                      buildInputs = old.buildInputs ++ [ prevStage.libffi ];
                      allowedReferences = old.allowedReferences ++ [ prevStage.libffi ];
                    });
                  };
                  stdenvNoLibc = prev.stdenvNoLibc.override {
                    cc = prev.stdenvNoLibc.cc.override (old: {
                      # libc and libexecinfo both link against the compiler builtins.
                      extraPackages = [ final.compilerRtBootstrap ];
                      # The C libraries do not use unwinding. Inherited -lunwind
                      # otherwise makes libpthread depend on the seed runtime.
                      nixSupport = old.nixSupport // {
                        cc-cflags = map (flag: if flag == "--unwindlib=libunwind" then "--unwindlib=none" else flag) (
                          builtins.filter (flag: flag != "-lunwind") old.nixSupport.cc-cflags
                        );
                        cc-ldflags = builtins.filter (
                          flag: flag != "-L${lib.getLib bootstrap.libunwind}/lib"
                        ) old.nixSupport.cc-ldflags;
                      };
                    });
                  };
                  openbsd = prev.openbsd.overrideScope (
                    _: old: {
                      libc = old.libc.overrideAttrs (attrs: {
                        disallowedRequisites = (attrs.disallowedRequisites or [ ]) ++ [ bootstrap.libunwind ];
                      });
                      libcMinimal = old.libcMinimal.overrideAttrs (attrs: {
                        patches = (attrs.patches or [ ]) ++ [ ./libc-difftime.patch ];
                        # Nixpkgs rewrites this private guard to "true", which is active in C23.
                        postInstall = (attrs.postInstall or "") + ''
                          substituteInPlace "$dev/include/sys/time.h" \
                            --replace-fail 'defined(_STANDALONE) || true' \
                              'defined(_STANDALONE) || defined (_LIBC)'
                        '';
                      });
                    }
                  );
                };
              };
        }
      )
      (
        prevStage:
        let
          tools = toolsFor prevStage.stdenv.__bootPackages;
          libraries = {
            libc = prevStage.openbsd.libc;
            compiler-rt = prevStage.compilerRtNative;
          };
          libraryStdenv =
            (import ./native-stdenv.nix {
              inherit
                nixpkgs
                lib
                localSystem
                config
                ;
              bootstrap = tools // libraries;
            }).override
              {
                name = "stdenv-openbsd-native-libraries";
              };
          runtimes = import ./native-cxx-runtimes.nix {
            pkgs = prevStage;
            stdenv = libraryStdenv;
            inherit (libraries) compiler-rt;
          };
        in
        {
          inherit config overlays;
          stdenv =
            (import ./native-stdenv.nix {
              inherit
                nixpkgs
                lib
                localSystem
                config
                ;
              bootstrap = tools // libraries // runtimes;
            }).override
              {
                name = "stdenv-openbsd-native-runtimes";
                overrides = final: _: {
                  inherit (tools) bashNonInteractive coreutils perl;
                  fetchurl = final.stdenv.fetchurlBoot;
                };
              };
        }
      )
      (
        prevStage:
        let
          tools = prevStage.stdenv.openbsdBootstrap;
          python3 = import ./native-test-python.nix {
            pkgs = prevStage.stdenv.__bootPackages;
          };
          toolchain = import ./native-toolchain.nix {
            pkgs = prevStage;
            inherit python3;
          };
        in
        {
          inherit config overlays;
          stdenv =
            (import ./native-stdenv.nix {
              inherit
                nixpkgs
                lib
                localSystem
                config
                ;
              bootstrap = tools // {
                inherit (toolchain) clang bintools;
              };
            }).override
              {
                name = "stdenv-openbsd-native-compiler";
                overrides = final: prev: {
                  inherit (tools) bashNonInteractive coreutils perl;
                  bashNative = prev.bashNonInteractive;
                  coreutilsNative = prev.coreutils;
                  nativeToolchain = toolchain;
                  nativeTestPython = python3;
                  fetchurl = final.stdenv.fetchurlBoot;
                };
              };
        }
      )
      (
        prevStage:
        let
          # Rebuild script interpreters first so the remaining tools' shebangs
          # and helper scripts no longer retain the earlier tools.
          tools = prevStage.stdenv.openbsdBootstrap // {
            bashNonInteractive = prevStage.bashNative;
            coreutils = prevStage.coreutilsNative;
          };
        in
        {
          inherit config overlays;
          stdenv =
            (import ./native-stdenv.nix {
              inherit
                nixpkgs
                lib
                localSystem
                config
                ;
              bootstrap = tools;
            }).override
              {
                name = "stdenv-openbsd-native-shell";
                overrides = final: prev: {
                  inherit (tools) bashNonInteractive coreutils perl;
                  inherit (prevStage) nativeToolchain nativeTestPython;
                  perlNative =
                    let
                      perl = prev.perl5.override {
                        enableCrypt = false;
                        self = perl;
                      };
                    in
                    perl;
                  fetchurl = final.stdenv.fetchurlBoot;
                };
              };
        }
      )
      (
        prevStage:
        let
          tools = toolsFor prevStage // {
            inherit (prevStage.stdenv.openbsdBootstrap)
              clang
              bintools
              libc
              compiler-rt
              libunwind
              libcxx
              ;
            perl = prevStage.perlNative;
          };
        in
        {
          inherit config overlays;
          stdenv =
            (import ./native-stdenv.nix {
              inherit
                nixpkgs
                lib
                localSystem
                config
                ;
              bootstrap = tools;
            }).override
              {
                name = "stdenv-openbsd-native";
                overrides = final: _: {
                  inherit (tools) bashNonInteractive coreutils perl;
                  inherit (prevStage) nativeToolchain nativeTestPython;
                  fetchurl = final.stdenv.fetchurlBoot;
                };
              };
        }
      )
    ];
}
