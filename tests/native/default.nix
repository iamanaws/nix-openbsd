{ nixbsd }:
let
  cores = 6;
  host = nixbsd.inputs.nixpkgs.legacyPackages.x86_64-linux;
  system = nixbsd.nixosConfigurations.openbsd-base.extendModules {
    modules = [
      ({ lib, pkgs, ... }: {
        nixpkgs.buildPlatform = "x86_64-linux";
        networking.hostName = lib.mkForce "native-packages";
        services.openssh.enable = lib.mkForce false;
        # GENERIC only uses one CPU, even when QEMU exposes more.
        boot.kernel.package = lib.mkForce (pkgs.openbsd.sys.override { baseConfig = "GENERIC.MP"; });
        environment.systemPackages = [ guestTest ];
        # OpenBSD libc loads UTF-8 character data from this fixed path.
        system.activationScripts.openbsdLocales = ''
          mkdir -p /usr/share/locale
          ln -sfnT ${locales}/share/locale/UTF-8 /usr/share/locale/UTF-8
        '';
        nix.settings = {
          max-jobs = 1;
          inherit cores;
        };
        virtualisation.vmVariant.virtualisation = {
          memorySize = 8192;
          inherit cores;
          # Leave room for LLVM sources, native outputs and large-file tests.
          rootSize = "64g";
          qemu.networkingOptions = lib.mkForce [ ];
        };
      })
    ];
  };
  pkgs = system.pkgs;
  locales = host.callPackage ../../pkgs/openbsd/locales.nix {
    inherit (pkgs.openbsd) source version;
  };
  libc = pkgs.openbsd.libc.override {
    libcMinimal = pkgs.openbsd.libcMinimal.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ../../pkgs/openbsd/libc-difftime.patch ];
      postInstall = (old.postInstall or "") + ''
        # Nixpkgs rewrites this private guard to "true", which becomes active in C23.
        substituteInPlace "$dev/include/sys/time.h" \
          --replace-fail 'defined(_STANDALONE) || true' \
            'defined(_STANDALONE) || defined (_LIBC)'
      '';
    });
  };
  # Preserve output selection and compiler metadata when passing seed packages to the guest.
  package =
    p:
    {
      inherit (p) name;
      pname = pkgs.lib.getName p;
      path = p.outPath;
      version = p.version or "";
      meta = pkgs.lib.optionalAttrs (p.meta ? mainProgram) { inherit (p.meta) mainProgram; };
    }
    // pkgs.lib.genAttrs (builtins.filter (
      output:
      builtins.elem output [
        "out"
        "bin"
        "dev"
        "lib"
      ]
    ) (p.outputs or [ "out" ])) (output: p.${output}.outPath)
    // pkgs.lib.filterAttrs (
      name: _:
      builtins.elem name [
        "isClang"
        "isLLVM"
        "isGNU"
        "langC"
        "langCC"
        "shellPath"
      ]
    ) p;
  recipe = import ../../pkgs/openbsd/libagentx.nix {
    inherit (pkgs) lib;
    mkDerivation = attrs: attrs;
  };
  source = (pkgs.openbsd.callPackage ../../pkgs/openbsd/libagentx.nix { }).src;
  # openbsd.makeMinimal uses buildPackages; this make must run in the guest.
  make = (pkgs.netbsd.makeMinimal.override { make-rules = pkgs.openbsd.make-rules; }).overrideAttrs {
    # Configure otherwise embeds the Linux sh found in the build environment.
    BSHELL = pkgs.runtimeShell;
  };
  environment = host.writeText "openbsd-native-environment.json" (
    builtins.toJSON {
      nixpkgs = nixbsd.inputs.nixpkgs.outPath;
      # Preload sources for the offline guest, without replacing package recipes.
      sources = map (p: p.src.outPath) [
        host.hello
        host.zlib
        host.pigz
        host.bashNonInteractive
        host.gnum4
        host.bison
        host.gnused
        host.gzip
        host.file
        host.coreutils
        host.diffutils
        host.findutils
        host.gnugrep
        host.pcre2
        host.gawk
        host.gnutar
        host.bzip2
        host.patch
        host.ed
        host.lzip
        host.patchelf
        host.gmp
        host.autoconf
        host.automake
        host.libtool
        host.texinfo
        host.gettext
        host.libiconvReal
        host.pkg-config-unwrapped
        host.gnumake
        host.xz
        host.perl
        host.python3Minimal
        host.curlMinimal
        host.openssl
        host.nghttp2
        host.libssh2
        host.libkrb5
        host.byacc
        host.c-aresMinimal
        host.libev
        host.libedit
        host.ncurses
        host.cmakeMinimal
        host.ninja
        host.re2c
        host.libuv
        host.libarchive
        host.libxml2
        host.expat
        host.zstd
        host.rsync
        host.rhash
        host.lz4
        host.lzo
        host.xxhash
        host.popt
        host.groff
        host.pax
        host.mandoc
        host.lndir
        host.which
      ];
      # compiler-rt's src is filtered with a native runCommand, not a fetcher.
      llvmSource = (host.llvmPackages.callPackage ({ monorepoSrc }: monorepoSrc) { }).outPath;
      bsdSources = [ host.netbsd.source.outPath pkgs.openbsd.source.outPath ];
      sourcePatches =
        host.bashNonInteractive.patches
        ++ host.libssh2.patches
        ++ host.libev.patches
        ++ host.lz4.patches
        ++ host.rsync.patches
        ++ host.openbsd.libcMinimal.patches
        ++ host.openbsd.make-rules.patches
        ++ host.openbsd.csu.patches
        # Includes the ENODATA fix also needed by OpenBSD's native Kerberos.
        ++ host.pkgsCross.x86_64-freebsd.krb5.patches;
      # Perl's postPatch replaces several bundled CPAN distributions.
      perlSources = host.perl.postPatch;
      # gnu-config embeds its two fetched scripts in unpackPhase rather than src.
      configScripts = host.gnu-config.unpackPhase;
      bootstrap = pkgs.lib.mapAttrs (_: package) {
        inherit (pkgs)
          bashNonInteractive
          coreutils
          diffutils
          findutils
          gnugrep
          gnused
          gawk
          gnumake
          gnutar
          gzip
          bzip2
          xz
          patch
          patchelf
          file
          curl
          expand-response-params
          ;
        inherit (pkgs.llvmPackages) libcxx compiler-rt libunwind;
        clang = pkgs.llvmPackages.clang-unwrapped;
        bintools = pkgs.llvmPackages.bintools-unwrapped;
        inherit libc;
      };
      make = make.outPath;
      bsdTools = map (p: p.outPath) [
        # OpenBSD provides fts; the NetBSD backport currently fails to compile.
        (pkgs.netbsd.install.override { fts = null; })
        pkgs.netbsd.tsort
        pkgs.openbsd.lorder
      ];
      inherit source;
      inherit (recipe) path preInstall;
    }
  );
  guestTest = pkgs.writeShellScriptBin "test-openbsd-native" ''
    export NATIVE_BUILD_CORES=${toString cores}
    export NATIVE_ENVIRONMENT=${environment}
    export NATIVE_RECIPE=${./.}/package.nix
    export NATIVE_PACKAGES=${../../pkgs/openbsd}/native-packages.nix
    export NATIVE_CONSUMER=${./consumer.c}
    ${builtins.readFile ./test.sh}
  '';
  vm = system.config.system.build.vm;
in
{
  inherit vm environment locales;
  test = host.writeShellScriptBin "test-openbsd-native" ''
    exec ${host.python3}/bin/python3 ${./run.py} ${vm}/bin/run-native-packages-vm
  '';
}
