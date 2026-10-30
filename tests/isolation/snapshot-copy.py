"""Compile the patch's actual snapshot methods and inject source-path races."""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cxx', required=True)
    parser.add_argument('--template', type=Path, default=Path(__file__).with_suffix('.cc'))
    parser.add_argument('--patch', type=Path, default=Path(__file__).resolve().parents[2] /
                        'pkgs/openbsd/nix-openbsd-sandbox.patch')
    args = parser.parse_args()
    text = args.patch.read_text()
    section = re.search(r'\+\+\+ b/openbsd/build/openbsd-derivation-builder.cc\n@@[^\n]*\n'
                        r'(.*?)(?=\n--- |\Z)', text, re.S).group(1)
    code = '\n'.join(line[1:] for line in section.splitlines() if line.startswith('+'))
    start = code.index('void ChrootOpenBSDDerivationBuilder::materialise(')
    end = code.index('AutoCloseFD ChrootOpenBSDDerivationBuilder::networkSocket()', start)
    template = args.template.read_text()
    with tempfile.TemporaryDirectory(prefix='sandbox-snapshot-') as temporary:
        work = Path(temporary)
        source, executable = work / 'probe.cc', work / 'probe'
        source.write_text(template.replace('// MATERIALISE_METHODS', code[start:end]))
        subprocess.run([args.cxx, '-std=c++23', '-Wall', '-Wextra', '-Werror',
                        *shlex.split(os.environ.get('CXXFLAGS', '')),
                        str(source), '-o', str(executable),
                        *shlex.split(os.environ.get('LDFLAGS', ''))], check=True)
        failed = []
        for case in ['file', 'tree', 'hardlink', 'setid', 'file-swap', 'directory-swap',
                     'directory-after-open', 'parent-symlink', 'fifo-swap']:
            directory = work / case
            directory.mkdir()
            try:
                result = subprocess.run([executable, case, directory], capture_output=True,
                                        text=True, timeout=3)
            except subprocess.TimeoutExpired:
                failed.append(case)
                print('FAIL ' + case + ': copy blocked', flush=True)
                continue
            if result.returncode:
                failed.append(case)
                print('FAIL ' + case + ': ' + result.stderr.strip(), flush=True)
            else:
                print(result.stdout.strip(), flush=True)
        if failed:
            raise SystemExit('Failed snapshot probes: ' + ', '.join(failed))


if __name__ == '__main__':
    main()
