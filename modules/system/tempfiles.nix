{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tempfiles;
  directories = pkgs.writeShellScript "service-directories" ''
    set -eu
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        path: dir:
        lib.escapeShellArgs [
          "${pkgs.coreutils}/bin/install"
          "-d"
          "-m"
          dir.mode
          "-o"
          dir.user
          "-g"
          dir.group
          "--"
          path
        ]
      ) cfg.directories
    )}
  '';
in
{
  options.services.tempfiles.directories = lib.mkOption {
    default = { };
    description = "Directories created at boot and activation. Existing contents are preserved.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          mode = lib.mkOption {
            type = lib.types.strMatching "[0-7]{3,4}";
            default = "0755";
            description = "Directory permissions in octal.";
          };
          user = lib.mkOption {
            type = lib.types.str;
            default = "root";
            description = "Directory owner.";
          };
          group = lib.mkOption {
            type = lib.types.str;
            default = "wheel";
            description = "Directory group.";
          };
        };
      }
    );
  };

  config = lib.mkIf pkgs.stdenv.hostPlatform.isOpenBSD {
    assertions = lib.mapAttrsToList (path: _: {
      assertion = lib.hasPrefix "/" path && !(lib.elem ".." (lib.splitString "/" path));
      message = "services.tempfiles.directories requires absolute paths without '..': ${path}";
    }) cfg.directories;

    # mtree can return success after failing to create a missing directory.
    init.services.tempfiles.postStart = "${directories}";
    openbsd.rc.services.tempfiles.hooks.rc_start = lib.mkForce ''
      rc_exec "''${daemon} ''${daemon_flags}" || return $?
      ${config.init.services.tempfiles.postStart}
    '';
    system.activationScripts.tempfiles = {
      deps = [
        "users"
        "groups"
        "etc"
      ];
      # rc.subr requires the service name from its rc.d symlink.
      text = ''
        # su unveils /var/run/dev.db before mtree creates /var/run.
        mkdir -p /var/run
        /etc/rc.d/tempfiles -f start
      '';
    };
  };
}
