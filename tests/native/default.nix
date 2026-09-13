{ nixbsd }:
let
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
        nix.settings = {
          max-jobs = 1;
          cores = 2;
        };
        virtualisation.vmVariant.virtualisation = {
          memorySize = 8192;
          cores = 4;
          rootSize = "16g";
          qemu.networkingOptions = lib.mkForce [ ];
        };
      })
    ];
  };
  pkgs = system.pkgs;
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
      ];
      sourcePatches = host.bashNonInteractive.patches;
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
          perl
          ;
        inherit (pkgs.llvmPackages) libcxx compiler-rt libunwind;
        clang = pkgs.llvmPackages.clang-unwrapped;
        bintools = pkgs.llvmPackages.bintools-unwrapped;
        libc = pkgs.llvmPackages.clang.libc;
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
    export NATIVE_ENVIRONMENT=${environment}
    export NATIVE_RECIPE=${./package.nix}
    export NATIVE_PACKAGES=${../../pkgs/openbsd}/native-packages.nix
    export NATIVE_CONSUMER=${./consumer.c}
    ${builtins.readFile ./test.sh}
  '';
  vm = system.config.system.build.vm;
in
{
  inherit vm environment;
  test = host.writeShellScriptBin "test-openbsd-native" ''
    exec ${host.python3}/bin/python3 ${./run.py} ${vm}/bin/run-native-packages-vm
  '';
}
