{
  description = "Basic NixBSD OpenBSD web server VM";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ufsNixpkgs.url =
      "github:obsidiansystems/bsd-nixpkgs/6af5d8f48e16d5fca6dfaa3d16f50d6e197b1f9c";
    nixbsd = {
      url = "github:obsidiansystems/nixbsd/openbsd-phase6";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixbsd, ufsNixpkgs, ... }:
    let
      system = "x86_64-linux";
      compatibleMakefs = (import ufsNixpkgs { inherit system; }).freebsd.makefs;

      openbsdWebserver = nixbsd.nixosConfigurations.openbsd-base.extendModules {
        modules = [
          (
            { lib, pkgs, ... }:
            {
              imports = [
                ./modules/compat/nixpkgs.nix
                ./modules/security/acme-client.nix
                ./modules/services/bgpd.nix
                ./modules/services/cron.nix
                ./modules/services/dhcpd.nix
                ./modules/services/httpd.nix
                ./modules/services/iked.nix
                ./modules/services/ipsec.nix
                ./modules/services/isakmpd.nix
                ./modules/services/newsyslog.nix
                ./modules/services/ntpd.nix
                ./modules/services/ospfd.nix
                ./modules/services/pf.nix
                ./modules/services/pflogd.nix
                ./modules/services/rad.nix
                ./modules/services/relayd.nix
                ./modules/services/resolvd.nix
                ./modules/services/ripd.nix
                ./modules/services/sensorsd.nix
                ./modules/services/snmpd.nix
                ./modules/services/syslogd.nix
                ./modules/services/unwind.nix
              ];

              nixpkgs.buildPlatform = system;
              nixpkgs.overlays = [
                (import ./overlays/openbsd.nix { inherit compatibleMakefs; })
              ];
              nixpkgs.overrideMiniTmpfiles = false;
              # This is a runnable VM rather than an offline installer, so it
              # does not need NixBSD's legacy cross-toolchain bundle.
              system.includeInstallerDependencies = false;
              # Current Nixpkgs' static OpenBSD clang bootstrap selects rcrt0
              # for CMake probes and cannot build NixBSD's static init default.
              system.init = pkgs.openbsd.init;
              environment.systemPackages = [ pkgs.openbsd.netstat ];
              fonts.fontconfig.enable = false;
              networking.hostName = lib.mkForce "openbsd-webserver";
              system.stateVersion = "25.05";

              services.cron.enable = true;

              services.newsyslog = {
                enable = true;
                config = ''
                  /var/cron/log		root:wheel	600  3     10   *     Z
                  /var/log/authlog	root:wheel	640  7     *    168   Z
                  /var/log/daemon			640  5     300  *     Z
                  /var/log/messages			644  5     300  *     Z
                  /var/log/secure			600  7     *    168   Z
                '';
              };

              services.syslogd = {
                enable = true;
                config = ''
                  *.notice;auth,authpriv,cron,ftp,kern,lpr,mail,user.none	/var/log/messages
                  kern.debug;syslog,user.info				/var/log/messages
                  auth.info						/var/log/authlog
                  authpriv.debug					/var/log/secure
                  cron.info						/var/cron/log
                  daemon.info						/var/log/daemon
                '';
              };

              services.sensorsd.enable = true;

              services.snmpd = {
                enable = true;
                config = ''
                  # Localhost-only SNMPv2c demonstration.
                  listen on 127.0.0.1 snmpv2c
                  read-only community public
                  system contact "nixbsd-demo"
                  system location "qemu"
                '';
              };

              services.ntpd = {
                enable = true;
                config = ''
                  servers pool.ntp.org
                '';
              };

              services.resolvd = {
                enable = true;
                config = ''
                  nameserver 10.0.2.3
                '';
              };

              services.pf = {
                enable = true;
                config = ''
                  set skip on lo
                  block return
                  pass
                '';
              };

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
          acme-client
          arp
          bgpctl
          bgpd
          cron
          crontab
          dhcpd
          doas
          httpd
          ikectl
          iked
          ipsecctl
          isakmpd
          libagentx
          libedit
          libkeynote
          libpcap
          libradius
          netstat
          newsyslog
          ntpctl
          ntpd
          ospfctl
          ospfd
          pfctl
          pflogd
          ping
          rad
          relayctl
          relayd
          resolvd
          ripctl
          ripd
          sensorsd
          snmp
          snmp_mibs
          snmpd
          snmpd_metrics
          syslogc
          syslogd
          tcpdump
          traceroute
          unwind
          w
          ;
        default = openbsdWebserver.config.system.build.vm;
        vm = openbsdWebserver.config.system.build.vm;
        system-image = openbsdWebserver.config.system.build.systemImage;
        toplevel = openbsdWebserver.config.system.build.toplevel;
      };
    };
}
