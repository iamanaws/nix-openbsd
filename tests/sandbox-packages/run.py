"""Run fresh Nixpkgs package builds in a disposable OpenBSD sandbox VM."""
import argparse
import json
from pathlib import Path
import re
import shlex
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guest import Guest, clone_state


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--launcher', required=True, type=Path)
    parser.add_argument('--fixtures', required=True, type=Path)
    parser.add_argument('--vm-state', required=True, type=Path)
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--keep', action='store_true')
    args = parser.parse_args()
    fixtures = args.fixtures.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix='nixopenbsd-sandbox-packages.'))
    print('Sandbox package tests: ' + str(work), flush=True)
    state, log = work / 'state', work / 'console.log'
    clone_state(args.vm_state, state)
    with Guest(args.launcher, state, log) as guest:
        guest.run(shlex.join([str(fixtures / 'python3/bin/python3'), '-B',
                              str(fixtures / 'source/tests/sandbox-packages/proof.py'),
                              str(fixtures), str(args.timeout)]), args.timeout)
    contents = log.read_text(errors='replace')
    assert 'SANDBOX_PACKAGES_RUNTIME_PASS' in contents
    results = json.loads(re.search(r'^SANDBOX_PACKAGES_RESULT (.+)$', contents, re.M).group(1))
    assert results['result'] == 'passed'
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results), flush=True)
    print('SANDBOX_PACKAGES_RUNTIME_PASS', flush=True)
    if not args.keep:
        shutil.rmtree(state)


if __name__ == '__main__':
    main()
