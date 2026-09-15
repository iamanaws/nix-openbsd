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
      bashNonInteractive = stage.bashNative;
      coreutils = stage.coreutilsNative;
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
    (final: prev: {
      # Avoid libfido2's Linux udev hook in the bootstrap CVS fetcher.
      fetchcvs = prev.fetchcvs.override {
        openssh = final.openssh.override { withFIDO = false; };
      };
      netbsd = prev.netbsd.overrideScope (
        _: old: {
          # OpenBSD already provides fts.h and the FTS functions in libc.
          install = old.install.override { fts = null; };
        }
      );
      openbsd = prev.openbsd.overrideScope (
        _: old: {
          include = old.include.overrideAttrs (attrs: {
            nativeBuildInputs = (attrs.nativeBuildInputs or [ ]) ++ [ final.perl ];
            # Keep the header generator out of the install-directory rewrite.
            postPatch = (attrs.postPatch or "") + ''
              substituteInPlace "$BSDSRCDIR/lib/libcrypto/Makefile" \
                --replace-fail '/usr/bin/perl' '${final.perl}/bin/perl'
            '';
            postInstall = (attrs.postInstall or "") + ''
              test -s "$out/include/openssl/obj_mac.h"
            '';
          });
        }
      );
      ncurses = prev.ncurses.overrideAttrs (old: {
        # Match the versioned --host so configure recognizes a native build.
        configurePlatforms = [ ];
        configureFlags = old.configureFlags ++ [
          "--build=${final.stdenv.buildPlatform.config}${final.stdenv.cc.libc.version}"
        ];
      });
      krb5 = prev.krb5.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ./krb5-openbsd-shared.patch
          # Reuse Nixpkgs' FreeBSD fix: OpenBSD also lacks ENODATA.
          (final.fetchpatch {
            name = "fix-missing-ENODATA.patch";
            url = "https://cgit.freebsd.org/ports/plain/security/krb5-122/files/patch-lib_krad_packet.c?id=0501f716c4aff7880fde56e42d641ef504593b7d";
            extraPrefix = "";
            hash = "sha256-l8ev+WrDKbTqwgBRYhfJGELkCCE8mJTqVHFBvvCPvgE=";
          })
        ];
      });
      mandoc = prev.mandoc.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./mandoc-pledge.patch ];
      });
      libxcrypt = prev.libxcrypt.overrideAttrs (old: {
        # Its shared link uses -z defs; Libtool otherwise strips OpenBSD's -lc.
        makeFlags = (old.makeFlags or [ ]) ++ [ "libcrypt_la_LIBADD=-Wl,-lc" ];
      });
      libuv = prev.libuv.overrideAttrs (old: {
        # Allow missing kqueue filenames and OpenBSD's no-network error in tests.
        patches = (old.patches or [ ]) ++ [ ./libuv-openbsd-tests.patch ];
      });
      libxml2 = prev.libxml2.overrideAttrs (old: {
        # OpenBSD does not provide iconv in libc.
        propagatedBuildInputs = old.propagatedBuildInputs ++ [ final.libiconv ];
      });
      libarchive = prev.libarchive.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          # Bare Windows locale names select ASCII on OpenBSD, not CP1251/CP932.
          substituteInPlace libarchive/test/*.c \
            --replace-quiet 'setlocale(LC_ALL, "Russian_Russia")' 'setlocale(LC_ALL, "Russian_Russia.1251")' \
            --replace-quiet 'setlocale(LC_ALL, "Japanese_Japan")' 'setlocale(LC_ALL, "Japanese_Japan.932")'
        '';
      });
      python3Minimal = prev.python3Minimal.overrideAttrs (old: {
        # Account for the unwind runtime selected by this bootstrap stage.
        allowedReferences = old.allowedReferences ++ [ (final.lib.getLib final.stdenv.cc.libunwind) ];
        meta = old.meta // {
          platforms = old.meta.platforms ++ [ "x86_64-openbsd" ];
        };
      });
      gnugrep = prev.gnugrep.overrideAttrs (old: {
        # Keep regex and DFA case mappings consistent: https://debbugs.gnu.org/71471
        patches = (old.patches or [ ]) ++ [ ./gnulib-openbsd-case-mapping.patch ];
      });
      diffutils = prev.diffutils.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./diffutils-openbsd-pipes.patch ];
      });
      findutils = prev.findutils.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./findutils-test-gnulib.patch ];
        prePatch = (old.prePatch or "") + ''
          (cd gl; patch -p1 < ${./gnulib-openbsd-fseeko.patch})
        '';
      });
      gnutar = prev.gnutar.overrideAttrs (old: {
        prePatch = (old.prePatch or "") + ''
          (cd gnu; patch -p2 < ${./gnulib-openbsd-fseeko.patch})
        '';
      });
      autoconf = prev.autoconf.overrideAttrs (old: {
        checkInputs = (old.checkInputs or [ ]) ++ [ final.zlib ];
        # make -n check tries to run tests/testsuite before generating it.
        checkTarget = "check";
        preCheck = (old.preCheck or "") + ''
          # Test configure scripts also need an explicit platform without arch.
          export configure_options="--build=${final.stdenv.buildPlatform.config}"
        '';
      });
      pkg-config-unwrapped = prev.pkg-config-unwrapped.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          # Apply Nixpkgs' three Requires.private test exclusions to TESTS too.
          if [ ! -e check/check-requires-private ]; then
            substituteInPlace check/Makefile.in \
              --replace-fail "check-requires-private " "" \
              --replace-fail "check-gtk " "" \
              --replace-fail "check-missing " ""
          fi
        '';
      });
      gzip = prev.gzip.overrideAttrs (old: {
        # Gzip's bundled gnulib predates OpenBSD's opaque FILE type.
        patches = (old.patches or [ ]) ++ [ ./gnulib-openbsd-fseeko.patch ];
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
                  rsync = prev.rsync.override { python3 = final.python3Minimal; };
                  stdenvNoLibc = prev.stdenvNoLibc.override {
                    cc = prev.stdenvNoLibc.cc.override {
                      # libc and libexecinfo both link against the compiler builtins.
                      extraPackages = [ final.compilerRtBootstrap ];
                    };
                  };
                  openbsd = prev.openbsd.overrideScope (
                    _: old: {
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
    ];
}
