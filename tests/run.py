"""Run focused OpenBSD regression suites, or the complete set with --all."""
import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from xml.etree import ElementTree as ET


SUITES = {
    'local': 'Local unit tests and configuration evaluation',
    'base': 'Base VM service and network startup checks',
    'packages': 'Native package consumers and package regression checks',
    'go': 'Native Go standard tests, cgo, shfmt and regular-user builds',
    'dhcp': 'Native DHCP leases, DNS updates, carrier recovery and reboot persistence',
    'slaac': 'Native IPv6 SLAAC, lifetimes, DNS updates, static exclusions and recovery',
    'vm': 'Fresh native VM, cache downloads and restart',
    'workflow': 'Regular-user builds, personal configuration and live rollback',
    'generations': 'HTTP, cron, NTP, directories, failure recovery and boot recovery',
    'dns': 'DNS updates, failure recovery, cache preservation and boot recovery',
    'logging': 'Log delivery, rotation, live updates, failure recovery and boot recovery',
    'doas': 'Native privilege management, authentication and configuration rollback',
    'mail': 'Local delivery, cron output, persistent queues and configuration rollback',
    'maintenance': 'OpenBSD daily, weekly and monthly scripts, reports and local configuration',
    'cron-fallback': 'Generation checks without cronctl',
    'network': 'Native IPv4/IPv6 forwarding, PF, BGP and IPsec recovery',
    'isolation': 'Nix sandbox filesystem/network isolation, compiler consumers and lifecycle cleanup',
    'native': 'Native bootstrap, toolchain, C++ and Nix validation (slow)',
    'bootstrap': 'Focused native bootstrap and package builds',
    'toolchain': 'Focused LLVM, Clang and LLD checks (slow)',
    'cxx': 'Focused libc++ and libc++abi suites (slow)',
    'nix': 'Focused native Nix CLI and daemon checks',
}
REGULAR = ('local', 'base', 'packages', 'go', 'dhcp', 'slaac', 'vm', 'workflow', 'generations',
           'dns', 'logging', 'doas', 'mail', 'maintenance', 'cron-fallback', 'network', 'isolation')
GENERATIONS = {'generations', 'dns', 'logging', 'doas', 'mail', 'maintenance', 'cron-fallback'}
NATIVE = {'native': '--all', 'bootstrap': None, 'toolchain': '--toolchain',
          'cxx': '--cxx', 'nix': '--nix'}
