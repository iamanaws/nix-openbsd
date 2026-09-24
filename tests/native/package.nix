{
  environment,
  packageSetSource ? ../../pkgs/openbsd/native-packages.nix,
  consumerSource,
  nonce,
  nixbsdSource ? null,
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
  tools = stdenv.openbsdBootstrap;
  toolsStage = stdenv.__bootPackages;
  fetchText = "native fetchurl ${nonce}\n";
  common = {
    strictDeps = true;
    preBuild = ''
      test "$EUID" -ne 0
      case "$CC" in /*) test -x "$CC";; *) command -v "$CC";; esac
      case ":$PATH:" in *:/bin:*|*:/usr/bin:*|*:/usr/local/bin:*) exit 1;; esac
      test "$BASH" = "${tools.bashNonInteractive}/bin/bash"
      test "$(command -v diff)" = "${tools.diffutils}/bin/diff"
      test "$(command -v find)" = "${tools.findutils}/bin/find"
      test "$(command -v grep)" = "${tools.gnugrep}/bin/grep"
      test "$(command -v awk)" = "${tools.gawk}/bin/awk"
      test "$(command -v tar)" = "${tools.gnutar}/bin/tar"
      test "$(command -v bzip2)" = "${lib.getBin tools.bzip2}/bin/bzip2"
      test "$(command -v patch)" = "${tools.patch}/bin/patch"
      test "$(command -v patchelf)" = "${tools.patchelf}/bin/patchelf"
      test "$(command -v sed)" = "${tools.gnused}/bin/sed"
      test "$(command -v gzip)" = "${tools.gzip}/bin/gzip"
      test "$(command -v file)" = "${tools.file}/bin/file"
      test "$(command -v xz)" = "${lib.getBin tools.xz}/bin/xz"
      for tool in cat cp mkdir rm sort stat sha256sum factor; do
        test "$(command -v "$tool")" = "${tools.coreutils}/bin/$tool"
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
      nativeBuildInputs = [
        tools.perl
        toolsStage.python3Minimal
      ];
      buildPhase = ''
        runHook preBuild
        test "$(command -v make)" = "${tools.gnumake}/bin/make"
        "${toolsStage.ncurses}/bin/tic" -V
        "${toolsStage.ncurses}/bin/infocmp" -A "${toolsStage.ncurses}/share/terminfo" xterm > /dev/null
        printf '#define _XOPEN_SOURCE 700\n#include <sys/types.h>\n#include <sys/stat.h>\n' \
          | "$CC" -std=c23 -Werror -x c -fsyntax-only -
        for compare in diff cmp; do
          if printf A | (printf B | "$compare" /dev/fd/5 - > /dev/null) 5<&0; then
            echo "$compare treated distinct pipes as the same file" >&2
            exit 1
          else
            test "$?" -eq 1
          fi
        done
        perl -MConfig -MTime::HiRes -Mthreads -MCompress::Raw::Zlib -e '
          die "wrong Perl platform" unless $Config{osname} eq "openbsd";
          die "wrong Perl compiler" unless $Config{cc} eq "cc";
          die "no subsecond stat" unless Time::HiRes::d_hires_stat();
          die "threads failed" unless threads->create(sub { 42 })->join == 42;
          die "zlib XS failed" unless Compress::Raw::Zlib::zlib_version();
          print "native Perl and XS modules passed\n";
        '
        test "$(command -v python3)" = "${toolsStage.python3Minimal}/bin/python3"
        python3 - <<'PY'
        import hashlib
        import locale
        import pathlib
        import subprocess
        import sys
        import tempfile

        assert sys.platform.startswith("openbsd")
        assert locale.setlocale(locale.LC_CTYPE, "C.UTF-8") == "C.UTF-8"
        assert locale.setlocale(locale.LC_CTYPE, "en_US.UTF-8") == "en_US.UTF-8"
        assert hashlib.sha256(b"native OpenBSD").hexdigest() == "eb259cb13a89b0eec25e9db3e2e7b8958fc3986106a574ab57a496dc1e0cd6f3"
        with tempfile.TemporaryDirectory() as work:
            path = pathlib.Path(work) / "data"
            path.write_text("native OpenBSD")
            assert path.read_text() == "native OpenBSD"
        assert subprocess.check_output(["sh", "-c", "printf native"]) == b"native"
        print("native Python runtime checks passed")
        PY
        "$CC" -Wall -Wextra -Werror ${builtins.toFile "hello.c" ''
          #include <stdio.h>
          #include <locale.h>
          #include <time.h>
          #include <wchar.h>
          #include <wctype.h>
          int main(void) {
            volatile time_t zero = 0, before_epoch = -432000;
            if (difftime(zero, before_epoch) != 432000) return 1;
            if (difftime(before_epoch, zero) != -432000) return 1;
            locale_t de = newlocale(LC_ALL_MASK, "de_DE", (locale_t)0);
            locale_t fr = newlocale(LC_ALL_MASK, "fr_FR", (locale_t)0);
            if (!de || !fr || de != fr) return 1;
            freelocale(de);
            freelocale(fr);
            if (!setlocale(LC_CTYPE, "C.UTF-8")) return 1;
            if (towupper(0x00e9) != 0x00c9) return 1;
            if (wcwidth(0x754c) != 2 || wcwidth(0x0301) != 0) return 1;
            return puts("native stdenv passed") < 0;
          }
        ''} -Wl,-rpath,"$out/unused" -o hello
        ./hello
        # Binary-wrapper builds do not get library paths from dependency hooks.
        printf 'int main(void) { return 0; }\n' \
          | env -i PATH="$PATH" "$CC" -x c - -o standalone-cc
        ./standalone-cc
        gzip -c hello > hello.gz
        gzip -dc hello.gz > hello-roundtrip
        cmp hello hello-roundtrip
        xz -c hello > hello.xz
        xz -dc hello.xz > hello-xz-roundtrip
        cmp hello hello-xz-roundtrip
        bzip2 -c hello > hello.bz2
        bzip2 -dc hello.bz2 > hello-bzip2-roundtrip
        cmp hello hello-bzip2-roundtrip
        mkdir archive
        tar -cf hello.tar hello
        tar -xf hello.tar -C archive
        cmp hello archive/hello
        test "$(find archive -type f -print0 | xargs -0 basename)" = hello
        printf 'before\n' > edit.txt
        printf '%s\n' '--- edit.txt' '+++ edit.txt' '@@ -1 +1 @@' '-before' '+after' \
          | patch -p0
        grep -Fx after edit.txt
        awk -i inplace '{ print toupper($0) }' edit.txt
        test "$(cat edit.txt)" = AFTER
        printf '%s\n' '-x c -fsyntax-only -DNATIVE_RESPONSE=42 -' > compile.rsp
        printf '_Static_assert(NATIVE_RESPONSE == 42, "response file");\n' \
          | "$CC" @compile.rsp
        cp hello hello-copy
        test "$(stat -c %s hello)" = "$(stat -c %s hello-copy)"
        sha256sum hello > hello.sha256
        sha256sum -c hello.sha256
        test "$(printf '2\n1\n2\n' | sort -nu)" = $'1\n2'
        test "$(factor 18446744073709551617)" = '18446744073709551617: 274177 67280421310721'
        "$READELF" -d ${tools.coreutils}/bin/coreutils | grep 'NEEDED.*libgmp.so'
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
  testPython = pkgs.nativeTestPython;
  toolchain = pkgs.nativeToolchain;
in
{
  inherit
    testPython
    stdenv
    smoke
    library
    pkgs
    toolchain
    ;
  nativeNix = import ./nix.nix {
    inherit pkgs;
    nixbsdSource = store nixbsdSource;
  };
  seedClosure =
    pkgs.runCommand "openbsd-native-seed-closure"
      {
        disallowedRequisites = lib.unique (
          lib.concatMap (
            p: builtins.filter (v: builtins.isString v && lib.hasPrefix "/nix/store/" v) (builtins.attrValues p)
          ) (builtins.attrValues seed)
        );
      }
      ''
        ln -s ${stdenv} "$out"
      '';
  fetched = stdenv.fetchurlBoot {
    url = "file://${builtins.toFile "native-fetch-source" fetchText}";
    sha256 = builtins.hashString "sha256" fetchText;
  };
  noLibc = pkgs.mkStdenvNoLibs stdenv;
  toolchainChecks = import ./toolchain-checks.nix {
    inherit
      stdenv
      lib
      nonce
      toolchain
      ;
    compiler-rt = stdenv.openbsdBootstrap.compiler-rt;
  };
  cxxChecks = import ./cxx-checks.nix {
    libcxx = stdenv.cc.libcxx;
    llvmSrc = pkgs.llvmPackages.llvm.monorepoSrc;
    python3 = testPython;
  };
  libraries = import ./libraries.nix {
    inherit stdenv lib nonce;
    compiler-rt = stdenv.openbsdBootstrap.compiler-rt;
  };
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
