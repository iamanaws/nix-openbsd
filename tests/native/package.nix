{
  environment,
  packageSetSource ? ../../pkgs/openbsd/native-packages.nix,
  consumerSource,
  nonce,
}:
let
  # JSON drops string contexts; restore references to the bootstrap store paths.
  env = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile environment));
  store = builtins.storePath;
  nixpkgs = store env.nixpkgs;
  lib = import (nixpkgs + "/lib");
  seed = lib.mapAttrsRecursive (
    _: value:
    if builtins.isString value && lib.hasPrefix "/nix/store/" value then store value else value
  ) env.bootstrap;
  bootstrap = lib.mapAttrs (
    _: p:
    removeAttrs p [ "path" ]
    // {
      type = "derivation";
      outPath = p.path;
    }
  ) seed;
  pkgs = import packageSetSource { inherit nixpkgs bootstrap; };
  inherit (pkgs) stdenv;
  toolsStage = stdenv.__bootPackages;
  fetchText = "native fetchurl ${nonce}\n";
  common = {
    strictDeps = true;
    preBuild = ''
      test "$EUID" -ne 0
      case "$CC" in /*) test -x "$CC";; *) command -v "$CC";; esac
      case ":$PATH:" in *:/bin:*|*:/usr/bin:*|*:/usr/local/bin:*) exit 1;; esac
      test "$BASH" = "${toolsStage.bashNative}/bin/bash"
      test "$(command -v sed)" = "${toolsStage.gnused}/bin/sed"
      test "$(command -v gzip)" = "${toolsStage.gzip}/bin/gzip"
      test "$(command -v file)" = "${toolsStage.file}/bin/file"
      test "$(command -v xz)" = "${lib.getBin toolsStage.xz}/bin/xz"
      for tool in cat cp mkdir rm sort stat sha256sum factor; do
        test "$(command -v "$tool")" = "${toolsStage.coreutilsNative}/bin/$tool"
      done
    '';
    postInstall = ''
      echo "$EUID" > "$out/build-uid"
    '';
  };
  smoke = stdenv.mkDerivation (
    common
    // {
      name = "stdenv-smoke-${nonce}";
      dontUnpack = true;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        test "$(command -v make)" = "${toolsStage.gnumake}/bin/make"
        "$CC" -Wall -Wextra -Werror ${builtins.toFile "hello.c" ''
          #include <stdio.h>
          #include <locale.h>
          int main(void) {
            locale_t de = newlocale(LC_ALL_MASK, "de_DE", (locale_t)0);
            locale_t fr = newlocale(LC_ALL_MASK, "fr_FR", (locale_t)0);
            if (!de || !fr || de != fr) return 1;
            freelocale(de);
            freelocale(fr);
            return puts("native stdenv passed") < 0;
          }
        ''} -Wl,-rpath,"$out/unused" -o hello
        ./hello
        gzip -c hello > hello.gz
        gzip -dc hello.gz > hello-roundtrip
        cmp hello hello-roundtrip
        xz -c hello > hello.xz
        xz -dc hello.xz > hello-xz-roundtrip
        cmp hello hello-xz-roundtrip
        cp hello hello-copy
        test "$(stat -c %s hello)" = "$(stat -c %s hello-copy)"
        sha256sum hello > hello.sha256
        sha256sum -c hello.sha256
        test "$(printf '2\n1\n2\n' | sort -nu)" = $'1\n2'
        test "$(factor 18446744073709551617)" = '18446744073709551617: 274177 67280421310721'
        "$READELF" -d ${toolsStage.coreutilsNative}/bin/coreutils | grep 'NEEDED.*libgmp.so'
        "$CXX" -Wall -Wextra -Werror ${builtins.toFile "hello.cc" ''
          #include <iostream>
          int main() { std::cout << "native C++ stdenv passed\n"; }
        ''} -o hello-cxx
        ./hello-cxx
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        install -Dm755 hello "$out/bin/hello"
        install -Dm755 hello-cxx "$out/bin/hello-cxx"
        runHook postInstall
      '';
      preFixup = ''
        patchelf --print-rpath "$out/bin/hello" | grep -F "$out/unused"
      '';
      postFixup = ''
        if patchelf --print-rpath "$out/bin/hello" | grep -F "$out/unused"; then
          echo 'Unused RPATH was not removed' >&2
          exit 1
        fi
      '';
    }
  );
  library = stdenv.mkDerivation (
    common
    // {
      name = "libagentx-native-${nonce}";
      src = store env.source;
      nativeBuildInputs = [
        (nixpkgs + "/pkgs/os-specific/bsd/setup-hook.sh")
        (nixpkgs + "/pkgs/os-specific/bsd/openbsd/pkgs/openbsdSetupHook/setup-hook.sh")
        (store env.make)
      ]
      ++ map store env.bsdTools;
      COMPONENT_PATH = env.path;
      MACHINE = "amd64";
      MACHINE_ARCH = "amd64";
      MACHINE_CPU = "amd64";
      HOST_SH = stdenv.shell;
      CPP = "cpp";
      makeFlags = [ "NOPROFILE=yes" ];
      # OpenBSD appends the section number; openbsdSetupHook omits the final /man.
      preConfigure = ''
        makeFlagsArray+=("MANDIR=$out/share/man/man")
      '';
      preInstall = env.preInstall;
      postFixup = ''
        test -s "$out/include/agentx.h"
        test -s "$out/lib/libagentx.a"
        test -s "$out/lib/libagentx.so.1.1"
        test -L "$out/lib/libagentx.so"
        test -s "$out/share/man/man3/agentx.3.gz"
      '';
    }
  );
in
{
  inherit
    stdenv
    smoke
    library
    pkgs
    ;
  fetched = stdenv.fetchurlBoot {
    url = "file://${builtins.toFile "native-fetch-source" fetchText}";
    sha256 = builtins.hashString "sha256" fetchText;
  };
  noLibc = pkgs.mkStdenvNoLibs stdenv;
  consumer = stdenv.mkDerivation (
    common
    // {
      name = "libagentx-consumer-${nonce}";
      dontUnpack = true;
      dontConfigure = true;
      buildInputs = [ library ];
      buildPhase = ''
        runHook preBuild
        "$CC" -Wall -Wextra -Werror ${store consumerSource} -lagentx -o agentx-shared
        "$CC" -Wall -Wextra -Werror ${store consumerSource} \
          ${library}/lib/libagentx.a -o agentx-archive
        "$READELF" -d agentx-shared | grep 'NEEDED.*libagentx.so.1.1'
        if "$READELF" -d agentx-archive | grep 'NEEDED.*libagentx'; then
          echo 'Archive consumer unexpectedly depends on shared libagentx' >&2
          exit 1
        fi
        ./agentx-shared
        ./agentx-archive
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        install -Dm755 agentx-shared "$out/bin/agentx-shared"
        install -Dm755 agentx-archive "$out/bin/agentx-archive"
        runHook postInstall
      '';
    }
  );
}