BASELINE = 'github:iamanaws/nix-openbsd/openbsd-8.0'


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--suite', choices=SUITES, action='append', help='run only this suite; repeat to select several')
    selection.add_argument('--all', '--full', action='store_true', help='include the long native toolchain and runtime suites')
    parser.add_argument('--list', action='store_true', help='list suites without building or booting a VM')
    parser.add_argument('--work-dir', type=Path, help='empty directory for logs and CI reports')
    parser.add_argument('--keep', action='store_true', help='also retain successful test disks')
    parser.add_argument('--vm-state', type=Path, help='copy a stopped native VM for faster fixture preparation')
    parser.add_argument('--live-only', action='store_true', help='skip reboots, GC and console recovery in selected generation suites')
    parser.add_argument('--baseline', default=BASELINE, help='published native VM used to build new test inputs')
    parser.add_argument('--timeout', type=int, help='seconds per suite; defaults to 1 hour, or 24 hours for native suites')
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1], help=argparse.SUPPRESS)
    parser.add_argument('--host-system', default=platform.machine() + '-' + platform.system().lower(), help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.timeout is not None and args.timeout <= 0:
        parser.error('--timeout must be positive')
    if args.live_only and (not args.suite or not set(args.suite) <= GENERATIONS):
        parser.error('--live-only requires --suite generations, dns, logging, doas, mail, maintenance or cron-fallback')
    return args


def select_suites(args):
    if args.all:
        return ['local', 'native', *REGULAR[1:]]
    return list(dict.fromkeys(args.suite or REGULAR))


def write_reports(work, source, results):
    failed = any(r['result'] != 'passed' for r in results)
    (work / 'results.json').write_text(json.dumps({
        'source': str(source), 'result': 'failed' if failed else 'passed', 'suites': results,
    }, indent=2) + '\n')
    report = ET.Element('testsuite', name='nix-openbsd', tests=str(len(results)),
                        failures=str(sum(r['result'] != 'passed' for r in results)),
                        time=f"{sum(r['seconds'] for r in results):.3f}")
    for result in results:
        case = ET.SubElement(report, 'testcase', name=result['suite'], time=f"{result['seconds']:.3f}")
        if result['result'] != 'passed':
            ET.SubElement(case, 'failure', message=result['error']).text = result['log']
        ET.SubElement(case, 'system-out').text = 'Log: ' + result['log']
    ET.ElementTree(report).write(work / 'junit.xml', encoding='utf-8', xml_declaration=True)
    return 1 if failed else 0


def run_suites(runtime, suites, work):
    results = []
    interrupted = False
    for name in suites:
        log = work / (name + '.log')
        started = time.monotonic()
        result = {'suite': name, 'result': 'passed', 'log': str(log), 'error': ''}
        print(f'RUN {name}: {log}', flush=True)
        try:
            runtime.run_suite(name, log)
        except KeyboardInterrupt:
            result.update(result='interrupted', error='Interrupted')
            interrupted = True
        except Exception as error:
            result.update(result='failed', error=str(error))
        result['seconds'] = round(time.monotonic() - started, 3)
        results.append(result)
        print(f"{result['result'].upper()} {name} ({result['seconds']:.1f}s)" +
              (': ' + result['error'] if result['error'] else ''), flush=True)
        write_reports(work, runtime.source, results)
        if interrupted:
            break
    return 130 if interrupted else write_reports(work, runtime.source, results)


class Runtime:
    def __init__(self, args, suites, work):
        self.args, self.suites, self.work = args, suites, work
        self.source = args.source.resolve(strict=True)
        self.ref = 'path:' + str(self.source)
        self.env = os.environ | {
            'PYTHONDONTWRITEBYTECODE': '1',
            'NIX_VM_CORES': os.environ.get('NIX_VM_CORES', '2'),
            'NIX_VM_MEMORY': os.environ.get('NIX_VM_MEMORY', '4096'),
            'NIX_VM_DISK_READ_BPS': os.environ.get('NIX_VM_DISK_READ_BPS', '41943040'),
            'NIX_VM_DISK_WRITE_BPS': os.environ.get('NIX_VM_DISK_WRITE_BPS', '20971520'),
        }
        # The older cross-built runners use QEMU_OPTS instead of NIX_VM_DISK_*.
        self.env['QEMU_OPTS'] = (
            '-set drive.drive1.cache.direct=on '
            '-set drive.drive1.bps_rd=' + self.env['NIX_VM_DISK_READ_BPS'] + ' '
            '-set drive.drive1.bps_wr=' + self.env['NIX_VM_DISK_WRITE_BPS'] + ' '
            + os.environ.get('QEMU_OPTS', '')
        )
        if args.keep:
            self.env['OPENBSD_VM_KEEP_TMP'] = '1'
        self.prepared = None
        self.prepare_error = None
        self.launcher = None

    def command(self, args, capture=False, env=None):
        args = list(map(str, args))
        with self.log.open('ab', buffering=0) as log:
            log.write(('$ ' + shlex.join(args) + '\n').encode())
            process = subprocess.Popen(args, stdout=subprocess.PIPE if capture else log,
                                       stderr=log, env=env or self.env, start_new_session=True)
            try:
                output, _ = process.communicate(timeout=max(0, self.deadline - time.monotonic()))
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=100)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, args)
            return output.decode().strip() if capture else None

    def target_args(self):
        return ['--impure', '--file', str(self.source / 'tests/targets.nix'),
                '--argstr', 'flakeRef', str(self.source),
                '--argstr', 'system', self.args.host_system]

    def build(self, name, installables, extra=()):
        link = self.work / 'outputs' / name
        link.parent.mkdir(exist_ok=True)
        self.command(['nix', 'build', '--accept-flake-config', '--max-jobs', '1', '--cores', '2',
                      '--builders', '', '--out-link', link, *extra, *installables])
        return link.resolve(strict=True)

    def ensure_launcher(self):
        if self.launcher is None:
            self.launcher = self.build('prepared-launcher', ['preparedLauncher'], self.target_args())
            qemu = self.command(['nix', 'eval', '--raw', *self.target_args(), 'qemu.outPath'], capture=True)
            self.env['PATH'] = qemu + '/bin:' + self.env['PATH']
        return self.launcher

    def ensure_prepared(self):
        if self.prepare_error:
            raise RuntimeError(self.prepare_error)
        if self.prepared is not None:
            return self.prepared
        wanted = [s for s in self.suites if s in GENERATIONS or s in ['packages', 'go', 'dhcp', 'slaac', 'network', 'isolation']]
        if any(s in GENERATIONS or s in ['vm', 'workflow', 'dhcp', 'slaac', 'network', 'isolation'] for s in self.suites):
            wanted.insert(0, 'base')
        wanted = list(dict.fromkeys(wanted))
        try:
            select = '{ ' + ' '.join(json.dumps(s) + ' = null;' for s in wanted) + ' }'
            expected = json.loads(self.command([
                'nix', 'eval', '--json', *self.target_args(), 'nativeTargets', '--apply',
                't: builtins.mapAttrs (_: p: p.outPath) (builtins.intersectAttrs ' + select + ' t)',
            ], capture=True))
            targets = self.work / 'native-targets.json'
            targets.write_text(json.dumps(expected, indent=2) + '\n')
            self.ensure_launcher()
            starter = (self.launcher if self.args.vm_state else
                       self.build('baseline-launcher', [self.args.baseline + '#native-vm']))
            command = [sys.executable, '-B', self.source / 'tests/prepare.py',
                       '--source', self.source, '--launcher', starter,
                       '--work-dir', self.work / 'native-preparation', '--targets', targets,
                       '--timeout', str(self.timeout)]
            if self.args.vm_state:
                command += ['--vm-state', self.args.vm_state.resolve(strict=True)]
            if self.args.all or any(s in ['native', 'toolchain'] for s in self.suites):
                command += ['--allow-toolchain']
            self.command(command)
            self.prepared = expected
        except Exception as error:
            self.prepare_error = f'Native test preparation failed: {error}; see {self.work / "native-preparation"}'
            raise RuntimeError(self.prepare_error) from error
        return self.prepared

    def run_suite(self, name, log):
        self.log = log
        directory = self.work / name
        directory.mkdir()
        self.env['TMPDIR'] = str(directory)
        self.timeout = self.args.timeout or (86400 if name in NATIVE else 3600)
        self.deadline = time.monotonic() + self.timeout
        if name == 'local':
            self.build('local', [self.ref + '#checks.' + self.args.host_system + '.local'])
            self.command(['nix', 'eval', '--impure', '--json', '--file',
                          self.source / 'tests/base/default.nix', '--argstr', 'flakeRef', str(self.source), 'passed'])
            self.command(['nix', 'eval', '--impure', '--json', '--file',
                          self.source / 'tests/security/default.nix', '--argstr', 'flakeRef', str(self.source), 'passed'])
            self.command(['nix', 'eval', '--impure', '--json', '--file',
                          self.source / 'tests/mail/default.nix', '--argstr', 'flakeRef', str(self.source), 'passed'])
            self.command(['nix', 'eval', '--impure', '--json', '--file',
                          self.source / 'tests/maintenance/default.nix', '--argstr', 'flakeRef', str(self.source), 'passed'])
            self.command(['nix', 'eval', '--impure', '--json', '--file',
                          self.source / 'tests/dhcp/default.nix', '--argstr', 'flakeRef', str(self.source), 'passed'])
            self.command(['nix', 'eval', '--impure', '--json', '--file',
                          self.source / 'tests/slaac/default.nix', '--argstr', 'flakeRef', str(self.source), 'passed'])
            self.command(['nix', 'eval', '--impure', '--json', '--file',
                          self.source / 'tests/network/default.nix', '--argstr', 'flakeRef', str(self.source), 'passed'])
            self.command(['nix', 'eval', '--impure', '--json', '--file',
                          self.source / 'tests/isolation/default.nix', '--argstr', 'flakeRef', str(self.source), 'passed'])
        elif name == 'base':
            self.command(['bash', self.source / 'tests/base/run.sh', '--max-jobs', '1', '--cores', '2', '--builders', ''])
        elif name in NATIVE:
            extra = self.target_args() + [
                '--arg', 'cores', os.environ.get('NIX_VM_CORES', '8'),
                '--arg', 'memorySize', os.environ.get('NIX_VM_MEMORY', '16384'),
            ]
            runner = self.build('native', ['native'], extra)
            command = [runner / 'bin/test-openbsd-native']
            if NATIVE[name]:
                command.append(NATIVE[name])
            self.command(command, env=self.env | {'OPENBSD_VM_TIMEOUT': str(self.timeout)})
        elif name == 'packages':
            self.ensure_prepared()
        elif name == 'go':
            inputs = self.ensure_prepared()
            command = [sys.executable, '-B', self.source / 'tests/go/run.py',
                       '--source', self.source, '--launcher', self.launcher,
                       '--inputs', inputs['go'], '--timeout', str(self.timeout),
                       '--vm-state', self.work / 'native-preparation/state']
            if self.args.keep:
                command.append('--keep')
            self.command(command)
        elif name in ['dhcp', 'slaac', 'network', 'isolation']:
            inputs = self.ensure_prepared()
            command = [sys.executable, '-B', self.source / ('tests/' + name + '/run.py'),
                       '--source', self.source, '--launcher', self.launcher,
                       '--fixtures', inputs[name], '--timeout', str(self.timeout),
                       '--vm-state', self.work / 'native-preparation/state']
            if self.args.keep:
                command.append('--keep')
            self.command(command)
        elif name in ['vm', 'workflow']:
            self.ensure_prepared()
            command = [sys.executable, '-B', self.source / 'tests/vm/run.py', self.source,
                       '--timeout', str(self.timeout), '--builders', '']
            if name == 'workflow':
                command.append('--system-workflow')
            if self.args.keep:
                command.append('--keep')
            self.command(command)
        else:
            inputs = self.ensure_prepared()
            fixtures = Path(inputs[name])
            command = [sys.executable, '-B', self.source / 'tests/generations/run.py',
                       '--source', self.source, '--launcher', self.launcher,
                       '--base-system', inputs['base'], '--system-a', fixtures / 'a',
                       '--system-b', fixtures / 'b',
                       {s: '--' + s + '-fixtures' for s in ['dns', 'logging', 'doas', 'mail', 'maintenance']}.get(name, '--live-fixtures'), fixtures,
                       '--timeout', str(self.timeout),
                       '--vm-state', self.work / 'native-preparation/state']
            if self.args.live_only:
                command.append('--live-only')
            if self.args.keep:
                command.append('--keep')
            self.command(command)

    def cleanup(self, success):
        if success and not self.args.keep and self.prepared:
            shutil.rmtree(self.work / 'native-preparation/state')
            shutil.rmtree(self.work / 'native-preparation/roots')


def main(argv=None):
    args = arguments(argv)
    if args.list:
        for name, description in SUITES.items():
            print(f'{name:15} {description}')
        return 0
    suites = select_suites(args)
    if args.host_system != 'x86_64-linux' and suites != ['local']:
        raise SystemExit('VM suites currently require x86_64-linux; --suite local is portable.')
    work = args.work_dir.resolve() if args.work_dir else Path(tempfile.mkdtemp(prefix='nixopenbsd-tests.'))
    work.mkdir(parents=True, exist_ok=True)
    if any(work.iterdir()):
        raise SystemExit('--work-dir must be empty')
    print(f'Test results: {work}', flush=True)
    runtime = Runtime(args, suites, work)
    code = run_suites(runtime, suites, work)
    runtime.cleanup(code == 0)
    print(f'Reports: {work / "results.json"} and {work / "junit.xml"}', flush=True)
    return code


if __name__ == '__main__':
    sys.exit(main())
