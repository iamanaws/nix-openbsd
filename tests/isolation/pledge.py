"""Probe inherited exec policies inside a real Nix build; do not enable a policy."""
import json
import os
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import tempfile


def check_policies(fixtures, out):
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    work = Path(tempfile.mkdtemp(prefix='exec-policy.', dir='/build'))
    allowed = work / 'allowed'
    allowed.mkdir()
    hidden = work / 'hidden'
    hidden.write_text('hidden by inherited unveil\n')
    visible = allowed / 'visible'
    visible.write_text('visible after exec\n')
    out.mkdir()
    probe = fixtures / 'probe/bin/exec-probe'
    minimal = 'stdio rpath wpath cpath exec proc prot_exec'
    broad = minimal + ' fattr chown flock getpw tty inet dns route unix sendfd recvfd unveil id ps vminfo dpath'
    results = {}

    def run(name, promises, mode, argv, expected=0):
        result = subprocess.run([str(probe), 'exec-policy', promises, mode,
                                 str(hidden), str(allowed), *map(str, argv)],
                                cwd=allowed, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=600,
                                env=os.environ | {'HOME': str(allowed), 'TMPDIR': str(allowed)})
        log = result.stdout + result.stderr
        (out / (name + '.log')).write_text(log)
        assert result.returncode == expected, (name, result.returncode, log[-4000:])
        results[name] = {'returncode': result.returncode}
        return log

    for mode in ['open', 'locked']:
        for name, promises, expected in [('reset', '-', '1'), ('inherited', broad, '0')]:
            run(name + '-' + mode, promises, mode,
                [probe, 'exec-visibility', '3', hidden, visible, expected])
    run('unlocked-child-can-reveal-path', broad, 'open', [probe, 'unveil-reveal', hidden])
    run('child-cannot-expand-promises', broad, 'none', [probe, 'pledge-expand', broad + ' pf'])

    route = [fixtures / 'route/bin/route', '-n', 'show']
    run('route-control', '-', 'none', route)
    run('route-minimal', minimal, 'none', route, -signal.SIGABRT)
    run('route-broad', broad, 'none', route, -signal.SIGABRT)
    error = run('route-error', broad + ' error', 'none', route, 1)
    assert 'Function not implemented' in error

    # A parent lock prevents a native tool from establishing its own unveil.
    ifconfig = [fixtures / 'ifconfig/bin/ifconfig']
    run('ifconfig-control', '-', 'none', ifconfig)
    error = run('ifconfig-locked', broad, 'locked', ifconfig, 1)
    assert 'unveil' in error and 'Operation not permitted' in error

    for kind in ['shm', 'msg', 'sem']:
        argv = [probe, 'policy-ipc', kind]
        run('ipc-control-' + kind, '-', 'none', argv)
        run('ipc-broad-' + kind, broad, 'none', argv, -signal.SIGABRT)
        run('ipc-error-' + kind, broad + ' error', 'none', argv, 2)

    # A positive compiler workload distinguishes API restrictions from a policy
    # that simply prevents all useful programs from running.
    destination = allowed / 'consumers'
    run('native-consumers', broad, 'locked',
        [fixtures / 'bash/bin/bash', fixtures / 'tests/consumers.sh', fixtures, destination])
    assert (destination / 'result').read_text() == 'NATIVE_CONSUMERS_PASS\n'
    shutil.copytree(destination, out / 'consumers')
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    check_policies(Path(os.environ['fixtures']), Path(os.environ['out']))
