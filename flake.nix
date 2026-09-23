{
  description = "OpenBSD packages, NixBSD modules and a work-in-progress native stdenv";

  nixConfig = {
    extra-substituters = [ "https://nix-openbsd.cachix.org" ];
    extra-trusted-public-keys = [
      "nix-openbsd.cachix.org-1:IbN25q8l3NyIq8L16AWaJ1MNTxZRiYdzO5eYFQv1J+4="
    ];
  };

  inputs = {
    nixbsd.url = "path:/home/iamanaws/repos/nix-bsd/nixbsd";
  };

  outputs =
    { self, nixbsd, ... }:
    let
      system = "x86_64-linux";

      openbsdBase = nixbsd.nixosConfigurations.openbsd-base.extendModules {
        modules = [
          ./modules/system/openbsd.nix
          {
            nixpkgs.buildPlatform = system;
          }
        ];
      };

      openbsdWebserver = openbsdBase.extendModules {
        modules = [
          (
            { lib, pkgs, ... }:
            {
              imports = [
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

              nixpkgs.overlays = [ (import ./overlays/openbsd.nix) ];
              environment.systemPackages = [ pkgs.openbsd.netstat ];
              fonts.fontconfig.enable = false;
              systemd.tmpfiles.rules = [
                "d /var/authpf 0700 root wheel - -"
                "d /var/db 0755 root wheel - -"
                "f /var/db/host.random 0600 root wheel - -"
              ];
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
        minimal-vm = openbsdBase.config.system.build.vm;
        vm = openbsdWebserver.config.system.build.vm;
        system-image = openbsdWebserver.config.system.build.systemImage;
        toplevel = openbsdWebserver.config.system.build.toplevel;
      };
    };
}
