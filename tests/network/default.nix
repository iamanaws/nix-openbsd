{ flake }:
let
  makePeer =
    number:
    let
      local = toString number;
      remote = toString (3 - number);
      system = flake.inputs.nixbsd.nixosConfigurations.openbsd-base.extendModules {
        modules = [
          ({ lib, pkgs, ... }: {
            imports = [
              ../../modules/services/bgpd.nix
              ../../modules/services/iked.nix
              ../../modules/services/pf.nix
            ];
            nixpkgs.buildPlatform = "x86_64-linux";
            nixpkgs.overlays = [ (import ../../overlays/openbsd.nix) ];
            networking.hostName = lib.mkForce "network-${local}";
            networking.domain = "test";
            networking.useDHCP = false;
            networking.interfaces.vio0.ipv4.addresses = [
              {
                address = "192.0.2.${local}";
                prefixLength = 24;
              }
            ];
            networking.interfaces.lo0.ipv4.addresses = [
              {
                address = "198.51.100.${local}";
                prefixLength = 32;
              }
              # Not advertised by BGP, so the peer must use its default route.
              {
                address = "203.0.113.${local}";
                prefixLength = 32;
              }
            ];
            networking.defaultGateway =
              if number == 1 then
                {
                  address = "192.0.2.${remote}";
                  interface = "vio0";
                  metric = 42;
                }
              else
                "192.0.2.${remote}";
            services.openssh.enable = lib.mkForce false;
            environment.systemPackages = with pkgs.openbsd; [
              ifconfig
              route
              ping
              ipsecctl
              tcpdump
              netstat
            ];

            services.bgpd = {
              enable = true;
              config = ''
                AS 6500${local}
                router-id 192.0.2.${local}
                listen on 192.0.2.${local}
                network 198.51.100.${local}/32
                neighbor 192.0.2.${remote} {
                  remote-as 6500${remote}
                  announce IPv4 unicast
                }
                allow from any
                allow to any
              '';
            };
            services.iked = {
              enable = true;
              # Public test key, only used on the isolated guest-to-guest link.
              config = ''
                ikev2 "test" ${if number == 1 then "active" else "passive"} esp \
                  from 198.51.100.${local} to 198.51.100.${remote} \
                  local 192.0.2.${local} peer 192.0.2.${remote} \
                  srcid 192.0.2.${local} dstid 192.0.2.${remote} \
                  psk "isolated-vm-test-only"
              '';
            };
            services.pf = {
              enable = true;
              config = ''
                set skip on lo
                block return
                pass on vio0 proto { tcp udp esp icmp }
                pass on enc0
              '';
            };
            virtualisation.vmVariant.virtualisation = {
              graphics = false;
              memorySize = 768;
              cores = 1;
              # The driver supplies a private socket NIC, without NAT or host bridges.
              qemu.networkingOptions = lib.mkForce [ ];
            };
          })
        ];
      };
    in
    system.config.system.build.vm;
  left = makePeer 1;
  right = makePeer 2;
  host = flake.inputs.nixbsd.inputs.nixpkgs.legacyPackages.x86_64-linux;
in
{
  inherit left right;
  test = host.writeShellScriptBin "test-openbsd-network" ''
    exec ${host.python3}/bin/python3 ${./run.py} \
      ${left}/bin/run-network-1-vm ${right}/bin/run-network-2-vm
  '';
}
