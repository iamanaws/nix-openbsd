{
  flakeRef ? "path:" + toString ../..,
  flake ? builtins.getFlake flakeRef,
}:
let
  inherit (flake.inputs.nixbsd.inputs.nixpkgs) lib;
  base = flake.nixosConfigurations.openbsd-native;
  pkgs = base.pkgs;
  lan4 = number: if number == 1 then "198.51.100" else "203.0.113";
  rules = protected: ''
    set skip on lo
    block drop
    pass quick on { pair0 pair1 } no state
    block drop quick on { vio1 enc0 } proto udp to port 9001 label "blocked_udp"
    # Keep the routing and IKE control traffic independent of payload states.
    pass on vio1 inet from 192.0.2.0/24 to 192.0.2.0/24 no state
    pass on vio1 inet6 from { 2001:db8:0::/64 fe80::/10 } to any no state
    ${
      if protected then
        ''
          block drop quick on vio1 inet from { 198.51.100.0/24 203.0.113.0/24 } to { 198.51.100.0/24 203.0.113.0/24 } label "cleartext_v4"
          block drop quick on vio1 inet6 from { 2001:db8:1::/64 2001:db8:2::/64 } to { 2001:db8:1::/64 2001:db8:2::/64 } label "cleartext_v6"
        ''
      else
        ''
          pass on vio1 inet from { 198.51.100.0/24 203.0.113.0/24 } to { 198.51.100.0/24 203.0.113.0/24 }
          pass on vio1 inet6 from { 2001:db8:1::/64 2001:db8:2::/64 } to { 2001:db8:1::/64 2001:db8:2::/64 }
        ''
    }
    pass on enc0 no state
  '';
  makePeer =
    number:
    let
      local = toString number;
      remote = toString (3 - number);
    in
    base.extendModules {
      modules = [
        ({ lib, pkgs, ... }: {
          networking.hostName = lib.mkOverride 40 "network-${local}";
          networking.domain = "test";
          networking.useDHCP = false;
          networking.useSLAAC = false;
          networking.interfaces = {
            vio0.ipv4.addresses = [
              {
                address = "10.0.2.15";
                prefixLength = 24;
              }
            ];
            vio1 = {
              ipv4.addresses = [
                {
                  address = "192.0.2.${local}";
                  prefixLength = 24;
                }
              ];
              ipv6.addresses = [
                {
                  address = "2001:db8:0::${local}";
                  prefixLength = 64;
                }
              ];
            };
            pair0 = {
              ipv4.addresses = [
                {
                  address = "${lan4 number}.1";
                  prefixLength = 24;
                }
              ];
              ipv6.addresses = [
                {
                  address = "2001:db8:${local}::1";
                  prefixLength = 64;
                }
              ];
            };
            pair1 = {
              ipv4.addresses = [
                {
                  address = "${lan4 number}.2";
                  prefixLength = 24;
                }
              ];
              ipv6.addresses = [
                {
                  address = "2001:db8:${local}::2";
                  prefixLength = 64;
                }
              ];
            };
          };
          # PF blocks this NAT fallback during the runtime tests.
          networking.defaultGateway =
            if number == 1 then
              {
                address = "10.0.2.2";
                interface = "vio0";
                metric = 42;
              }
            else
              "10.0.2.2";
          boot.kernel.sysctl = {
            "net.inet.ip.forwarding" = 1;
            "net.inet6.ip6.forwarding" = 1;
          };
          init.services.network_interfaces = {
            preStart = ''
              ${pkgs.openbsd.ifconfig}/bin/ifconfig pair0 >/dev/null 2>&1 || ${pkgs.openbsd.ifconfig}/bin/ifconfig pair0 create
              ${pkgs.openbsd.ifconfig}/bin/ifconfig pair1 >/dev/null 2>&1 || ${pkgs.openbsd.ifconfig}/bin/ifconfig pair1 create
              ${pkgs.openbsd.ifconfig}/bin/ifconfig pair1 rdomain 1
              ${pkgs.openbsd.ifconfig}/bin/ifconfig pair0 patch pair1
            '';
            postStart = ''
              ${pkgs.openbsd.route}/bin/route -T 1 -n add -inet default ${lan4 number}.1 ||
                ${pkgs.openbsd.route}/bin/route -T 1 -n change -inet default ${lan4 number}.1
              ${pkgs.openbsd.route}/bin/route -T 1 -n add -inet6 default 2001:db8:${local}::1 ||
                ${pkgs.openbsd.route}/bin/route -T 1 -n change -inet6 default 2001:db8:${local}::1
            '';
          };
          environment.systemPackages = [
            pkgs.python3
          ]
          ++ (with pkgs.openbsd; [
            ifconfig
            route
            ping
            ipsecctl
            tcpdump
            netstat
            pkill
          ]);
          # tcpdump uses OpenBSD's privilege separation account for the capture.
          users.users._tcpdump = {
            uid = 76;
            isSystemUser = true;
            group = "_tcpdump";
            home = "/var/empty";
          };
          users.groups._tcpdump.gid = 76;
          services = lib.mkMerge [
            (lib.genAttrs
              [
                "smtpd"
                "httpd"
                "relayd"
                "ntpd"
                "cron"
                "newsyslog"
                "sensorsd"
                "snmpd"
                "resolvd"
              ]
              (_: {
                enable = lib.mkForce false;
              })
            )
            {
              openssh.enable = lib.mkForce false;
              bgpd = {
                enable = true;
                config = ''
                  AS 6500${local}
                  router-id 192.0.2.${local}
                  listen on 192.0.2.${local}
                  listen on 2001:db8:0::${local}
                  holdtime 9
                  staletime 5
                  connect-retry 5
                  network ${lan4 number}.0/24
                  network 2001:db8:${local}::/64
                  neighbor 192.0.2.${remote} {
                    remote-as 6500${remote}
                    announce IPv4 unicast
                    announce IPv6 none
                  }
                  neighbor 2001:db8:0::${remote} {
                    remote-as 6500${remote}
                    announce IPv4 none
                    announce IPv6 unicast
                  }
                  allow from any
                  allow to any
                '';
              };
              iked = {
                enable = true;
                # Public test data, used only on the private guest-to-guest link.
                config = ''
                  set enforcesingleikesa
                  ikev2 "lan" ${if number == 1 then "active" else "passive"} esp \
                    from ${lan4 number}.0/24 to ${lan4 (3 - number)}.0/24 \
                    from 2001:db8:${local}::/64 to 2001:db8:${remote}::/64 \
                    local 192.0.2.${local} peer 192.0.2.${remote} \
                    srcid 192.0.2.${local} dstid 192.0.2.${remote} \
                    psk "isolated-vm-test-only"
                '';
              };
              pf = {
                enable = true;
                config = rules true;
              };
            }
          ];
        })
      ];
    };
  left = makePeer 1;
  right = makePeer 2;
