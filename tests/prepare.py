"""Build native test inputs in OpenBSD and import their closures into the host."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import threading

from guest import Guest, clone_state


def prepare(source, launcher, work, targets, timeout, vm_state=None, allow_toolchain=False):
    work.mkdir(parents=True, exist_ok=False)
    state = work / 'state'
    if vm_state:
        clone_state(vm_state, state)
    with (work / 'source.nar').open('wb') as stream:
        subprocess.run(['nix-store', '--export', str(source)], stdout=stream, check=True)
    known = subprocess.check_output(['nix', 'path-info', '--all'], text=True)
    (work / 'known-paths').write_text(known)
    token = '/' + secrets.token_hex(24) + '/'
    uploaded = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            name = self.path.removeprefix(token) if self.path.startswith(token) else ''
            if name not in ['source.nar', 'known-paths', 'build.sh']:
                self.send_error(404)
                return
            data = (work / name).read_bytes()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_PUT(self):
            if self.path != token + 'outputs.nar':
                self.send_error(404)
                return
            remaining = int(self.headers.get('Content-Length', '-1'))
            if remaining <= 0:
                self.send_error(411)
                return
            with (work / 'outputs.partial').open('wb') as stream:
                while remaining:
                    chunk = self.rfile.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        raise ConnectionError('Incomplete native test output export')
                    stream.write(chunk)
                    remaining -= len(chunk)
            (work / 'outputs.partial').rename(work / 'outputs.nar')
            uploaded.set()
            self.send_response(200)
            self.send_header('Content-Length', '0')
            self.end_headers()

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    url = f'http://10.0.2.2:{server.server_port}{token}'
    commands = [f'''set -euo pipefail
export NIX_REMOTE=daemon PYTHONDONTWRITEBYTECODE=1
curl --noproxy '*' -fsS {url}source.nar | nix-store --import
work=$(mktemp -d /var/tmp/openbsd-test-build.XXXXXXXX)
trap 'rm -rf "$work"' EXIT
''']
    if {'go', 'packages'} & targets.keys():
        # Go's libc resolver tests require localhost forward and reverse lookups.
        commands.append(f'test -e /etc/hosts || install -m 644 {shlex.quote(str(source / "tests/go/hosts"))} /etc/hosts\n')
    for name, path in targets.items():
        command = shlex.join([
            'nix', '--log-format', 'raw', 'build', '--accept-flake-config', '--impure',
            '--file', str(source / 'tests/targets.nix'), '--argstr', 'flakeRef', str(source),
            'nativeTargets.' + name, '--max-jobs', '1',
            '--cores', os.environ.get('NIX_VM_CORES', '2'), '--keep-failed', '-L',
        ])
        commands.append(f'{command} --dry-run > "$work/plan" 2>&1\ncat "$work/plan"\n')
        if not allow_toolchain:
            commands.append('''if grep -Eq '/nix/store/[^ ]*-(llvm|clang|compiler-rt|libcxx|libcxxabi|libunwind)-[0-9][[:alnum:].+_-]*[.]drv' "$work/plan"; then
  echo 'Uncached toolchain inputs: run --suite native or --all, or use a prepared --vm-state.' >&2
  exit 1
fi
''')
        commands.append(f'''{command} -o "$work/{name}"
test "$(readlink -f "$work/{name}")" = {shlex.quote(path)}
''')
    paths = shlex.join(list(targets.values()))
    commands.append(f'''curl --noproxy '*' -fsS {url}known-paths -o "$work/known"
nix-store -qR {paths} | sort -u > "$work/closure"
grep -Fxv -f "$work/known" "$work/closure" > "$work/missing" || test "$?" = 1
nix-store --export $(cat "$work/missing") > "$work/outputs.nar"
curl --noproxy '*' -fsS --upload-file "$work/outputs.nar" {url}outputs.nar
''')
    if 'base' in targets:
        commands.append(shlex.quote(targets['base']) + '/bin/switch-to-configuration boot\n')
    (work / 'build.sh').write_text(''.join(commands))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with Guest(launcher, state, work / 'console.log') as guest:
            # The published baseline may reach login before its DHCP lease settles.
            guest.run(f"curl --noproxy '*' --retry 60 --retry-all-errors --retry-delay 1 --connect-timeout 2 --max-time 5 -fsS {url}build.sh -o /tmp/build-tests.sh && bash /tmp/build-tests.sh", timeout)
        if not uploaded.is_set():
            raise RuntimeError('Guest did not export its test inputs')
        with (work / 'outputs.nar').open('rb') as stream:
            subprocess.run(['nix-store', '--import'], stdin=stream, check=True)
        roots = work / 'roots'
        roots.mkdir()
        for name, path in targets.items():
            subprocess.run(['nix-store', '--realise', '--indirect', '--add-root', str(roots / name), path], check=True)
        (work / 'results.json').write_text(json.dumps(targets, indent=2) + '\n')
        for name in ['source.nar', 'outputs.nar']:
            (work / name).unlink()
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--launcher', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    parser.add_argument('--targets', required=True, type=Path)
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--vm-state', type=Path)
    parser.add_argument('--allow-toolchain', action='store_true')
    args = parser.parse_args()
    targets = json.loads(args.targets.read_text())
    assert targets and all(re.fullmatch(r'/nix/store/[a-z0-9]{32}-[^/\s]+', p) for p in targets.values())
    prepare(args.source, args.launcher, args.work_dir, targets, args.timeout,
            args.vm_state, args.allow_toolchain)


if __name__ == '__main__':
    main()
