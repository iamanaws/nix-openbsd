"""Validate native DHCP leases and resolver updates between two OpenBSD guests."""
import argparse
import json
from pathlib import Path
import shlex
import shutil
import socket
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guest import Guest, clone_state


def run(guest, script, timeout=180):
    guest.run('bash -eu -c ' + shlex.quote(script.strip()), timeout)


def qmp(path, command, arguments):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(10)
        connection.connect(str(path))
        stream = connection.makefile('rwb', buffering=0)
        assert 'QMP' in json.loads(stream.readline())
        for request in [{'execute': 'qmp_capabilities'},
                        {'execute': command, 'arguments': arguments}]:
            stream.write((json.dumps(request) + '\n').encode())
            while True:
                response = json.loads(stream.readline())
                if 'error' in response:
                    raise RuntimeError(response['error'])
                if 'return' in response:
                    break


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
    work = Path(tempfile.mkdtemp(prefix='nixopenbsd-dhcp.'))
    print('DHCP tests: ' + str(work), flush=True)
    results = {}
    states = {role: work / role for role in ['server', 'client']}
    for role, state in states.items():
        clone_state(args.vm_state, state)
        with Guest(args.launcher, state, work / (role + '-install.log')) as guest:
            run(guest, f'''
test ! -e /etc/rc.d/dhcpcd
/etc/rc.d/dhcpleased check
/etc/rc.d/resolvd check
ifconfig vio0 | grep AUTOCONF4
dhcpleasectl -l vio0 | grep 'inet 10[.]0[.]2[.]15 '
curl --retry 5 --retry-all-errors --retry-delay 1 -fsS https://nix-openbsd.cachix.org/nix-cache-info
{shlex.quote(str(fixtures / role))}/bin/switch-to-configuration boot
''')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    # Unix socket paths must fit sockaddr_un even with a long --work-dir.
    monitor_directory = tempfile.TemporaryDirectory(prefix='nixopenbsd-qmp.', dir='/tmp')
    monitor = Path(monitor_directory.name) / 'client.qmp'

    def network(role):
        endpoint = ('listen' if role == 'server' else 'connect') + f'=127.0.0.1:{port}'
        mac = '52:54:00:44:00:' + ('01' if role == 'server' else '02')
        flags = ['-netdev', 'socket,id=dhcp,' + endpoint,
                 '-device', 'virtio-net-pci,netdev=dhcp,id=dhcpnic,mac=' + mac]
        if role == 'client':
            monitor.unlink(missing_ok=True)
            flags += ['-qmp', f'unix:{monitor},server=on,wait=off']
        return flags

    def check_client(guest, dns):
        lookup = shlex.join(['python3', '-c',
            'import socket; assert {a[4][0] for a in socket.getaddrinfo('
            '"dhcp.a.dns.example.com", 80, socket.AF_INET, socket.SOCK_STREAM)} '
            '== {"192.0.2.10"}'])
        run(guest, f'''
test "$(readlink -f /run/current-system)" = {shlex.quote(str((fixtures / 'client').resolve()))}
test ! -e /etc/rc.d/dhcpcd
/etc/rc.d/dhcpleased check
/etc/rc.d/resolvd check
test "$(id -u _dhcp)" = 77
test "$(stat -c '%U:%G:%a' /var/db/dhcpleased)" = root:wheel:755
ifconfig vio1 | grep AUTOCONF4
for attempt in $(seq 1 60); do
  if dhcpleasectl -l vio1 | grep -q '192.0.2.100' &&
     grep -Eq '^nameserver[[:space:]]+{dns}([[:space:]]|$)' /etc/resolv.conf; then break; fi
  sleep 1
done
test -s /var/db/dhcpleased/vio1
dhcpleasectl -l vio1 | grep '192.0.2.100'
grep -E '^nameserver[[:space:]]+{dns}([[:space:]]|$)' /etc/resolv.conf
su -l bestie -c {shlex.quote(lookup)}
''')

    success = False
    try:
        with Guest(args.launcher, states['server'], work / 'server.log', extra_args=network('server')) as server:
            run(server, f'''
test "$(readlink -f /run/current-system)" = {shlex.quote(str((fixtures / 'server').resolve()))}
/etc/rc.d/dhcpd check
if ifconfig vio1 | grep -q AUTOCONF4; then exit 1; fi
python3 {shlex.quote(str(source / 'tests/dhcp/dns-server.py'))} >/var/tmp/dhcp-dns.log 2>&1 &
''')
            with Guest(args.launcher, states['client'], work / 'client.log', extra_args=network('client')) as client:
                check_client(client, '192.0.2.1')
                results['boot'] = 'passed'
                # Change only the server. The client must renew without a control request.
                run(server, f'''
temporary=$(mktemp /etc/.dhcpd.conf.XXXXXXXX)
cat {shlex.quote(str(fixtures / 'renewal'))} > "$temporary"
chmod 644 "$temporary"
mv -f "$temporary" /etc/dhcpd.conf
/etc/rc.d/dhcpd restart
/etc/rc.d/dhcpd check
''')
                run(client, '''
for attempt in $(seq 1 60); do
  if dhcpleasectl -l vio1 | grep -Eq 'nameservers 192[.]0[.]2[.]254([[:space:]]|$)'; then break; fi
  sleep 1
done
dhcpleasectl -l vio1
dhcpleasectl -l vio1 | grep -E 'nameservers 192[.]0[.]2[.]254([[:space:]]|$)'
''')
                results['automaticRenewal'] = 'passed'
                # OpenBSD 8.0 updates its lease on renewal, but emits a new DNS
                # proposal only on acquisition or rebooting the lease state.
                check_client(client, '192.0.2.1')
                qmp(monitor, 'set_link', {'name': 'dhcpnic', 'up': False})
                run(client, '''
for attempt in $(seq 1 30); do
  if ifconfig vio1 | grep -q 'status: no carrier'; then break; fi
  sleep 1
done
ifconfig vio1 | grep 'status: no carrier'
/etc/rc.d/dhcpleased check
''')
                qmp(monitor, 'set_link', {'name': 'dhcpnic', 'up': True})
                check_client(client, '192.0.2.254')
                run(client, "if grep -Eq '^nameserver[[:space:]]+192[.]0[.]2[.]1([[:space:]]|$)' /etc/resolv.conf; then exit 1; fi")
                results['carrierRecoveryAndDnsChange'] = 'passed'
                run(client, f'''
original=$(readlink /etc/dhcpleased.conf)
before=$(pgrep -x dhcpleased | sort)
temporary=$(mktemp /etc/.dhcpleased.conf.XXXXXXXX)
cat {shlex.quote(str(fixtures / 'invalid'))} > "$temporary"
chmod 644 "$temporary"
mv -f "$temporary" /etc/dhcpleased.conf
if /etc/rc.d/dhcpleased restart; then exit 1; fi
test "$(pgrep -x dhcpleased | sort)" = "$before"
ln -sfn "$original" /etc/dhcpleased.conf
/etc/rc.d/dhcpleased check
if /etc/rc.d/dhcpleased reload; then exit 1; fi
/etc/rc.d/dhcpleased restart
/etc/rc.d/dhcpleased check
/etc/rc.d/dhcpleased stop
if pgrep -x dhcpleased; then exit 1; fi
/etc/rc.d/dhcpleased start
dhcpleasectl -w 30 vio1
/etc/rc.d/network_interfaces start
touch /var/db/dhcpleased/test-persistence
''')
                check_client(client, '192.0.2.254')
                results['configurationChecksAndRestart'] = 'passed'
            with Guest(args.launcher, states['client'], work / 'client-reboot.log', extra_args=network('client')) as client:
                run(client, 'test -f /var/db/dhcpleased/test-persistence')
                check_client(client, '192.0.2.254')
                results['rebootPersistence'] = 'passed'
            results['result'] = 'passed'
            success = True
        print('DHCP_RUNTIME_PASS', flush=True)
    finally:
        monitor_directory.cleanup()
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        if success and not args.keep:
            for state in states.values():
                shutil.rmtree(state)


if __name__ == '__main__':
    main()
