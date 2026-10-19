{ lib, pkgs, ... }:
{
  environment.systemPackages = [ pkgs.openbsd.localeData ];
  environment.pathsToLink = [ "/share/locale" ];
  environment.variables.LC_CTYPE = lib.mkDefault "en_US.UTF-8";

  # OpenBSD libc loads character data from this fixed path.
  system.activationScripts.openbsdLocale.text = ''
    if [ "''${NIXOS_ACTION:-}" != dry-activate ]; then
      mkdir -p /usr/share/locale/UTF-8
      ln -sfn /run/current-system/sw/share/locale/UTF-8/LC_CTYPE \
        /usr/share/locale/UTF-8/LC_CTYPE
    fi
  '';
}
