"""Build ordinary package recipes through an untrusted daemon client."""
import argparse
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time


def workflow_consumers(fixtures, packages, work):
    output = lambda name: packages[name]['outputs']['out']
    site = f'lib/python{sys.version_info.major}.{sys.version_info.minor}/site-packages'
    return f'''set -euo pipefail
cd {shlex.quote(str(work / 'consumers'))}
PYTHONPATH={shlex.quote(output('workflow-python') + '/' + site)} {shlex.quote(str(fixtures / 'python3/bin/python3'))} -c 'import sandbox_probe; assert sandbox_probe.answer() == 42'
for program in {" ".join(shlex.quote(output(name) + '/bin/answer') for name in ['workflow-tools', 'workflow-autotools', 'workflow-cmake', 'workflow-meson'])}; do
    test "$("$program")" = 42
done
printf 'SANDBOX_PACKAGE_CONSUMERS_PASS\\n'
'''


def consumers(fixtures, packages, work):
    directory = work / 'consumers'
    output = lambda name, part='out': packages[name]['outputs'][part]
    quote = shlex.quote
    cxxlib = (fixtures / 'libcxx').resolve(strict=True) / 'lib'
    site = f'lib/python{sys.version_info.major}.{sys.version_info.minor}/site-packages'
    database = directory / 'test.sqlite'
    migrate = shlex.join([output('dbmate') + '/bin/dbmate', '--url', 'sqlite:' + str(database),
                          '--migrations-dir', str(directory / 'migrations'),
                          '--schema-file', str(directory / 'schema.sql')])
    return f'''set -euo pipefail
cd {quote(str(directory))}
export PATH={quote(str(fixtures / 'sqlite/bin'))}:"$PATH"
{quote(output('hello') + '/bin/hello')} | grep -Fx 'Hello, world!'
printf 'echo   hello\\n' | {quote(output('shfmt') + '/bin/shfmt')} -ln posix | grep -Fx 'echo hello'
PYTHONPATH={quote(output('markupsafe') + '/' + site)} {quote(str(fixtures / 'python3/bin/python3'))} -c 'import markupsafe._speedups; from markupsafe import escape; assert str(escape("<native>")) == "&lt;native&gt;"'
cat > fmt.cc <<'EOF'
#include <fmt/format.h>
int main() {{ fmt::print("native fmt: {{}}\\n", 42); }}
EOF
{quote(str(fixtures / 'cc/bin/c++'))} fmt.cc -I{quote(output('fmt', 'dev') + '/include')} -L{quote(output('fmt') + '/lib')} -Wl,-rpath,{quote(output('fmt') + '/lib')} -L{quote(str(cxxlib))} -Wl,-rpath,{quote(str(cxxlib))} -lfmt -o fmt
./fmt | grep -Fx 'native fmt: 42'
cat > inih.c <<'EOF'
#include <ini.h>
#include <stdlib.h>
#include <string.h>
static int handler(void *p, const char *section, const char *name, const char *value) {{
    if (strcmp(section, "native") || strcmp(name, "answer")) return 0;
    *(int *)p = atoi(value);
    return 1;
}}
int main(void) {{
    int answer = 0;
    return ini_parse_string("[native]\\nanswer=42\\n", handler, &answer) || answer != 42;
}}
EOF
{quote(str(fixtures / 'cc/bin/cc'))} inih.c -I{quote(output('inih', 'dev') + '/include')} -L{quote(output('inih') + '/lib')} -Wl,-rpath,{quote(output('inih') + '/lib')} -linih -o inih
./inih
mkdir migrations
cat > migrations/20260101000000_notes.sql <<'EOF'
-- migrate:up
CREATE TABLE notes (body TEXT);
INSERT INTO notes VALUES ('native sandbox');
-- migrate:down
DROP TABLE notes;
EOF
{migrate} up
test "$(sqlite3 {quote(str(database))} 'SELECT body FROM notes;')" = 'native sandbox'
{migrate} rollback
test "$(sqlite3 {quote(str(database))} "SELECT count(*) FROM sqlite_master WHERE name='notes';")" = 0
{workflow_consumers(fixtures, packages, work)}
'''


