"""Validate native IPv6 SLAAC against OpenBSD rad on two private Ethernet links."""
import argparse
import json
from pathlib import Path
import shlex
import shutil
import socket
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guest import Guest, clone_state, qmp


def run(guest, script, timeout=180):
    # Each predicate is bounded and ends with a mandatory successful check.
    helpers = '''
wait_for() {
  for attempt in $(seq 1 90); do
    if eval "$1"; then return 0; fi
    sleep 1
  done
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
    work = Path(tempfile.mkdtemp(prefix='nixopenbsd-slaac.'))
    print('SLAAC tests: ' + str(work), flush=True)
    states = {role: work / role for role in ['server', 'client']}
    results = {}
    success = False
    for role, state in states.items():
        clone_state(args.vm_state, state)
        with Guest(args.launcher, state, work / (role + '-install.log')) as guest:
            run(guest, f'''
/etc/rc.d/dhcpleased check
/etc/rc.d/slaacd check
/etc/rc.d/resolvd check
ifconfig vio0 | grep AUTOCONF6
dhcpleasectl -l vio0 | grep 'inet 10[.]0[.]2[.]15 '
{shlex.quote(str(fixtures / role))}/bin/switch-to-configuration boot
''')
    ports = []
    for _ in range(2):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            ports.append(listener.getsockname()[1])
    monitor_directory = tempfile.TemporaryDirectory(prefix='nixopenbsd-qmp.', dir='/tmp')
    monitor = Path(monitor_directory.name) / 'client.qmp'

    def network(role):
        flags = []
        for number, port in enumerate(ports, 1):
            endpoint = ('listen' if role == 'server' else 'connect') + f'=127.0.0.1:{port}'
            mac = f'52:54:00:66:{number:02x}:' + ('01' if role == 'server' else '02')
            flags += ['-netdev', f'socket,id=slaac{number},' + endpoint,
                      '-device', f'virtio-net-pci,netdev=slaac{number},id=slaacnic{number},mac=' + mac]
        if role == 'client':
            monitor.unlink(missing_ok=True)
            flags += ['-qmp', f'unix:{monitor},server=on,wait=off']
        return flags

    def check_client(guest, prefix='2001:db8:100', dns='53', temporary=True):
        lookup = shlex.join(['python3', '-c',
            'import socket; assert {a[4][0] for a in socket.getaddrinfo('
            '"slaac.a.dns.example.com", 80, socket.AF_INET, socket.SOCK_STREAM)} '
            '== {"192.0.2.10"}'])
        run(guest, f'''
/etc/rc.d/dhcpleased check
/etc/rc.d/slaacd check
/etc/rc.d/resolvd check
test "$(id -u _slaacd)" = 115
test "$(id -g _slaacd)" = 115
test "$(stat -c '%a' /var/empty)" = 555
ifconfig vio1 | grep AUTOCONF6
wait_for "ifconfig vio1 | grep 'inet6 {prefix}:' | grep -v tentative"
wait_for "route -n get -inet6 default | grep 'interface: vio1'"
wait_for "grep -Eq '^nameserver[[:space:]]+2001:db8:100::{dns}([[:space:]]|$)' /etc/resolv.conf"
if ifconfig vio0 | grep -q AUTOCONF6; then exit 1; fi
if ifconfig vio2 | grep -q AUTOCONF6; then exit 1; fi
ifconfig vio2 | grep 'inet6 2001:db8:300::2 '
test "$(ifconfig vio2 | grep -c 'inet6 2001:db8:300:')" = 1
slaacctl show interface vio1
su -l bestie -c {shlex.quote(lookup)}
''')
        if temporary:
            run(guest, f'wait_for "ifconfig vio1 | grep \'inet6 {prefix}:\' | grep temporary | grep -v tentative"')
        else:
            run(guest, 'if ifconfig vio1 | grep -q temporary; then exit 1; fi')

    try:
        with Guest(args.launcher, states['server'], work / 'server.log', extra_args=network('server')) as server:
            run(server, f'''
