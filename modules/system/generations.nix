{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.openbsd.system;
  services = config.openbsd.rc.services;
  policies = {
    tempfiles = { };
    httpd = {
      files = [ "httpd.conf" ];
      check = "${config.services.httpd.package}/bin/httpd -n -f \"$target/etc/httpd.conf\"";
    };
    relayd = {
      files = [ "relayd.conf" ];
      check = "${config.services.relayd.package}/bin/relayd -n -f \"$target/etc/relayd.conf\"";
    };
  }
  // lib.optionalAttrs (config.services.cron.enable or false) {
    cron = {
      files = [ "crontab" ];
      check = lib.optionalString (
        config.services.cron.controlPackage != null
      ) "${config.services.cron.controlPackage}/bin/cronctl check \"$target/etc/crontab\"";
      reload = true;
    };
  }
  // lib.optionalAttrs (config.services.ntpd.enable or false) {
    ntpd = {
      files = [ "ntpd.conf" ];
      check = "${config.services.ntpd.package}/bin/ntpd -n -f \"$target/etc/ntpd.conf\"";
    };
  }
  // lib.optionalAttrs (config.services.resolvd.enable or false) {
    resolvd = {
      files = [ "resolv.conf.resolvd" ];
      reload = true;
    };
  }
  // lib.optionalAttrs (config.services.unwind.enable or false) {
    unwind = {
      files = [ "unwind.conf" ];
      check = "${config.services.unwind.package}/bin/unwind -n -f \"$target/etc/unwind.conf\"";
      reload = true;
    };
  }
  // cfg.services;
  metadata = pkgs.writeText "openbsd-system.json" (
    builtins.toJSON {
      version = 1;
      etc = lib.mapAttrs (_: entry: toString entry.source) (
        lib.filterAttrs (_: entry: entry.enable) config.environment.etc
      );
      services = lib.mapAttrs' (
        _: service:
        lib.nameValuePair service.name (
          {
            inherit (service) name before after;
            script = toString config.environment.etc."rc.d/${service.name}".source;
            flags = config.openbsd.rc.conf."${service.name}_flags" or "";
            live = builtins.hasAttr service.name policies;
            files = policies.${service.name}.files or [ ];
            check = policies.${service.name}.check or "";
          }
          // lib.optionalAttrs (policies.${service.name}.reload or false) { reload = true; }
        )
      ) services;
      # These settings affect boot or connectivity and are not live-switchable yet.
      boot = {
        fileSystems = lib.mapAttrs (_: fs: { inherit (fs) device fsType options; }) config.fileSystems;
        rc = builtins.removeAttrs config.openbsd.rc.conf (
          map (s: "${s.name}_flags") (builtins.attrValues services)
        );
      };
    }
  );
  live = pkgs.writeText "openbsd-live.sh" (builtins.readFile ./live.sh);
  rebuild = pkgs.writeShellScriptBin "openbsd-rebuild" (
    ''
      export PATH=${
        lib.makeBinPath [
          config.nix.package
          pkgs.coreutils
        ]
      }:$PATH
      generation_manager=${manager}
    ''
    + builtins.readFile ./rebuild.sh
  );
  manager = pkgs.writeShellScript "openbsd-generation-manager" (
    ''
      source ${live}
      export PATH=${
        lib.makeBinPath [
          config.nix.package
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.findutils
          pkgs.jq
          pkgs.less
        ]
      }
    ''
    + builtins.readFile ./generations.sh
  );
in
{
  options.openbsd.system.services = lib.mkOption {
    default = { };
    description = "Additional services that can safely be restarted during live activation.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          files = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Paths below /etc whose changes require restarting the service.";
          };
          check = lib.mkOption {
            type = lib.types.lines;
            default = "";
            description = "Read-only configuration check; $target is the new system store path.";
          };
          reload = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Reload through rc.d when only configuration files change.";
          };
        };
      }
    );
  };
  config = {
    environment.systemPackages = [ rebuild ];
    system.systemBuilderCommands = ''
      mkdir -p $out/bin
      ln -s ${metadata} $out/openbsd-system.json
      cat > $out/bin/switch-to-configuration <<EOF
      #!${pkgs.runtimeShell}
      test "\$#" = 1 || exit 1
      case "\$1" in boot|test|switch|dry-activate) ;; *) exit 1 ;; esac
      exec ${manager} "\$1" "$out"
      EOF
      chmod +x $out/bin/switch-to-configuration
    '';
    # A failed live activation must return to the manager, not open an interactive shell.
    system.activatableSystemBuilderCommands = lib.mkAfter ''
      substituteInPlace $out/activate \
        --replace-fail 'bash -i' 'if [[ ''${REALINIT:-0} == 1 ]]; then bash -i; fi'
    '';
  };
}
