# NixBSD OpenBSD web server

This flake builds an experimental NixBSD OpenBSD VM running the native
OpenBSD `httpd(8)` and `relayd(8)` daemons. The request path is:

```text
host 127.0.0.1:8080 -> guest relayd :80 -> guest httpd 127.0.0.1:8080
```

The flake extends NixBSD's `openbsd-base`, inheriting its nixpkgs pin and
boot/runtime fixes. Extra packages and services remain here. The OpenBSD
programs use the upstream `pkgs.openbsd.mkDerivation` conventions:

- Base utilities: `arp`, `cron`, `crontab`, `doas`, `netstat`, `ping`,
  `traceroute`, and `w`
- Libraries: `libagentx`, `libedit`, `libkeynote`, `libpcap`, and `libradius`
- Networking: `dhcpd`, `httpd`, `ntpd`/`ntpctl`, `pflogd`, `rad`, `relayd`,
  `relayctl`, `resolvd`, `tcpdump`, and `unwind`
- Routing: `bgpd`/`bgpctl`, `ospfd`/`ospfctl`, and `ripd`/`ripctl`; the
  upstream `pkgs.openbsd.pfctl` package is reused directly
- Security and VPN: `acme-client`, `iked`, `ikectl`, `ipsecctl`, and `isakmpd`
- Observability: patched `syslogd`, reused `newsyslog`, plus `syslogc`,
  `snmpd`/`snmpd_metrics`/`snmp_mibs`/`snmp`, and `sensorsd`. OpenBSD 7.9
  uses `snmp(1)` rather than the removed `snmpctl`.

Local NixBSD modules provide `services.cron`, `services.dhcpd`,
`services.httpd`, `services.ntpd`, `services.pflogd`, `services.rad`,
`services.relayd`, `services.resolvd`, `services.unwind`, `services.iked`,
`services.isakmpd`, `services.ipsec`, `services.pf`, `services.bgpd`,
`services.ospfd`, `services.ripd`, `services.syslogd`, `services.newsyslog`,
`services.snmpd`, and `services.sensorsd`. `security.acme-client` adds
cron-backed certificate renewal without treating the client as a daemon. The
modules declare the standard OpenBSD users, protected directories,
configuration checks where the native program supports them, and rc services.
The demo enables cron, newsyslog, syslogd, sensorsd, localhost-only snmpd,
ntpd, resolvd, PF, httpd, and relayd; dynamic routing, forwarding, VPN, and
public ACME operations remain disabled.

## Run the VM

Enable flakes if they are not already enabled:

```sh
export NIX_CONFIG='experimental-features = nix-command flakes'
```

Build the VM runner:

```sh
nix build --accept-flake-config .#vm
```

The native daemon packages are not yet in the NixBSD cache, so Nix must
cross-compile them for OpenBSD. The rest of the VM may be downloaded from the
upstream cache; review that cache before accepting the flake configuration.

Start the VM:

```sh
./result/bin/run-openbsd-webserver-vm
```

In another terminal, wait for the guest to finish booting and then test it:

```sh
curl http://127.0.0.1:8080/
```

Inside the guest, inspect relayd with:

```sh
relayctl show summary
ntpctl -s status
pfctl -nf /etc/pf.conf
pfctl -sr
newsyslog -n -v -f /etc/newsyslog.conf
snmp walk -v 2c -c public 127.0.0.1 system
ps axww | grep -E '[c]ron|[n]tpd|[r]esolvd|[h]ttpd|[r]elayd|[s]yslogd|[s]nmpd|[s]ensorsd'
```

SSH is also forwarded to localhost port 2222:

```sh
ssh -p 2222 bestie@127.0.0.1
```

The inherited demonstration accounts are `root` and `bestie`; their
demonstration password is `toor`. Do not expose this VM or reuse those
credentials for a real machine.

VM state is stored in `openbsd-webserver.qcow2` in the current directory.
Delete that file to start again from a fresh disk image.

## Other outputs

Build the native OpenBSD packages individually:

```sh
nix build --accept-flake-config .#libagentx
nix build --accept-flake-config .#httpd
nix build --accept-flake-config .#relayd
nix build --accept-flake-config .#relayctl
```

## Observability modules

`services.newsyslog` is cron-backed rather than a daemon. It creates the log
files syslogd needs, installs an hourly rotation job, and runs a dry-run
`newsyslog -n` check at boot. `services.syslogd` starts early, removes a stale
`/dev/log`, and uses the OpenBSD `_syslogd` account.

```nix
{
  services.newsyslog = {
    enable = true;
    config = ''
      /var/log/messages			644  5     300  *     Z
      /var/log/daemon			640  5     300  *     Z
    '';
  };

  services.syslogd = {
    enable = true;
    config = ''
      *.notice;auth,authpriv,cron,ftp,kern,lpr,mail,user.none	/var/log/messages
      daemon.info						/var/log/daemon
    '';
  };
}
```

