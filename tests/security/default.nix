{
  flakeRef ? "path:" + toString ../..,
}:
let
  flake = builtins.getFlake flakeRef;
  enabled = flake.nixosConfigurations.openbsd-native;
  disabled = enabled.extendModules {
    modules = [ ({ lib, ... }: { security.doas.enable = lib.mkForce false; }) ];
  };
  cfg = enabled.config;
in
assert cfg.security.doas.package.outPath == enabled.pkgs.openbsd.doas.outPath;
assert enabled.pkgs.buildPackages.doas.outPath == cfg.security.doas.package.outPath;
assert cfg.security.wrappers.doas.setuid;
assert cfg.security.wrappers.doas.owner == "root";
assert cfg.security.doas.wheelNeedsPassword;
assert cfg.environment.etc."doas.conf".mode == "0440";
assert cfg.init.services.doas-check.startType == "oneshot";
assert !(disabled.config.environment.etc ? "doas.conf");
assert !(disabled.config.security.wrappers ? doas);
assert !(disabled.config.init.services ? doas-check);
{
  passed = true;
}
