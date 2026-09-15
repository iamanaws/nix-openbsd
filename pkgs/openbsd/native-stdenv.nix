# Seed a native OpenBSD stdenv with tools cross-built on Linux.
{
  nixpkgs,
  bootstrap,
  lib ? import (nixpkgs + "/lib"),
  config ? (lib.evalModules { modules = [ (nixpkgs + "/pkgs/top-level/config.nix") ]; }).config,
  localSystem ? "x86_64-openbsd",
}:
let
  platform = lib.systems.elaborate localSystem;
  genericStdenv = import (nixpkgs + "/pkgs/stdenv/generic") { defaultConfig = config; };
  common = {
    buildPlatform = platform;
    hostPlatform = platform;
    targetPlatform = platform;
    shell = "${bootstrap.bashNonInteractive}/bin/bash";
    initialPath = import (nixpkgs + "/pkgs/stdenv/generic/common-path.nix") { pkgs = bootstrap; };
    extraNativeBuildInputs = [
      bootstrap.patchelf
      ./fix-libtool.sh
    ];
    preHook = ''
      export NIX_ENFORCE_PURITY="''${NIX_ENFORCE_PURITY-1}"
      export NIX_ENFORCE_NO_NATIVE="''${NIX_ENFORCE_NO_NATIVE-1}"
      # OpenBSD uses fixed locale handles; gnulib's probe needs absent UTF-8 data.
      export gt_cv_locale_fake=yes
    '';
    inherit fetchurlBoot;
  };
  stdenvNoCC = genericStdenv (
    common
    // {
      name = "stdenv-openbsd-bootstrap-nocc";
      cc = null;
    }
  );
  fetchurlBoot = import (nixpkgs + "/pkgs/build-support/fetchurl") {
    inherit lib stdenvNoCC;
    inherit (bootstrap) curl;
    inherit (config) hashedMirrors rewriteURL;
  };
  wrapperArgs = {
    inherit lib stdenvNoCC;
    inherit (bootstrap)
      libc
      coreutils
      gnugrep
      expand-response-params
      ;
    runtimeShell = common.shell;
    nativeTools = false;
    nativeLibc = false;
    propagateDoc = false;
  };
  bintools = lib.makeOverridable (import (nixpkgs + "/pkgs/build-support/bintools-wrapper")) (
    wrapperArgs // { bintools = bootstrap.bintools; }
  );
  wrappedCC = lib.makeOverridable (import (nixpkgs + "/pkgs/build-support/cc-wrapper")) (
    wrapperArgs
    // {
      inherit bintools;
      cc = bootstrap.clang;
      libcxx = bootstrap.libcxx;
      isClang = true;
      extraPackages = [
        bootstrap.compiler-rt
        bootstrap.libunwind
      ];
      # Match llvmPackages.clangUseLLVM's runtime and resource-directory setup.
      nixSupport = {
        cc-cflags = [
          "-rtlib=compiler-rt"
          "-Wno-unused-command-line-argument"
          "-B${lib.getLib bootstrap.compiler-rt}/lib"
          "--unwindlib=libunwind"
          "-lunwind"
        ];
        cc-ldflags = [ "-L${lib.getLib bootstrap.libunwind}/lib" ];
      };
      extraBuildCommands = ''
        rsrc="$out/resource-root"
        mkdir "$rsrc"
        ln -s ${lib.getLib bootstrap.clang}/lib/clang/${lib.versions.major bootstrap.clang.version}/include "$rsrc/include"
        ln -s ${lib.getLib bootstrap.compiler-rt}/lib "$rsrc/lib"
        ln -s ${lib.getLib bootstrap.compiler-rt}/share "$rsrc/share"
        echo "-resource-dir=$rsrc" >> "$out/nix-support/cc-cflags"
      '';
    }
  );
  cc = wrappedCC.overrideAttrs (old: {
    passthru = old.passthru // {
      inherit (bootstrap) libunwind;
    };
  });
in
assert platform.isOpenBSD;
genericStdenv (
  common
  // {
    name = "stdenv-openbsd-bootstrap";
    inherit cc;
  }
)
