{
  nixbsd,
  cores ? 8,
  memorySize ? 16384,
}:
let
  host = nixbsd.inputs.nixpkgs.legacyPackages.x86_64-linux;
  system = nixbsd.nixosConfigurations.openbsd-base.extendModules {
    modules = [
      ../../modules/system/openbsd.nix
      (import ../../modules/system/nixpkgs.nix { inherit nixbsd; })
      ({ lib, pkgs, ... }: {
        nixpkgs.buildPlatform = "x86_64-linux";
        # The BSD image builder creates a temporary partition but reads the store copy.
        # Disable the unused copy to avoid building the same 64 GiB partition twice.
        nixpkgs.overlays = [
          (_: prev: {
            callPackage =
              path: args:
              let
                result = prev.callPackage path (
                  if
                    builtins.isPath path
                    && toString path == "${nixbsd.outPath}/lib/make-disk-image.nix"
                    && (args.partitionTableType or null) == "bsd"
                  then
                    args
                    // {
                      # This builder reads the store partition; skip its unused temporary copy.
                      partitions = map (part: part // { tooLargeIntermediate = false; }) args.partitions;
                    }
                  else
                    args
                );
              in
              if
                builtins.isPath path
                && toString path == "${nixbsd.outPath}/lib/make-partition-image.nix"
                && (args.filesystem or null) == "ufs"
              then
                result.overrideAttrs (old: {
                  # Keep unused filesystem space sparse, as in the native VM image.
                  buildCommand = builtins.replaceStrings [ "/bin/makefs " ] [ "/bin/makefs -Z " ] old.buildCommand;
                })
              else
                result;
          })
        ];
        networking.hostName = lib.mkForce "native-packages";
        networking.useDHCP = true;
        services.openssh.enable = lib.mkForce false;
        # GENERIC only uses one CPU, even when QEMU exposes more.
        boot.kernel.package = lib.mkForce (pkgs.openbsd.sys.override { baseConfig = "GENERIC.MP"; });
        environment.systemPackages = [ guestLauncher ];
        # OpenBSD libc loads UTF-8 character data from this fixed path.
        system.activationScripts.openbsdLocales = ''
          mkdir -p /usr/share/locale
          ln -sfnT ${locales}/share/locale/UTF-8 /usr/share/locale/UTF-8
        '';
        nix.settings = {
          max-jobs = 1;
          inherit cores;
          fallback = true;
          substituters = lib.mkForce [
            "https://nix-openbsd.cachix.org"
            "https://cache.nixos.org"
          ];
          trusted-public-keys = [ "nix-openbsd.cachix.org-1:IbN25q8l3NyIq8L16AWaJ1MNTxZRiYdzO5eYFQv1J+4=" ];
        };
        virtualisation.vmVariant.virtualisation = {
          inherit cores memorySize;
          # Leave room for LLVM sources, native outputs and large-file tests.
          rootSize = "64g";
        };
      })
    ];
  };
  pkgs = system.pkgs;
  locales = host.callPackage ../../pkgs/openbsd/locales.nix {
    inherit (pkgs.openbsd) source version;
  };
  recipe = import ../../pkgs/openbsd/libagentx.nix {
    inherit (pkgs) lib;
    mkDerivation = attrs: attrs;
  };
  source = (pkgs.openbsd.callPackage ../../pkgs/openbsd/libagentx.nix { }).src;
  projectSource = host.nix-gitignore.gitignoreSource [ ] ../..;
  # openbsd.makeMinimal uses buildPackages; this make must run in the guest.
  make = (pkgs.netbsd.makeMinimal.override { make-rules = pkgs.openbsd.make-rules; }).overrideAttrs {
    # Configure otherwise embeds the Linux sh found in the build environment.
    BSHELL = pkgs.runtimeShell;
  };
  environment = host.writeText "openbsd-native-environment.json" (
    builtins.toJSON {
      nixpkgs = nixbsd.inputs.nixpkgs.outPath;
      # Import sources with the recipes so guest builds can run without internet access.
      sources =
        map (p: p.src.outPath) [
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
          host.libffi
          host.tcl
          host.expect
          host.dejagnu
          host.python3Packages.build
          host.python3Packages.calver
          host.python3Packages.editables
          host.python3Packages.flit-core
          host.python3Packages.hatchling
          host.python3Packages.iniconfig
          host.python3Packages.installer
          host.python3Packages.packaging
          host.python3Packages.pathspec
          host.python3Packages.pluggy
          host.python3Packages.psutil
          host.python3Packages.pygments
          host.python3Packages.pyproject-hooks
          host.python3Packages.pytest
          host.python3Packages.setuptools
          host.python3Packages.setuptools-scm
          host.python3Packages.tomli
          host.python3Packages.trove-classifiers
          host.python3Packages.vcs-versioning
          host.python3Packages.wheel
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
        ]
        ++ map (src: src.outPath) host.tzdata.srcs;
      # compiler-rt's src is filtered with a native runCommand, not a fetcher.
      llvmSource = (host.llvmPackages.callPackage ({ monorepoSrc }: monorepoSrc) { }).outPath;
      bsdSources = [
        host.netbsd.source.outPath
        pkgs.openbsd.source.outPath
      ];
      sourcePatches =
        host.bashNonInteractive.patches
        ++ host.libssh2.patches
        ++ host.libev.patches
        ++ host.lz4.patches
        ++ host.rsync.patches
        ++ host.expect.patches
        ++ host.openbsd.libcMinimal.patches
        ++ host.openbsd.make-rules.patches
        ++ host.openbsd.csu.patches
        # Includes the ENODATA fix also needed by OpenBSD's native Kerberos.
        ++ host.pkgsCross.x86_64-freebsd.krb5.patches;
      # Perl's postPatch replaces several bundled CPAN distributions.
      perlSources = host.perl.postPatch;
      # gnu-config embeds its two fetched scripts in unpackPhase rather than src.
      configScripts = host.gnu-config.unpackPhase;
      bootstrap = import ../../pkgs/openbsd/native-bootstrap.nix { inherit pkgs; };
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
  guestLauncher = pkgs.writeShellScriptBin "test-openbsd-native" ''
    exec /var/lib/native-test/bin/test-openbsd-native "$@"
  '';
  guestTest = pkgs.writeShellScriptBin "test-openbsd-native" ''
    export NATIVE_NIXBSD=${nixbsd.outPath}
    export NATIVE_BUILD_CORES=${toString cores}
    export NATIVE_ENVIRONMENT=${environment}
    export NATIVE_RECIPE=${projectSource}/tests/native/package.nix
    export NATIVE_PACKAGES=${projectSource}/pkgs/openbsd/native-packages.nix
    export NATIVE_CONSUMER=${projectSource}/tests/native/consumer.c
    export NATIVE_PROJECT=${projectSource}
    ${builtins.readFile ./test.sh}
  '';
  vm = system.config.system.build.vm;
in
{
  inherit
    vm
    environment
    locales
    guestTest
    ;
  test = host.writeShellScriptBin "test-openbsd-native" ''
    export PATH=${host.nix}/bin:$PATH
    exec ${host.python3}/bin/python3 ${./run.py} ${vm}/bin/run-native-packages-vm ${guestTest} "$@"
  '';
}
