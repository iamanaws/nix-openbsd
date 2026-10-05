{ nixbsdSource, nixpkgsSource }:
let
  pkgs = import nixpkgsSource { system = "x86_64-linux"; };
  inherit (pkgs) lib;
  version =
    platform: revision:
    (pkgs.callPackages (nixbsdSource + "/modules/installer/tools/package.nix") {
      stdenv = pkgs.stdenv // {
        hostPlatform = lib.systems.elaborate platform;
      };
      configurationRevision = revision;
      # Capture the recipe's actual substitutions without building its dependencies.
      replaceVarsWith = args: args;
    }).nixos-version.replacements;
  service = postStart: {
    name = "probe";
    environment = { };
    description = "Startup probe";
    path = [ ];
    startCommand = [ "/test/daemon" ];
    startType = "foreground";
    directory = null;
    user = "root";
    stopSignal = "TERM";
    preStart = null;
    postStop = null;
    preStop = null;
    before = [ ];
    dependencies = [ ];
    inherit postStart;
  };
  evaluated = lib.evalModules {
    modules = [
      (nixbsdSource + "/modules/system/boot/init/portable/openbsd.nix")
      {
        config._module.args.pkgs = { };
        options.init.backend = lib.mkOption { type = lib.types.str; };
        options.init.services = lib.mkOption { type = lib.types.attrs; };
        options.openbsd.rc.services = lib.mkOption { type = lib.types.attrs; };
        config.init = {
          backend = "openbsd";
          services = {
            plain = service null;
            post = service ''
              printf 'post\n' >> "$TRACE"
              return "$POST_STATUS"
            '';
          };
        };
      }
    ];
  };
in
{
  versions = lib.genAttrs [ "x86_64-freebsd" "x86_64-openbsd" ] (platform: {
    known = version platform "abc123";
    unknown = version platform null;
  });
  hooks = lib.mapAttrs (_: service: service.hooks.rc_start) evaluated.config.openbsd.rc.services;
}
