"""Run Nix sandbox integration tests in a private copy of a native OpenBSD VM."""
import argparse
import json
from pathlib import Path
import re
import secrets
import shlex
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from guest import Guest, clone_state


def run_managed(args, fixtures, work):
    directory = work / 'managed'
    directory.mkdir()
    state = directory / 'state'
    clone_state(args.vm_state, state)
    print('Managed daemon tests: ' + str(directory), flush=True)
    with Guest(args.launcher, state, directory / 'select-boot.log') as guest:
        guest.run(str(fixtures / 'managedSystems/a/bin/switch-to-configuration') + ' boot', args.timeout)
    phases = {}
    for phase in ['live', 'boot-b', 'boot-rollback']:
        log = directory / (phase + '.log')
        with Guest(args.launcher, state, log) as guest:
            guest.run(shlex.join([str(fixtures / 'python3/bin/python3'), '-B',
                                  str(fixtures / 'tests/managed.py'), str(fixtures), phase]), args.timeout)
        result = json.loads(re.search(r'^MANAGED_SANDBOX_RESULT (.+)$', log.read_text(), re.M).group(1))
        assert result['result'] == 'passed'
        phases[phase] = result
    assert len({result['binary'] for result in phases.values()}) == 1
    results = {'result': 'passed', 'phases': phases}
    (directory / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    if not args.keep:
        shutil.rmtree(state)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--launcher', required=True, type=Path)
    parser.add_argument('--fixtures', required=True, type=Path)
    parser.add_argument('--vm-state', required=True, type=Path)
    parser.add_argument('--timeout', type=int, default=3600)
    parser.add_argument('--keep', action='store_true')
    parser.add_argument('--managed-only', action='store_true')
    args = parser.parse_args()
    fixtures = args.fixtures.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix='nixopenbsd-isolation.'))
    print('Isolation tests: ' + str(work), flush=True)
    if args.managed_only:
        results = run_managed(args, fixtures, work)
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print('MANAGED_SANDBOX_RUNTIME_PASS', flush=True)
        return
    state, log = work / 'state', work / 'console.log'
    reboot_log = work / 'reboot.log'
    checkpoint = '/var/tmp/nix-isolation-reboot-' + secrets.token_hex(8) + '.json'
    proof = [str(fixtures / 'python3/bin/python3'), '-B',
             str(fixtures / 'tests/proof.py'), str(fixtures)]
    clone_state(args.vm_state, state)
    with Guest(args.launcher, state, log) as guest:
        guest.run('/etc/rc.d/nix_daemon check')
        guest.run(shlex.join(proof), args.timeout)
        guest.run(shlex.join(proof + ['--prepare-reboot', checkpoint]), args.timeout)
    contents = log.read_text(errors='replace')
    assert 'ISOLATION_RUNTIME_PASS' in contents and 'ISOLATION_REBOOT_READY' in contents
    results = json.loads(re.search(r'^ISOLATION_RESULT (.+)$', contents, re.M).group(1))
    assert results['result'] == 'passed'
    with Guest(args.launcher, state, reboot_log) as guest:
        guest.run('/etc/rc.d/nix_daemon check')
        guest.run(shlex.join(proof + ['--resume-reboot', checkpoint]), args.timeout)
    contents = reboot_log.read_text(errors='replace')
    assert 'ISOLATION_REBOOT_PASS' in contents
    reboot = json.loads(re.search(r'^ISOLATION_REBOOT_RESULT (.+)$', contents, re.M).group(1))
    assert reboot['binary'] == results['binary']
    group = 'flaggedOrdinaryAndFixedOutputRootsRecoverAfterReboot'
    assert reboot[group] == 'passed'
    results[group] = 'passed'
    results['managedDaemon'] = run_managed(args, fixtures, work)
    results['managedDaemonBootRestartSwitchAndRollback'] = 'passed'
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps(results), flush=True)
    print('ISOLATION_RUNTIME_PASS', flush=True)
    if not args.keep:
        shutil.rmtree(state)


if __name__ == '__main__':
    main()