test ! -e /etc/rc.d/slaacd
/etc/rc.d/rad check
/etc/rc.d/sysctl start
/etc/rc.d/sysctl_lastload start
test "$(sysctl -n net.inet6.ip6.forwarding)" = 1
if ifconfig vio1 | grep -q AUTOCONF6; then exit 1; fi
python3 {shlex.quote(str(source / 'tests/slaac/dns-server.py'))} >/var/tmp/slaac-dns.log 2>&1 &
''')
            with Guest(args.launcher, states['client'], work / 'client.log', extra_args=network('client')) as client:
                check_client(client)
                results['bootAndStaticExclusion'] = 'passed'
                # Stop all rad processes without sending a final withdrawal RA.
                run(server, 'pkill -STOP -x rad')
                run(client, '''
wait_for "ifconfig vio1 | grep 'inet6 2001:db8:100:' | grep deprecated"
''')
                results['preferredAddressLifetime'] = 'passed'
                run(client, '''
wait_for "! route -n get -inet6 default >/dev/null 2>&1"
wait_for "! grep -Eq '^nameserver[[:space:]]+2001:db8:100::53([[:space:]]|$)' /etc/resolv.conf"
wait_for "! ifconfig vio1 | grep -q 'inet6 2001:db8:100:'"
/etc/rc.d/slaacd check
''')
                results['addressRouterAndDnsExpiry'] = 'passed'
                run(server, 'pkill -CONT -x rad')
                run(client, 'slaacctl send solicitation vio1')
                check_client(client)
                results['advertisementRecovery'] = 'passed'
                run(server, f'''
temporary=$(mktemp /etc/.rad.conf.XXXXXXXX)
cat {shlex.quote(str(fixtures / 'changed'))} > "$temporary"
chmod 644 "$temporary"
mv -f "$temporary" /etc/rad.conf
/etc/rc.d/rad restart
/etc/rc.d/rad check
''')
                run(client, 'slaacctl send solicitation vio1')
                check_client(client, '2001:db8:200', '54')
                run(client, '''
wait_for "! ifconfig vio1 | grep -q 'inet6 2001:db8:100:'"
wait_for "! grep -Eq '^nameserver[[:space:]]+2001:db8:100::53([[:space:]]|$)' /etc/resolv.conf"
''')
                results['prefixAndDnsChange'] = 'passed'
                qmp(monitor, 'set_link', {'name': 'slaacnic1', 'up': False})
                run(client, "wait_for \"ifconfig vio1 | grep -q 'status: no carrier'\"")
                qmp(monitor, 'set_link', {'name': 'slaacnic1', 'up': True})
                check_client(client, '2001:db8:200', '54')
                results['carrierRecovery'] = 'passed'
                run(client, '''
if /etc/rc.d/slaacd reload; then exit 1; fi
/etc/rc.d/slaacd restart
/etc/rc.d/slaacd check
/etc/rc.d/slaacd stop
if pgrep -x slaacd; then exit 1; fi
/etc/rc.d/slaacd start
slaacctl send solicitation vio1
/etc/rc.d/network_interfaces start
''')
                check_client(client, '2001:db8:200', '54')
                results['serviceLifecycle'] = 'passed'
                run(client, f'{shlex.quote(str(fixtures / "no-temporary"))}/bin/switch-to-configuration boot')
            with Guest(args.launcher, states['client'], work / 'no-temporary.log', extra_args=network('client')) as client:
                check_client(client, '2001:db8:200', '54', temporary=False)
                results['rebootAndTemporaryAddressesDisabled'] = 'passed'
                run(client, f'{shlex.quote(str(fixtures / "explicit-static"))}/bin/switch-to-configuration boot')
            with Guest(args.launcher, states['client'], work / 'explicit-static.log', extra_args=network('client')) as client:
                run(client, '''
ifconfig vio2 | grep AUTOCONF6
ifconfig vio2 | grep 'inet6 2001:db8:300::2 '
wait_for "ifconfig vio2 | grep 'inet6 2001:db8:300:' | grep autoconf | grep -v tentative"
''')
                results['explicitStaticOverride'] = 'passed'
            results['result'] = 'passed'
            success = True
        print('SLAAC_RUNTIME_PASS', flush=True)
    finally:
        monitor_directory.cleanup()
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        if success and not args.keep:
            for state in states.values():
                shutil.rmtree(state)


if __name__ == '__main__':
    main()