def build_packages(fixtures, timeout, recipe='sandbox-packages', consumer=consumers, workflows_only=False):
    assert os.getuid() == 0
    source = (fixtures / 'source').resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix='openbsd-' + recipe + '.', dir='/var/tmp'))
    work.chmod(0o755)
    print('Guest package logs: ' + str(work), flush=True)
    outside = work / 'outside'
    outside.write_text('readable host fixture\n')
    outside.chmod(0o644)
    nonce = secrets.token_hex(12)
    listeners = []
    for family, address in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
        listener = socket.socket(family, socket.SOCK_STREAM)
        listener.bind((address, 0))
        listener.listen(16)
        listeners.append(listener)
    ports = json.dumps([listener.getsockname()[1] for listener in listeners])
    nix = Path(shutil.which('nix')).resolve()
    env = os.environ | {'NIX_REMOTE': 'daemon', 'NIX_DAEMON_SOCKET_PATH': str(work / 'socket'),
                       'NIX_LOG_NO_COLORS': '1'}

    def command(argv, **kwargs):
        return subprocess.run(list(map(str, argv)), env=kwargs.pop('env', env),
                              capture_output=True, text=True, timeout=kwargs.pop('timeout', 120),
                              check=kwargs.pop('check', True), **kwargs)

    arguments = [str(source / ('tests/' + recipe + '/packages.nix')),
                 '--argstr', 'flakeRef', str(source), '--argstr', 'nonce', nonce,
                 '--argstr', 'outside', str(outside), '--argstr', 'ports', ports]
    packages = json.loads(command(['nix-instantiate', '--eval', '--strict', '--json',
                                   *arguments, '-A', 'metadata'],
                                  env=env | {'NIX_REMOTE': 'local'}).stdout)
    if workflows_only:
        packages = {name: package for name, package in packages.items() if name.startswith('workflow-')}
        assert packages, 'no workflow projects selected'
    paths = [path for package in packages.values() for path in package['outputs'].values()]
    assert all(not Path(path).exists() for path in paths), 'fresh package output already exists'
    subprocess.run(['/etc/rc.d/nix_daemon', 'stop'], check=True)
    daemon = None
    try:
        with (work / 'daemon.log').open('w') as log:
            daemon = subprocess.Popen([nix.with_name('nix-daemon'),
                '--option', 'sandbox', 'true', '--option', 'sandbox-fallback', 'false',
                '--option', 'sandbox-rdomains', '201 202 203 204',
                '--option', 'trusted-users', 'root', '--option', 'max-jobs', '2',
                '--option', 'cores', '1', '--option', 'keep-failed', 'true'],
                env=env | {'NIX_REMOTE': 'local'}, stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT)
            for _ in range(100):
                assert daemon.poll() is None, 'test daemon exited'
                if Path(env['NIX_DAEMON_SOCKET_PATH']).is_socket():
                    break
                time.sleep(.1)
            else:
                raise AssertionError('test daemon did not create its socket')
            argv = [str(nix.with_name('nix-build')), *arguments,
                    '--no-substitute', '--no-out-link', '--max-jobs', '2', '--cores', '1']
            for name in packages:
                argv += ['-A', 'packages.' + name]
            client = ['su', '-l', 'bestie', '-c', shlex.join([
                'env', 'NIX_REMOTE=daemon', 'NIX_DAEMON_SOCKET_PATH=' + env['NIX_DAEMON_SOCKET_PATH'],
                'NIX_LOG_NO_COLORS=1', *argv])]
            with (work / 'build.log').open('w') as stream:
                built = subprocess.run(client, stdout=stream, stderr=subprocess.STDOUT,
                                       timeout=timeout)
            assert built.returncode == 0, (work / 'build.log').read_text()[-10000:]
            intervals = {}
            for name, package in packages.items():
                log = command(['nix-store', '--read-log', package['drvPath']]).stdout
                (work / (name + '.log')).write_text(log)
                events = re.findall(r'^SANDBOX_PACKAGE_(START|END) (.+)$', log, re.M)
                assert [event for event, _ in events] == ['START', 'END'], (name, log[-6000:])
                start, end = [json.loads(value) for _, value in events]
                for event in [start, end]:
                    assert event['nonce'] == nonce and event['package'] == name
                    assert event['uid'] != 0 and event['domain'] in [201, 202, 203, 204]
                assert start['uid'] == end['uid'] and start['domain'] == end['domain']
                package['isolation'] = {'uid': start['uid'], 'domain': start['domain']}
                intervals[name] = start, end
                print('PASS fresh sandboxed package: ' + name, flush=True)
            overlaps = [[a, b] for a, (start, end) in intervals.items()
                        for b, (other, finished) in intervals.items() if a < b
                        and max(start['time'], other['time']) < min(end['time'], finished['time'])
                        and start['uid'] != other['uid'] and start['domain'] != other['domain']]
            assert overlaps, 'package builds did not overlap in separate domains'
            command(['nix-store', '--check-validity', *paths])
            command(['nix-store', '--verify-path', *paths])
            deadline = time.monotonic() + 30
            while True:
                remaining = [domain for domain in [201, 202, 203, 204]
                    if subprocess.run([str(fixtures / 'ifconfig/bin/ifconfig'), 'lo' + str(domain)],
                                      capture_output=True).returncode == 0]
                if not remaining:
                    break
                assert time.monotonic() < deadline, remaining
                time.sleep(.1)
            for uid in {package['isolation']['uid'] for package in packages.values()}:
                processes = command(['ps', '-U', str(uid), '-o', 'pid=,stat='], check=False).stdout
                assert not [line for line in processes.splitlines() if 'Z' not in line], processes
            if consumer is not None:
                directory = work / 'consumers'
                directory.mkdir()
                user = pwd.getpwnam('bestie')
                os.chown(directory, user.pw_uid, user.pw_gid)
                script = consumer(fixtures, packages, work)
                (work / 'consumers.sh').write_text(script)
                consumed = command(['su', '-l', 'bestie', '-c', 'bash -c ' + shlex.quote(script)], check=False)
                (work / 'consumers.log').write_text(consumed.stdout + consumed.stderr)
                assert consumed.returncode == 0, consumed.stdout + consumed.stderr
                assert 'SANDBOX_PACKAGE_CONSUMERS_PASS' in consumed.stdout
            results = {'result': 'passed', 'nix': command([nix, '--version']).stdout.strip(),
                       'binary': str(nix), 'logs': str(work),
                       'packages': packages, 'parallelBuilds': overlaps,
                       'freshBuilds': 'passed',
                       'processAndDomainCleanup': 'passed', 'defaultSandbox': False}
            if consumer is not None:
                results['regularUserConsumers'] = 'passed'
            if 'workflow-tools' in packages:
                api = Path(packages['workflow-tools']['outputs']['out']) / 'share/workflows.json'
                results['nativeAPIWorkflows'] = json.loads(api.read_text())
            (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            return results
    finally:
        if daemon is not None:
            daemon.terminate()
            daemon.wait(timeout=30)
        subprocess.run(['/etc/rc.d/nix_daemon', 'start'], check=True)
        for listener in listeners:
            listener.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixtures', type=Path)
    parser.add_argument('timeout', type=int)
    parser.add_argument('--workflows-only', action='store_true')
    args = parser.parse_args()
    fixtures = args.fixtures.resolve(strict=True)
    results = build_packages(fixtures, args.timeout,
                             consumer=workflow_consumers if args.workflows_only else consumers,
                             workflows_only=args.workflows_only)
    print('SANDBOX_PACKAGES_RESULT ' + json.dumps(results), flush=True)
    print('SANDBOX_PACKAGES_RUNTIME_PASS', flush=True)


if __name__ == '__main__':
    main()
