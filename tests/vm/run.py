"""Exercise the native development workflow in a fresh VM, then restart it."""
import argparse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import functools
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from urllib.request import urlopen


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('--keep', action='store_true', help='keep test disks')
    parser.add_argument('--timeout', type=int, default=3600, help='seconds per guest phase')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='nixopenbsd-vm-test.'))
    print(f'Test files: {work}', flush=True)
    source = f'path:{args.source}'
    subprocess.run(['nix', 'build', '--accept-flake-config', f'{source}#native-vm',
                    '--cores', '8', '--max-jobs', '1', '-o', str(work / 'launcher')], check=True)
    # Archive direct inputs without recursively fetching development-tool inputs.
    roots = json.loads(output('nix', 'eval', '--impure', '--json', '--expr',
        f'let f = builtins.getFlake {json.dumps(source)}; in '
        '[ f.outPath f.inputs.nixbsd.outPath ] ++ '
        'builtins.map (input: input.outPath) (builtins.attrValues f.inputs.nixbsd.inputs)'))
    closure = output('nix-store', '--query', '--requisites', *roots).splitlines()
    # Serve only test inputs, behind a random path on the loopback interface.
    public = work / 'public'
    token = secrets.token_hex(24)
    payload = public / token
    payload.mkdir(parents=True)
    with (payload / 'sources.nar').open('wb') as stream:
        subprocess.run(['nix-store', '--export', *closure], stdout=stream, check=True)
    flake = shlex.quote('path:' + roots[0])
    (payload / 'client.sh').write_text(f'''set -eu
 test "$(id -u)" -ne 0
 mkdir -p "$HOME/development-test"
 cd "$HOME/development-test"
 nix build --accept-flake-config {flake}#hello --out-link result
 test "$(./result/bin/hello)" = "Hello, world!"
 test "$(nix run --accept-flake-config {flake}#hello)" = "Hello, world!"
 nix run --accept-flake-config {flake}#jq -- -n '1 + 1' | grep '^2$'
 nix-store --verify-path "$(readlink -f result)"
 echo USER_PACKAGE_PASS
''')
    expected = output('nix', 'eval', '--raw', f'{source}#native-system.outPath')

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(public)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://10.0.2.2:{server.server_port}/{token}'
    (payload / 'probe.sh').write_text(f'''set -eu
 test "$(readlink -f /run/current-system)" = {shlex.quote(expected)}
 mount | grep ' /boot/efi '
 for service in nix_daemon sshd dhcpcd httpd relayd cron syslogd; do
   /etc/rc.d/$service check
 done
 curl -fsS https://nix-openbsd.cachix.org/nix-cache-info
 curl --noproxy '*' -fsS {url}/sources.nar -o /tmp/sources.nar
 nix-store --import < /tmp/sources.nar
 rm /tmp/sources.nar
 curl --noproxy '*' -fsS {url}/client.sh -o /tmp/client.sh
 chmod 755 /tmp/client.sh
 su -l bestie -c 'bash /tmp/client.sh'
 touch /root/persistence-check
''')

    def free_port():
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            return sock.getsockname()[1]

    http_port, ssh_port = free_port(), free_port()
    env = os.environ | {
        'NIX_VM_STATE_DIR': str(work / 'state'),
        'NIX_VM_HTTP_PORT': str(http_port), 'NIX_VM_SSH_PORT': str(ssh_port),
        'NIX_VM_CORES': '8', 'NIX_VM_MEMORY': '4096',
    }
    success = False
    try:
        for phase in ('fresh', 'restart'):
            with (work / f'{phase}.log').open('wb', buffering=0) as log:
                process = subprocess.Popen([str(work / 'launcher/bin/run-openbsd-native-vm')],
                    env=env, stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT)
                try:
                    with (work / f'{phase}.log').open('rb') as reader:
                        buffer = b''

                        def expect(pattern):
                            nonlocal buffer
                            deadline = time.monotonic() + args.timeout
                            while time.monotonic() < deadline:
                                buffer += reader.read()
                                match = re.search(pattern, buffer)
                                if match:
                                    buffer = buffer[match.end():]
                                    return match
                                if process.poll() is not None:
                                    raise RuntimeError('VM exited before finishing')
                                time.sleep(0.2)
                            raise TimeoutError(f'Waiting for {pattern!r}; see {phase}.log')

                        def send(line):
                            process.stdin.write((line + '\n').encode())
                            process.stdin.flush()

                        expect(rb'login:')
                        send('root')
                        expect(rb'Password:')
                        send('toor')
                        expect(rb'root@')
                        if phase == 'fresh':
                            probe = f"curl --noproxy '*' -fsS {url}/probe.sh -o /tmp/probe.sh && bash /tmp/probe.sh"
                        else:
                            probe = "test -f /root/persistence-check && /etc/rc.d/nix_daemon check && su -l bestie -c 'test -x development-test/result/bin/hello && development-test/result/bin/hello'"
                        send(f"( {probe} ); status=$?; printf '\\nOPENBSD_VM_DONE:%s\\n' \"$status\"")
                        status = expect(rb'\nOPENBSD_VM_DONE:(\d+)\r?\n').group(1)
                        if status != b'0':
                            raise RuntimeError(f'{phase} failed with status {status.decode()}; see {phase}.log')
                        with urlopen(f'http://127.0.0.1:{http_port}/', timeout=10) as response:
                            if b'NixBSD' not in response.read():
                                raise RuntimeError('Unexpected HTTP response')
                        with socket.create_connection(('127.0.0.1', ssh_port), timeout=10) as ssh:
                            if not ssh.recv(256).startswith(b'SSH-2.0-'):
                                raise RuntimeError('Missing SSH banner')
                        send('shutdown -p now')
                        process.wait(timeout=60)
                        if process.returncode != 0:
                            raise RuntimeError('VM shutdown failed')
                        print(f'PASS {phase}: guest checks, HTTP and SSH', flush=True)
                finally:
                    if process.poll() is None:
                        # Try a clean shutdown before forcing a timed-out guest to exit.
                        try:
                            process.stdin.write(b'\x03shutdown -p now\n')
                            process.stdin.flush()
                            process.wait(timeout=60)
                        except (BrokenPipeError, subprocess.TimeoutExpired):
                            pass
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
        success = True
        print('NATIVE_VM_PASS', flush=True)
    finally:
        server.shutdown()
        server.server_close()
        if success and not args.keep:
            shutil.rmtree(work / 'state')
            shutil.rmtree(public)
            (work / 'launcher').unlink()
        print(f'Logs: {work}', flush=True)


if __name__ == '__main__':
    main()
