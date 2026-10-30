"""Exercise Nix's process-kill helper as root in a disposable OpenBSD VM."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cxx', required=True)
    parser.add_argument('--process-source', required=True, type=Path)
    parser.add_argument('--template', type=Path, default=Path(__file__).with_suffix('.cc'))
    parser.add_argument('--user', default='nixbld1')
    args = parser.parse_args()
    if sys.platform != 'openbsd' or os.geteuid() != 0:
        parser.error('run as root inside a disposable OpenBSD VM')
    code = args.process_source.read_text()
    start = code.index('void killUser(uid_t uid)')
    code = code[start:code.index('\n//////////////////////////////////////////////////////////////////////', start)]
    code = code.replace('if (kill(-1, SIGKILL)', 'if (probeKill(-1, SIGKILL)')
    code = code.replace('pledge(', 'probePledge(')
    with tempfile.TemporaryDirectory(prefix='kill-user-') as temporary:
        work = Path(temporary)
        source, executable = work / 'probe.cc', work / 'probe'
        source.write_text(args.template.read_text().replace('// KILL_USER', code))
        subprocess.run([args.cxx, '-std=c++23', '-Wall', '-Wextra', '-Werror',
                        *shlex.split(os.environ.get('CXXFLAGS', '')),
                        str(source), '-o', str(executable),
                        *shlex.split(os.environ.get('LDFLAGS', ''))], check=True)
        failed = []
        for case in ['ordinary', 'empty', 'detached', 'stopped', 'high-fds',
                     'open', 'socket', 'pledge-failure', 'interrupted', 'kill-error']:
            result = subprocess.run([executable, case, work, args.user], capture_output=True,
                                    text=True, timeout=20)
            if result.returncode:
                failed.append(case)
                print('FAIL kill-user-' + case + ': ' + result.stderr.strip(), flush=True)
            else:
                print('PASS kill-user-' + case, flush=True)
        if failed:
            raise SystemExit('Failed process-kill probes: ' + ', '.join(failed))


if __name__ == '__main__':
    main()
