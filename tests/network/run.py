"""Native dual-stack transit routing, PF and IKEv2 on two disposable OpenBSD VMs."""
import argparse
from contextlib import ExitStack
import json
from pathlib import Path
import shlex
import shutil
import socket
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guest import Guest, clone_state


def run(guest, script, timeout=240):
    helpers = '''
trap 'printf "%s\\n" "Network test failed: $BASH_COMMAND" >&2' ERR
wait_for() {
  for attempt in $(seq 1 "${2:-60}"); do
    if eval "$1"; then return 0; fi
    sleep 1
  done
  bgpctl show
  bgpctl show rib
  netstat -rn
  ipsecctl -s all
  ikectl show sa
  tail -40 /var/log/messages
  eval "$1"
}
'''
    guest.run('bash -euo pipefail -c ' + shlex.quote(helpers + script.strip()), timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--launcher', required=True, type=Path)
    parser.add_argument('--fixtures', required=True, type=Path)
    parser.add_argument('--vm-state', required=True, type=Path)
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    fixtures = args.fixtures.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix='nixopenbsd-network.'))
    print('Network tests: ' + str(work), flush=True)
    states = {role: work / role for role in ['left', 'right']}
    results = {}
    success = False
    traffic = shlex.join(['python3', '-B', str(source / 'tests/network/traffic.py')])
    addresses = {
        'left': ('198.51.100.2', '2001:db8:1::2', 1),
        'right': ('203.0.113.2', '2001:db8:2::2', 2),
    }

    def record(name):
        results[name] = 'passed'
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print('PASS ' + name, flush=True)

    def probe(address, port=9000, blocked=False):
        return f'route -T 1 exec {traffic} probe {address} {port}' + (' --blocked' if blocked else '')

    def endpoint(guest, role):
        ipv4, ipv6, number = addresses[role]
        run(guest, f'''
test "$(hostname)" = network-{number}.test
test "$(sysctl -n net.inet.ip.forwarding)" = 1
test "$(sysctl -n net.inet6.ip6.forwarding)" = 1
test "$(id -u _bgpd)" = 75
test "$(id -u _iked)" = 101
test "$(stat -c '%a' /etc/iked.conf)" = 600
test "$(stat -c '%a' /etc/iked/private)" = 700
test "$(stat -c '%a' /etc/iked/private/local.key)" = 600
/etc/rc.d/bgpd check
/etc/rc.d/iked check
pfctl -si | grep 'Status: Enabled'
ifconfig pair1 | grep 'rdomain 1'
ifconfig pair0 | grep 'patch: pair1'
ifconfig pair1 | grep 'inet {ipv4} '
wait_for "ifconfig pair1 | grep 'inet6 {ipv6} ' | grep -v tentative"
route -n get default | grep 'gateway: 10.0.2.2'
route -T 1 -n get default | grep 'gateway: {ipv4.rsplit('.', 1)[0]}.1'
route -T 1 -n get -inet6 default | grep 'gateway: 2001:db8:{number}::1'
if test -f /var/tmp/network-key.sha256; then
  sha256sum -c /var/tmp/network-key.sha256
else
  sha256sum /etc/iked/private/local.key > /var/tmp/network-key.sha256
fi
route -T 1 exec {traffic} serve {ipv4} {ipv6} >/var/tmp/network-endpoint.log 2>&1 &
echo $! > /var/tmp/network-endpoint.pid
wait_for "grep -q ENDPOINT_READY /var/tmp/network-endpoint.log"
kill -0 "$(cat /var/tmp/network-endpoint.pid)"
{probe(ipv4, 9000)}
{probe(ipv4, 9001)}
{probe(ipv6, 9000)}
{probe(ipv6, 9001)}
''')
        if role == 'left':
            run(guest, "route -n get default | grep -E 'priority: *42'")

    def routes(guest, role, present=True):
        other = 'right' if role == 'left' else 'left'
        ipv4, ipv6, number = addresses[other]
        prefix4 = ipv4.rsplit('.', 1)[0] + '.0/24'
        prefix6 = f'2001:db8:{number}::/64'
        for prefix in [prefix4, prefix6]:
            run(guest, f'wait_for "' + ('' if present else '! ') + f"bgpctl show rib | grep -Fq '{prefix}'\"")
        if present:
            run(guest, f'''
wait_for "route -n get {ipv4} | grep -q 'gateway: 192.0.2.{number}'"
wait_for "route -n get -inet6 {ipv6} | grep -q 'gateway: 2001:db8::{number}'"
route -n get {ipv4} | grep -E 'priority: *48'
route -n get -inet6 {ipv6} | grep -E 'priority: *48'
''')
        else:
            run(guest, f'''
if route -n get {ipv4} | grep -q 'gateway: 192.0.2.{number}'; then exit 1; fi
if route -n get -inet6 {ipv6} 2>/dev/null | grep -q 'gateway: 2001:db8::{number}'; then exit 1; fi
''')

    def transit(guest, role, ipv4=True, ipv6=True, allowed=True, attempts=60):
        other = 'right' if role == 'left' else 'left'
        for index, binary in [(0, 'ping'), (1, 'ping6')]:
            if not [ipv4, ipv6][index]:
                continue
            local, remote = addresses[role][index], addresses[other][index]
            command = f'route -T 1 exec {binary} -n -c 1 -w 2 -I {local} {remote} >/dev/null 2>&1'
            if allowed:
                run(guest, f'wait_for "{command}" {attempts}\n{probe(remote)}', timeout=max(240, attempts * 5))
            else:
                run(guest, f'if {command}; then exit 1; fi')

    def firewall(guest, role):
        other = 'right' if role == 'left' else 'left'
        for address in addresses[other][:2]:
            run(guest, '''
blocked_packets() {
  pfctl -s labels | awk '$1 == "blocked_udp" { packets += $3 } END { print packets+0 }'
}
before=$(blocked_packets)
''' + probe(address, 9001, blocked=True) + '''
test "$(blocked_packets)" -gt "$before"
''')

    def policy(guest, name):
        run(guest, f'''
ln -sfn {shlex.quote(str(fixtures / (name + '-pf')))} /etc/pf.conf
/etc/rc.d/pf start
pfctl -F states
''')

    def invalid_config(guest, service, filename):
        run(guest, f'''
before=$(pgrep -x {service} | sort -n)
test -n "$before"
cp -P /etc/{filename} /var/tmp/network-original.conf
trap 'mv -f /var/tmp/network-original.conf /etc/{filename}' EXIT
rm /etc/{filename}
printf '%s\\n' 'invalid configuration for regression test' > /etc/{filename}
chmod 600 /etc/{filename}
if /etc/rc.d/{service} restart; then exit 1; fi
test "$before" = "$(pgrep -x {service} | sort -n)"
mv -f /var/tmp/network-original.conf /etc/{filename}
trap - EXIT
/etc/rc.d/{service} check
''')

    with socket.socket(type=socket.SOCK_DGRAM) as a, socket.socket(type=socket.SOCK_DGRAM) as b:
        a.bind(('127.0.0.1', 0))
        b.bind(('127.0.0.1', 0))
        ports = [a.getsockname()[1], b.getsockname()[1]]

    def network(role):
        number = addresses[role][2]
        return ['-netdev', f'socket,id=network,udp=127.0.0.1:{ports[2-number]},localaddr=127.0.0.1:{ports[number-1]}',
                '-device', f'virtio-net-pci,netdev=network,mac=52:54:00:12:34:0{number}']

    guests = {}
    stacks = {role: ExitStack() for role in states}

    def boot(role, suffix=''):
        guest = stacks[role].enter_context(Guest(args.launcher, states[role], work / (role + suffix + '.log'), extra_args=network(role)))
        guests[role] = guest
        endpoint(guest, role)

    try:
        for role, state in states.items():
            clone_state(args.vm_state, state)
            with Guest(args.launcher, state, work / (role + '-install.log')) as guest:
                run(guest, shlex.quote(str(fixtures / role)) + '/bin/switch-to-configuration boot')
        for role in states:
            boot(role)
        record('nativeBootAndIsolatedLanEndpoints')
        for role, guest in guests.items():
            run(guest, '/etc/rc.d/iked stop\nipsecctl -F')
            policy(guest, 'routed')
            routes(guest, role)
        for role, guest in guests.items():
            transit(guest, role)
            firewall(guest, role)
        record('dualStackBgpTransitAndPfPolicy')

        left, right = guests['left'], guests['right']
        for sysctl, ipv4 in [('net.inet.ip.forwarding', True), ('net.inet6.ip6.forwarding', False)]:
            run(left, f'sysctl {sysctl}=0\npfctl -F states')
            transit(left, 'left', ipv4=ipv4, ipv6=not ipv4, allowed=False)
            transit(right, 'right', ipv4=ipv4, ipv6=not ipv4, allowed=False)
            run(left, f'sysctl {sysctl}=1')
            transit(left, 'left')
            transit(right, 'right')
        record('forwardingDisabledNegativeControls')
        for role, guest in guests.items():
            run(guest, '/etc/rc.d/network_interfaces start')
            routes(guest, role)
            transit(guest, role)
        record('repeatNetworkStartup')

        invalid_config(left, 'bgpd', 'bgpd.conf')
        run(left, '''
before=$(pfctl -sr | sha256sum)
cp -P /etc/pf.conf /var/tmp/network-original-pf.conf
trap 'mv -f /var/tmp/network-original-pf.conf /etc/pf.conf' EXIT
rm /etc/pf.conf
printf '%s\\n' 'invalid PF rules for regression test' > /etc/pf.conf
if /etc/rc.d/pf start; then exit 1; fi
test "$before" = "$(pfctl -sr | sha256sum)"
mv -f /var/tmp/network-original-pf.conf /etc/pf.conf
trap - EXIT
''')
        transit(left, 'left')
        record('invalidBgpRestartAndPfLoadPreserveTraffic')
        run(left, '''
/etc/rc.d/bgpd stop
if pgrep -x bgpd; then exit 1; fi
''')
        routes(right, 'right', present=False)
        transit(right, 'right', allowed=False)
        run(left, '/etc/rc.d/bgpd start')
        for role, guest in guests.items():
            routes(guest, role)
            transit(guest, role)
        record('bgpWithdrawalAndRestartRecovery')

        for guest in guests.values():
            policy(guest, 'protected')
        for role, guest in guests.items():
            transit(guest, role, allowed=False)
            run(guest, '/etc/rc.d/iked start')
        for role, guest in guests.items():
            transit(guest, role)
            firewall(guest, role)
            run(guest, '''
ipsecctl -s sa | grep 'esp tunnel'
ipsecctl -s flow | grep '198.51.100.0/24'
ipsecctl -s flow | grep '2001:db8:1::/64'
sha256sum -c /var/tmp/network-key.sha256
''')
        record('dualStackIpsecAndPfPolicy')

        run(left, '''
tcpdump -n -i vio1 -w /var/tmp/network-wan.pcap 'ip or ip6' >/var/tmp/network-tcpdump.log 2>&1 &
echo $! > /var/tmp/network-tcpdump.pid
wait_for "grep -q 'listening on vio1' /var/tmp/network-tcpdump.log"
''')
        for role, guest in guests.items():
            transit(guest, role)
        run(left, '''
kill -INT "$(cat /var/tmp/network-tcpdump.pid)"
wait_for "! kill -0 $(cat /var/tmp/network-tcpdump.pid) 2>/dev/null"
tcpdump -nr /var/tmp/network-wan.pcap esp > /var/tmp/network-esp.txt
test -s /var/tmp/network-esp.txt
tcpdump -nr /var/tmp/network-wan.pcap 'net 198.51.100.0/24 or net 203.0.113.0/24 or net 2001:db8:1::/64 or net 2001:db8:2::/64' > /var/tmp/network-cleartext.txt
test ! -s /var/tmp/network-cleartext.txt
''')
        record('espOnWireWithoutLanCleartext')
        invalid_config(left, 'iked', 'iked.conf')
        transit(left, 'left')
        run(left, '/etc/rc.d/iked restart\nsha256sum -c /var/tmp/network-key.sha256')
        for role, guest in guests.items():
            transit(guest, role)
        record('ikedRestartAndInvalidConfigRecovery')

        for guest in guests.values():
            run(guest, '/etc/rc.d/iked stop\nipsecctl -F\npfctl -F states')
        for role, guest in guests.items():
            routes(guest, role)
            transit(guest, role, allowed=False)
        for guest in guests.values():
            run(guest, '/etc/rc.d/iked start')
        for role, guest in guests.items():
            transit(guest, role)
        record('ipsecRemovedFailsClosedAndRecovers')

        for role in states:
            stacks[role].close()
            boot(role, '-reboot')
            for current, guest in guests.items():
                routes(guest, current)
                # A negotiation begun while the peer is down can remain pending
                # for iked's native five-minute exchange timeout before retrying.
                transit(guest, current, attempts=180)
                firewall(guest, current)
                run(guest, 'sha256sum -c /var/tmp/network-key.sha256')
            record(role + 'RebootRecovery')
        record('result')
        success = True
        print('NETWORK_RUNTIME_PASS', flush=True)
    finally:
        for stack in stacks.values():
            stack.close()
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        if success and not args.keep:
            for state in states.values():
                shutil.rmtree(state)


if __name__ == '__main__':
    main()
