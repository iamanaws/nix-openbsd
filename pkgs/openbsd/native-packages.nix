# A native package set seeded with the cross-built OpenBSD tools.
{
  nixpkgs,
  bootstrap,
  localSystem ? "x86_64-openbsd",
  config ? { },
  overlays ? [ ],
}:
import nixpkgs {
  inherit localSystem;
  overlays = [
    (final: prev: {
      gzip = prev.gzip.overrideAttrs (old: {
        # Gzip's bundled gnulib predates OpenBSD's opaque FILE type.
        patches = (old.patches or [ ]) ++ [ ./gzip-openbsd-fseeko.patch ];
      });
      gnumake = prev.gnumake.overrideAttrs (old: {
        # make check silently skips the regression suite without Perl.
        nativeCheckInputs = (old.nativeCheckInputs or [ ]) ++ [ final.perl ];
        patches = (old.patches or [ ]) ++ [ ./gnumake-tests-shell.patch ];
      });
    })
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
                inherit (bootstrap) bashNonInteractive coreutils perl;
                bashNative = prev.bashNonInteractive;
                coreutilsNative = prev.coreutils;
                fetchurl = final.stdenv.fetchurlBoot;
              };
            };
      })
      (
        prevStage:
        let
          tools = bootstrap // {
            bashNonInteractive = prevStage.bashNative;
            coreutils = prevStage.coreutilsNative;
            inherit (prevStage)
              gnused
              gzip
              file
              gnumake
              xz
              ;
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
                name = "stdenv-openbsd-native-tools";
                overrides = final: _: {
                  inherit (tools) bashNonInteractive coreutils perl;
                  fetchurl = final.stdenv.fetchurlBoot;
                };
              };
        }
      )
    ];
}