`services.snmpd` listens on localhost SNMPv2c in the demo and installs the
OpenBSD `snmp(1)` client. Do not confuse it with the removed `snmpctl`
utility. SNMP is not forwarded to the host.

```nix
{
  services.snmpd = {
    enable = true;
    config = ''
      listen on 127.0.0.1 snmpv2c
      read-only community public
    '';
  };
}
```

`services.sensorsd` runs as root with an optional `sensorsd.conf`. QEMU often
exposes few or no hardware sensors, so a quiet process with an empty config is
still a successful single-VM check.

## Routing and firewall modules

PF is kernel state loaded by `pfctl`, so `services.pf` is a one-shot service
rather than a daemon. The demo uses a permissive ruleset that preserves its
SSH and HTTP paths:

```nix
{
  services.pf = {
    enable = true;
    config = ''
      set skip on lo
      block return
      pass
    '';
  };
}
```

The routing daemons are disabled by default. Each module installs its matching
control tool and validates the configuration before startup. For example, a
no-peer BGP parser/process test can start with:

```nix
{
  services.bgpd = {
    enable = true;
    config = ''
      AS 64512
      router-id 192.0.2.1
      fib-update no
    '';
  };
}
```

`services.ospfd` provides IPv4 OSPFv2 and `services.ripd` provides RIP. None of
the modules enables packet forwarding. A machine intentionally acting as an
IPv4 router must opt in explicitly:

```nix
{
  boot.kernel.sysctl."net.inet.ip.forwarding" = 1;
}
```

Use explicit PF rules and routing protocol interface/neighbor policies before
enabling forwarding. Real BGP, OSPF, or RIP adjacency and route exchange
requires at least a second VM or peer; the single demo VM only supports safe
parser, process, socket, and local FIB inspection. `services.pflogd` is the
optional PF logging companion.

## Security and VPN modules

An IKEv2 host can enable `services.iked` and load a matching policy after the
daemon starts:

```nix
{
  services.iked = {
    enable = true;
    config = ''
      set passive
      # Add peer policies from iked.conf(5).
    '';
  };

  services.ipsec = {
    enable = true;
    ikeService = "iked";
    config = ''
      # Add flows from ipsec.conf(5).
    '';
  };
}
```

`services.isakmpd` provides the legacy IKEv1 alternative. Its `-n` flag means
"do not alter kernel SAs", not config-test mode, so that module cannot perform
the parser-only pre-start validation used by `iked` and `ipsecctl`.

ACME renewal is configured with domain handles from `acme-client.conf`:

```nix
{
  security.acme-client = {
    enable = true;
    domains = [ "example.com" ];
    reloadHttpd = true;
    config = ''
      # Add an authority and a domain block; test with a staging authority first.
    '';
  };
}
```

The module validates the file at boot and renews through
`services.cron.systemCronJobs`. Real issuance needs public HTTP-01 reachability
and should first use an ACME staging endpoint. End-to-end IPsec testing needs a
second peer; the single VM is only suitable for parser, permission, process,
and control-socket checks.

Build the installable system image:

```sh
nix build --accept-flake-config .#system-image
```

Build only the configured system closure:

```sh
nix build --accept-flake-config .#toplevel
```

## Deferred work

- Live configuration switching: NixBSD's `switch-to-configuration.sh` still
  invokes `@rcorder@`, but that path is substituted only for FreeBSD. Review
  OpenBSD service ordering and `check` versus `status` handling before testing
  `switch`/`test`, service restarts, and rollback in a disposable VM. Boot/login
  smoke tests do not cover this.
- Raw `disk.img` export: consider an optional output converting the existing
  system image with build-host `qemu-img`, as in the
  [Obsidian phase6 follow-up](https://github.com/nix-community/nixbsd/compare/openbsd-phase6...obsidiansystems:nixbsd:openbsd-phase6).
  This is useful for writing images to disks, not required for the QEMU boot
  path. Validate the exported partition layout and boot it before relying on it.

Recent native Nix support is being investigated separately; do not duplicate
that work here. The removed OpenBSD port used Nix 2.3.16
([removal commit](https://github.com/openbsd/ports/commit/7f027d386301a6844d1f4e054b0833943e6a33bd)).

## Upstreaming

The derivations under `pkgs/openbsd/` are intentionally shaped like files
under `pkgs/os-specific/bsd/openbsd/pkgs/` in nixpkgs. The service
modules follow NixBSD's `init.services` interface, which is converted to
generated OpenBSD `rc.d` scripts. This keeps the package and module changes
easy to split into separate upstream pull requests.

The intended observability split is: patched `syslogd` plus reused
`newsyslog`, `syslogc`, the SNMP stack (`snmp_mibs`, `snmpd_metrics`, `snmpd`,
`snmp`), `sensorsd`, then the OpenBSD-native logging/SNMP/sensors service
modules.
