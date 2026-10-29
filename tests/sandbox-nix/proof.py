"""Rebuild Nix inside isolation, then exercise the rebuilt CLI and daemon."""
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time


def main():
    fixtures = Path(sys.argv[1]).resolve(strict=True)
    timeout = int(sys.argv[2])
    source = (fixtures / 'source').resolve(strict=True)
    spec = importlib.util.spec_from_file_location('sandbox_packages', source / 'tests/sandbox-packages/proof.py')
    packages = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packages)
    results = packages.build_packages(fixtures, timeout, recipe='sandbox-nix', consumer=None)
    assert len(results['packages']) == 14, results['packages'].keys()
    print('SANDBOX_NIX_BUILD_RESULT ' + json.dumps(results), flush=True)
    native = Path(results['packages']['nix']['outputs']['out'])
    assert native / 'bin/nix' != Path(results['binary'])
    closure = set(subprocess.check_output([native / 'bin/nix-store', '-qR', native], text=True).splitlines())
    baseline = json.loads(subprocess.check_output([
        native / 'bin/nix-instantiate', '--eval', '--strict', '--json',
        source / 'tests/sandbox-nix/packages.nix', '--argstr', 'flakeRef', source,
        '-A', 'baselineOutputs'], text=True))
    assert not closure.intersection(baseline.values()), 'rebuilt Nix still uses old components'
    results['freshComponentClosure'] = 'passed'
    work = Path(tempfile.mkdtemp(prefix='openbsd-self-hosted-nix.', dir='/var/tmp'))
    work.chmod(0o755)
    env = os.environ | {'PATH': str(native / 'bin') + ':' + os.environ['PATH']}

    def run(name, argv, extra=None):
        print('RUN rebuilt Nix: ' + name, flush=True)
        with (work / (name + '.log')).open('w') as log:
            subprocess.run(list(map(str, argv)), env=env | (extra or {}),
                           stdout=log, stderr=subprocess.STDOUT, timeout=timeout, check=True)
        text = (work / (name + '.log')).read_text()
        print('PASS rebuilt Nix: ' + name, flush=True)
        return text

    print('Rebuilt Nix validation logs: ' + str(work), flush=True)
    runtime = run('native', [fixtures / 'native-tests/bin/test-openbsd-native', '--nix-checks', native])
    assert 'NATIVE_NIX_RUNTIME_PASS' in runtime
    pty_env = {'NIX_OPENBSD_TEST_COREUTILS': str(fixtures / 'coreutils/bin'),
               'NIX_OPENBSD_TEST_SLEEP': str(fixtures / 'coreutils/bin/sleep'),
               'NIX_OPENBSD_TEST_PTY_FIXTURES': str((fixtures / 'pty-fixtures').resolve(strict=True))}
    # Both PTY modes select the rebuilt Nix; the user connects to its private
    # daemon rather than the reference system's daemon restored by other suites.
    os.chdir('/')
    local = run('pty-local', ['bash', fixtures / 'pty-script'], pty_env | {'NIX_REMOTE': 'local'})
    subprocess.run(['/etc/rc.d/nix_daemon', 'stop'], check=True)
    daemon = None
    try:
        socket = str(work / 'socket')
        with (work / 'pty-daemon.log').open('w') as log:
            daemon = subprocess.Popen([native / 'bin/nix-daemon'],
                env=env | {'NIX_REMOTE': 'local', 'NIX_DAEMON_SOCKET_PATH': socket},
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            for _ in range(100):
                assert daemon.poll() is None, 'rebuilt PTY daemon exited'
                if Path(socket).is_socket():
                    break
                time.sleep(.1)
            else:
                raise AssertionError('rebuilt PTY daemon did not create socket')
            user = run('pty-daemon', ['su', '-m', 'bestie', '-c',
                       shlex.join(['bash', str(fixtures / 'pty-script')])],
                       pty_env | {'NIX_REMOTE': 'daemon', 'NIX_DAEMON_SOCKET_PATH': socket})
    finally:
        if daemon is not None:
            daemon.terminate()
            daemon.wait(timeout=30)
        subprocess.run(['/etc/rc.d/nix_daemon', 'start'], check=True)
    marker = 'PTY terminal detection, live output, fast exits, logs and cleanup passed'
    assert marker in local and marker in user
    python = fixtures / 'python3/bin/python3'
    isolation = run('isolation', [python, '-B', fixtures / 'isolation/tests/proof.py', fixtures / 'isolation'])
    assert 'ISOLATION_RUNTIME_PASS' in isolation
    package_log = run('sandbox-packages', [python, '-B', source / 'tests/sandbox-packages/proof.py',
                                         fixtures / 'sandbox-packages', str(timeout)])
    assert 'SANDBOX_PACKAGES_RUNTIME_PASS' in package_log
    package_result = json.loads(re.search(r'^SANDBOX_PACKAGES_RESULT (.+)$', package_log, re.M).group(1))
    assert package_result['binary'] == str(native / 'bin/nix')
    isolation_result = json.loads(re.search(r'^ISOLATION_RESULT (.+)$', isolation, re.M).group(1))
    assert isolation_result['binary'] == str(native / 'bin/nix')
    results.update(rebuiltNix=str(native), validationLogs=str(work),
                   nativeRuntime='passed', ptyLocalAndDaemon='passed',
                   isolation=isolation_result,
                   sandboxPackages=package_result)
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('SANDBOX_NIX_RESULT ' + json.dumps(results), flush=True)
    print('SANDBOX_NIX_RUNTIME_PASS', flush=True)


if __name__ == '__main__':
    main()
