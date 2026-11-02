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
{
  passed = true;
  personalSystem = configuration.config.system.build.toplevel;
  image = images.native-system-image;
  rawImage = images.native-raw-image;
}
