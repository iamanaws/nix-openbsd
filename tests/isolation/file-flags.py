"""Probe build-owned file flag cleanup as root in a disposable OpenBSD VM."""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cxx', required=True)
    parser.add_argument('--template', type=Path, default=Path(__file__).with_suffix('.cc'))
    parser.add_argument('--patch', type=Path, default=Path(__file__).resolve().parents[2] /
                        'pkgs/openbsd/nix-openbsd-sandbox.patch')
    parser.add_argument('--user', default='nixbld1')
    args = parser.parse_args()
    if sys.platform != 'openbsd' or os.geteuid() != 0:
        parser.error('run as root inside a disposable OpenBSD VM')
    section = re.search(r'\+\+\+ b/openbsd/build/openbsd-derivation-builder.cc\n@@[^\n]*\n'
                        r'(.*?)(?=\n--- |\Z)', args.patch.read_text(), re.S).group(1)
    code = '\n'.join(line[1:] for line in section.splitlines() if line.startswith('+'))
    start = code.index('static void clearBuildFileFlags(')
    code = code[start:code.index('void ChrootOpenBSDDerivationBuilder::killSandbox(', start)]
    code = code.replace('chflagsat(', 'probeChflagsat(')
    with tempfile.TemporaryDirectory(prefix='file-flags-') as temporary:
        work = Path(temporary)
        source, executable = work / 'probe.cc', work / 'probe'
        source.write_text(args.template.read_text().replace('// FILE_FLAGS', code))
        subprocess.run([args.cxx, '-std=c++23', '-Wall', '-Wextra', '-Werror',
                        *shlex.split(os.environ.get('CXXFLAGS', '')),
                        str(source), '-o', str(executable),
                        *shlex.split(os.environ.get('LDFLAGS', ''))], check=True)
        failed = []
        for case in ['immutable', 'append', 'nodump', 'directory-immutable', 'directory-append',
                     'symlink', 'symlink-directory', 'dangling', 'fifo', 'hardlinks',
                     'foreign-input', 'inactive', 'root-symlink', 'clear-error']:
            directory = work / case
            directory.mkdir()
            try:
                result = subprocess.run([executable, case, directory, args.user],
                                        capture_output=True, text=True, timeout=15)
            except subprocess.TimeoutExpired:
                failed.append(case)
                print('FAIL flags-' + case + ': timed out', flush=True)
                continue
            if result.returncode:
                failed.append(case)
                print('FAIL flags-' + case + ': ' + result.stderr.strip(), flush=True)
            else:
                print('PASS flags-' + case, flush=True)
        if failed:
            raise SystemExit('Failed file flag probes: ' + ', '.join(failed))


if __name__ == '__main__':
    main()
