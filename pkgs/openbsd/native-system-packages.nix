{ nativeNix, nixbsdSource }:
let
  base = nativeNix.nativePackageSet;
in
import base.path {
  localSystem = "x86_64-openbsd";
  inherit (base) config;
  overlays = base.overlays ++ [
    (
      final: prev:
      let
        integration = import (nixbsdSource + "/overlays/openbsd.nix") final prev;
      in
      {
        # Keep the tested native libraries; reuse NixBSD's boot and login fixes.
        openssh = integration.openssh.overrideAttrs (old: {
          # Disabled regression tests still pull in libredirect, which needs sys/xattr.h.
          preCheck = if old.doCheck or false then old.preCheck else "";
        });
        openbsd = integration.openbsd.overrideScope (
          openbsdFinal: openbsdPrev: {
            boot-config = (openbsdPrev.boot-config.override { compatHook = null; }).overrideAttrs (old: {
              # Native OpenBSD supplies the libc interfaces emulated by the Linux hook.
              meta = old.meta // {
                platforms = prev.lib.platforms.openbsd;
              };
            });
            sys = (openbsdPrev.sys.override {
              # The upstream kernel recipe hardcodes Clang 18; use our tested compiler.
              buildPackages = final.buildPackages // {
                llvmPackages_18.clangNoLibc = (final.mkStdenvNoLibs final.stdenv).cc;
              };
            }).overrideAttrs (old: {
              # The kernel needs OpenBSD's linker features, provided by our native LLD.
              preBuild = old.preBuild + ''
                ln -sf ${final.stdenv.cc.bintools.bintools}/bin/ld.lld "$TMP/bin/ld"
              '';
              # Clang 21 checks that this logger uses the kernel's printf dialect.
              postPatch = (old.postPatch or "") + ''
                substituteInPlace sys/net/pipex_local.h \
                  --replace-fail '__format__(__printf__,3,4)' '__format__(__kprintf__,3,4)'
                # Only the address is used as a sleep identifier, but Clang 21 warns.
                substituteInPlace sys/scsi/scsi_base.c \
                  --replace-fail $'scsi_delay(struct scsi_xfer *xs, int seconds)\n{\n\tint ret;' \
                    $'scsi_delay(struct scsi_xfer *xs, int seconds)\n{\n\tint ret = 0;'
                # The sensor's first write must select its configuration register.
                substituteInPlace sys/dev/i2c/ad741x.c \
                  --replace-fail 'u_int8_t cmd, reg;' 'u_int8_t cmd = AD741X_CONFIG, reg;'
              '';
            });
          }
        );
        nix = nativeNix;
        gitMinimal = prev.gitMinimal.overrideAttrs (old: {
          # OpenBSD's regex implementation passes this upstream known-failure test.
          postPatch = (old.postPatch or "") + ''
            substituteInPlace t/t7815-grep-binary.sh \
              --replace-fail "test_expect_failure !CYGWIN,!MACOS 'git grep .fi a'" \
                "test_expect_success !CYGWIN,!MACOS 'git grep .fi a'"
          '';
        });
        libressl = prev.libressl.overrideAttrs (old: {
          # CMake's native OpenBSD probe returns an empty CPU in the build environment.
          postPatch = (old.postPatch or "") + ''
            substituteInPlace CMakeLists.txt \
              --replace-fail 'project(LibreSSL LANGUAGES C ASM)' \
                'project(LibreSSL LANGUAGES C ASM)
            set(CMAKE_SYSTEM_PROCESSOR "${final.stdenv.hostPlatform.parsed.cpu.name}")'
          '';
        });
        jq = prev.jq.overrideAttrs {
          # OpenBSD rejects TZ files outside /usr/share/zoneinfo; use equivalent rules.
          preInstallCheck = ''
            substituteInPlace tests/shtest \
              --replace-fail 'TZ=Asia/Tokyo' 'TZ=JST-9' \
              --replace-fail 'TZ=Europe/Paris' 'TZ=CET-1CEST,M3.5.0,M10.5.0/3' \
              --replace-fail 'TZ=Etc/GMT+7' 'TZ=GMT7'
          '';
        };
        # NixBSD passes the revision in JSON but omits the shell-script replacement.
        replaceVarsWith =
          args:
          prev.replaceVarsWith (
            args
            // prev.lib.optionalAttrs (args.name or "" == "nixos-version") {
              replacements = args.replacements // {
                configurationRevision = (builtins.fromJSON args.replacements.json).configurationRevision or null;
              };
            }
          );
        # New Python modules must inherit the tested interpreter's platform metadata.
        python3 = prev.python3.override {
          self = final.python3;
          __splices = prev.lib.genAttrs [
            "pythonOnBuildForBuild"
            "pythonOnBuildForHost"
            "pythonOnBuildForTarget"
            "pythonOnHostForHost"
            "pythonOnTargetForTarget"
          ] (_: final.python3);
        };
        python3Packages = final.python3.pkgs;
        flock = (prev.flock.override { ronn = null; }).overrideAttrs (old: {
          # Skip man-page generation, which otherwise pulls Ruby into the bootstrap.
          postPatch = (old.postPatch or "") + ''
            substituteInPlace Makefile.am --replace-fail 'man_MANS = man/flock.1' 'man_MANS ='
          '';
        });
      }
    )
    (import ../../overlays/openbsd.nix)
  ];
  stdenvStages = { config, overlays, ... }: [
    (_: {
      inherit config overlays;
      inherit (base) stdenv;
    })
  ];
}
