{
  flakeRef,
  system ? "x86_64-linux",
}:
let
  flake = builtins.getFlake flakeRef;
  template = (import (flake.templates.native-system.path + "/flake.nix")).outputs {
    nix-openbsd = flake;
  };
  configuration = template.nixosConfigurations.my-openbsd;
  images = template.packages.${system};
  display = configuration.extendModules {
    modules = [ { boot.loader.stand-openbsd.console = lib.mkForce "pc0"; } ];
  };
  noGetty = display.extendModules {
    modules = [ { services.getty.enabled = false; } ];
  };
  diskId = "0123456789abcdef";
  duidSystem = configuration.extendModules {
    modules = [
      {
        fileSystems."/".device = lib.mkForce "${diskId}.a";
        fileSystems."/boot/efi".device = lib.mkForce "${diskId}.i";
      }
    ];
  };
  duidImages = flake.lib.mkNativeImages {
    configuration = duidSystem;
    inherit system;
  };
  noAutoFsck = duidSystem.extendModules {
    modules = [ { system.boot.autoFsck = false; } ];
  };
  rejects =
    root: efi:
    !(builtins.tryEval (
      (flake.lib.mkNativeImages {
        inherit system;
        configuration = configuration.extendModules {
          modules = [
            {
              fileSystems."/".device = lib.mkForce root;
              fileSystems."/boot/efi".device = lib.mkForce efi;
            }
          ];
        };
      }).rawImage.name
    )).success;
  rootArgument = lib.escapeShellArg "${diskId}.a";
  ttys = display.config.environment.etc.ttys.text;
  inherit (flake.inputs.nixbsd.inputs.nixpkgs) lib;
  enabled =
    name: text: builtins.match ".*\n${name}[ \t]+[^\n]*[ \t]on[ \t]+secure\n.*" ("\n" + text) != null;
in
assert configuration.config.networking.hostName == "my-openbsd";
assert configuration.pkgs.stdenv.buildPlatform.system == "x86_64-openbsd";
assert !configuration.config.services.httpd.enable;
assert !configuration.config.services.relayd.enable;
assert configuration.config.boot.loader.stand-openbsd.console == "com0";
assert display.config.boot.loader.stand-openbsd.console == "pc0";
assert lib.all (name: enabled name ttys) [
  "ttyC0"
  "ttyC1"
  "ttyC2"
  "ttyC3"
  "ttyC5"
];
assert !enabled "console" ttys;
assert !enabled "ttyC4" ttys;
assert !enabled "tty00" ttys;
assert enabled "tty00" configuration.config.environment.etc.ttys.text;
assert !enabled "ttyC0" configuration.config.environment.etc.ttys.text;
assert noGetty.config.environment.etc.ttys.text == "";
assert images.native-raw-image.format == "raw";
assert images.native-raw-image.filename == "disk.img";
assert images.native-system-image.filename == "openbsd-native.qcow2";
assert duidImages.rawImage.format == "raw";
assert lib.hasInfix "fsck -y ${rootArgument}" duidSystem.config.system.activationScripts.script;
assert lib.hasInfix "mount -u -w ${rootArgument} /"
  duidSystem.config.system.activationScripts.script;
assert lib.hasInfix "mount -u -w ${rootArgument} /" duidSystem.config.system.dryActivationScript;
assert !(lib.hasInfix "/dev/sd0a" duidSystem.config.system.activationScripts.script);
assert lib.hasInfix "fsck  ${rootArgument}" noAutoFsck.config.system.activationScripts.script;
assert rejects "0000000000000000.a" "0000000000000000.i";
assert rejects "${diskId}.a" "fedcba9876543210.i";
assert rejects "${diskId}.b" "${diskId}.i";
assert rejects "/dev/sd1a" "/dev/sd1i";
assert rejects "${diskId}.a" "/dev/sd0i";
{
  passed = true;
  personalSystem = configuration.config.system.build.toplevel;
  image = images.native-system-image;
  rawImage = images.native-raw-image;
}
