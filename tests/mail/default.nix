{
  flakeRef ? "path:" + toString ../..,
}:
let
  flake = builtins.getFlake flakeRef;
  system = flake.nixosConfigurations.openbsd-native;
  cfg = system.config;
  disabled = system.extendModules {
    modules = [ ({ lib, ... }: { services.smtpd.enable = lib.mkForce false; }) ];
  };
in
assert cfg.services.smtpd.enable;
assert cfg.security.wrappers.sendmail.setgid;
assert cfg.security.wrappers.sendmail.group == "_smtpq";
assert cfg.security.wrappers.lockspool.setuid;
assert cfg.services.tempfiles.directories."/var/spool/smtpd/offline".mode == "0770";
assert cfg.services.tempfiles.directories."/var/spool/smtpd/queue".user == "_smtpq";
assert cfg.services.tempfiles.directories."/var/spool/smtpd/queue".group == "root";
assert builtins.match ".*listen on socket.*" cfg.services.smtpd.config != null;
assert cfg.environment.etc."mail/aliases".source != null;
assert cfg.init.services.smtpd.startType == "forking";
assert builtins.elem "suid_sgid_wrappers" cfg.init.services.smtpd.dependencies;
assert builtins.elem "smtpd" cfg.init.services.cron.dependencies;
assert !(disabled.config.security.wrappers ? sendmail);
assert !(disabled.config.security.wrappers ? lockspool);
assert !(disabled.config.init.services ? smtpd);
assert !(disabled.config.environment.etc ? "mail/smtpd.conf");
{
  passed = true;
}
