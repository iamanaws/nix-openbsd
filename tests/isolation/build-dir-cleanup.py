"""Probe failed-build cleanup with extracted Nix methods in a disposable VM."""
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
    parser.add_argument('--builder-source', type=Path, required=True)
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
    start = code.index('void ChrootOpenBSDDerivationBuilder::cleanupBuild(bool force)')
    code = code[start:code.index('\n} // namespace nix', start)]
    base = args.builder_source.read_text()
    start = base.index('void DerivationBuilderImpl::cleanupBuild(bool force)')
    base = base[start:base.index('\nStorePath DerivationBuilderImpl::makeFallbackPath(', start)]
    with tempfile.TemporaryDirectory(prefix='build-dir-cleanup-') as temporary:
        work = Path(temporary)
        source, executable = work / 'probe.cc', work / 'probe'
        source.write_text(args.template.read_text().replace('// BASE_CLEANUP', base)
                          .replace('// OPENBSD_CLEANUP', code))
        subprocess.run([args.cxx, '-std=c++23', '-Wall', '-Wextra', '-Werror',
                        *shlex.split(os.environ.get('CXXFLAGS', '')),
                        str(source), '-o', str(executable),
                        *shlex.split(os.environ.get('LDFLAGS', ''))], check=True)
        failed = []
        for case in ['keep', 'symlink-file', 'symlink-directory', 'symlink-original',
                     'replaced-directory', 'regular-file', 'missing', 'dangling',
                     'force', 'disabled', 'builtin', 'unopened', 'stop-first', 'stop-failure']:
            directory = work / case
            directory.mkdir()
            try:
                result = subprocess.run([executable, case, directory, args.user],
                                        capture_output=True, text=True, timeout=15)
            except subprocess.TimeoutExpired:
                failed.append(case)
                print('FAIL cleanup-' + case + ': timed out', flush=True)
                continue
            if result.returncode:
                failed.append(case)
                print('FAIL cleanup-' + case + ': ' + result.stderr.strip(), flush=True)
            else:
                print('PASS cleanup-' + case, flush=True)
        if failed:
            raise SystemExit('Failed cleanup probes: ' + ', '.join(failed))


if __name__ == '__main__':
    main()