in
assert left.pkgs.stdenv.buildPlatform.isOpenBSD;
assert left.config.boot.kernel.sysctl."net.inet.ip.forwarding" == 1;
assert left.config.boot.kernel.sysctl."net.inet6.ip6.forwarding" == 1;
assert left.config.openbsd.rc.services.bgpd.hooks.rc_configtest != null;
assert left.config.openbsd.rc.services.iked.hooks.rc_configtest != null;
assert left.config.openbsd.rc.services.pf.hooks.rc_configtest != null;
assert left.config.openbsd.rc.services.pf.shellVariables.rc_reload == false;
assert !(left.config.init.services ? dhcpleased);
assert !(left.config.init.services ? slaacd);
assert left.config.system.build.toplevel.outPath != "";
assert right.config.system.build.toplevel.outPath != "";
{
  passed = true;
  inherit left right;
  all = pkgs.linkFarm "openbsd-network-tests" (
    [
      {
        name = "left";
        path = left.config.system.build.toplevel;
      }
      {
        name = "right";
        path = right.config.system.build.toplevel;
      }
      {
        name = "routed-pf";
        path = pkgs.writeText "network-routed-pf.conf" (rules false);
      }
      {
        name = "protected-pf";
        path = pkgs.writeText "network-protected-pf.conf" (rules true);
      }
    ]
    ++
      lib.concatMap
        (name: [
          {
            inherit name;
            path = pkgs.openbsd.${name};
          }
          {
            name = name + "-source";
            path = pkgs.openbsd.${name}.src;
          }
        ])
        [
          "bgpd"
          "bgpctl"
          "iked"
          "ikectl"
          "pfctl"
          "ipsecctl"
          "ping"
          "tcpdump"
        ]
  );
}
