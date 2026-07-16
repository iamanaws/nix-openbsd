{
  description = "Basic NixBSD OpenBSD web server VM";

  inputs.nixbsd.url = "github:obsidiansystems/nixbsd/openbsd-phase6";

  outputs =
    { self, nixbsd }:
    let
      system = "x86_64-linux";

      openbsdWebserver = nixbsd.nixosConfigurations.openbsd-base.extendModules {
        modules = [
          (
            { lib, ... }:
            {
              imports = [
                ./modules/services/httpd.nix
                ./modules/services/relayd.nix
              ];

              nixpkgs.buildPlatform = system;
              nixpkgs.overlays = [ (import ./overlays/openbsd.nix) ];
              networking.hostName = lib.mkForce "openbsd-webserver";
              system.stateVersion = "25.05";

              services.httpd = {
                enable = true;
                documentRoot = ./www;
                config = ''
                  server "default" {
                    listen on 127.0.0.1 port 8080
                    root "/htdocs"
                    log style combined
                  }
                '';
              };

              services.relayd = {
                enable = true;
                config = ''
                  table <webserver> { 127.0.0.1 }

                  http protocol "http" {
                    match request header append "X-Forwarded-For" value "$REMOTE_ADDR"
                  }

                  relay "www" {
                    listen on 0.0.0.0 port 80
                    protocol "http"
                    forward to <webserver> port 8080 check http "/" code 200
                  }
                '';
              };

              virtualisation.vmVariant = {
                virtualisation = {
                  graphics = false;
                  memorySize = 1024;
                  forwardPorts = [
                    {
                      from = "host";
                      host = {
                        address = "127.0.0.1";
                        port = 8080;
                      };
                      guest.port = 80;
                    }
                    {
                      from = "host";
                      host = {
                        address = "127.0.0.1";
                        port = 2222;
                      };
                      guest.port = 22;
                    }
                  ];
                };
              };
            }
          )
        ];
      };
    in
    {
      nixosConfigurations.openbsd-webserver = openbsdWebserver;

      packages.${system} = {
        inherit (openbsdWebserver.pkgs.openbsd)
          httpd
          libagentx
          relayctl
          relayd
          ;
        default = openbsdWebserver.config.system.build.vm;
        vm = openbsdWebserver.config.system.build.vm;
        system-image = openbsdWebserver.config.system.build.systemImage;
        toplevel = openbsdWebserver.config.system.build.toplevel;
      };
    };
}
