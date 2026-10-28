{
  flakeRef ? "path:" + toString ../..,
}:
let
  flake = builtins.getFlake flakeRef;
  base = flake.nixosConfigurations.openbsd-native;
  cfg = (base.extendModules { modules = [ { services.maintenance.enable = true; } ]; }).config;
in
assert !base.config.services.maintenance.enable;
assert !(base.config.environment.etc ? "daily");
assert cfg.services.maintenance.package.pname == "maintenance-scripts";
assert cfg.services.maintenance.package.dontBuild;
assert cfg.services.maintenance.daily.schedule == "30 1 * * *";
assert cfg.services.maintenance.weekly.schedule == "30 3 * * 6";
assert cfg.services.maintenance.monthly.schedule == "30 5 1 * *";
assert cfg.services.maintenance.weekly.config == "MAKEWHATISARGS=-n\n";
assert builtins.all
  (
    name:
    cfg.environment.etc."${name}.local".mode == "0600"
    && cfg.environment.etc."${name}.local".group == "root"
  )
  [
    "daily"
    "weekly"
    "monthly"
  ];
assert cfg.services.cron.enable && cfg.services.smtpd.enable;
{
  passed = true;
}
