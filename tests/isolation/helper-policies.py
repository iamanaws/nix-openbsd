"""Probe the patch's helpers and launcher as root in a disposable OpenBSD VM."""
import argparse
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


def added_file(patch, name):
    section = re.search(r'\+\+\+ b/' + re.escape(name) + r'\n@@[^\n]*\n'
                        r'(.*?)(?=\n--- |\Z)', patch, re.S).group(1)
    return '\n'.join(line[1:] for line in section.splitlines() if line.startswith('+')) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cxx', required=True)
    parser.add_argument('--descriptor-source', type=Path, required=True,
                        help='patched Nix unix/file-descriptor.cc')
    parser.add_argument('--template', type=Path, default=Path(__file__).with_suffix('.cc'))
    root = Path(__file__).resolve().parents[2] / 'pkgs/openbsd'
    parser.add_argument('--sandbox-patch', type=Path, default=root / 'nix-openbsd-sandbox.patch')
    parser.add_argument('--pty-patch', type=Path, default=root / 'nix-openbsd-builder-pty.patch')
    parser.add_argument('--user', default='nixbld1')
    parser.add_argument('--shell', default='/bin/sh')
    args = parser.parse_args()
    if sys.platform != 'openbsd' or os.geteuid() != 0:
        parser.error('run as root inside a disposable OpenBSD VM')

    sandbox = args.sandbox_patch.read_text()
    builder = added_file(sandbox, 'openbsd/build/openbsd-derivation-builder.cc')
    start = builder.index('Pid cleanup = startProcess([&] {') + len('Pid cleanup = startProcess([&] {')
    caller = builder[start:builder.index('\n            });', start)]
    caller = caller.replace('cleanupOpenBSDSysVIPC(buildUser->getUID());',
                            'createOwnedIPC();\ncleanupOpenBSDSysVIPC(buildUser->getUID());')
    caller = caller.replace('_exit(0);', 'checkCleanup();\n_exit(0);')
    start = builder.index('        if (!live) {')
    transaction = builder[start:builder.index('\n        // Signal as the build UID', start)]
    patch = args.pty_patch.read_text()
    pty = '\n'.join(line[1:] for line in patch.splitlines()
                    if line.startswith('+') and not line.startswith('+++'))
    start = pty.index('pid_t child = fork();')
    supervisor = pty[start:pty.index('\n#endif', start)]
    supervisor = supervisor.replace('int status;', 'challenge();\nint status;')
    supervisor = supervisor.replace('fork()', 'workerFork()')
    state = re.search(r'^\+    bool supervised = false;$', patch, re.M)
    state = state.group()[1:] if state else ''
    policy = re.search(r'    if \(pledge\("stdio exec", nullptr\) == -1\)\n'
                       r'\s+throw SysError\("restricting OpenBSD builder launcher"\);', pty)
    policy = policy.group().replace('pledge(', 'policyPledge(') if policy else ''
    start = patch.index('     } catch (...) {')
    catch = '\n'.join(line[1:] for line in patch[start:].splitlines()
                      if line.startswith((' ', '+')) and not line.startswith('+++'))
    catch = catch[:catch.index('\n}')]
    descriptors = args.descriptor_source.read_text()
    start = descriptors.index('void unix::closeExtraFDs()')
    descriptors = descriptors[start:descriptors.index('\nvoid unix::closeOnExec(', start)]
    descriptors = descriptors.replace('closefrom(', 'descriptorClosefrom(')

    with tempfile.TemporaryDirectory(prefix='sandbox-helpers-') as temporary:
        work = Path(temporary)
        work.chmod(0o755)
        (work / 'nix/util').mkdir(parents=True)
        (work / 'nix/util/error.hh').write_text('''#pragma once
#include <stdexcept>
namespace nix {
using Error = std::runtime_error;
using SysError = std::runtime_error;
}
''')
        for name in ['sysv-ipc.cc', 'sysv-ipc.hh']:
            code = added_file(sandbox, 'openbsd/build/' + name)
            if name.endswith('.cc'):
                code = 'extern int policyUnveil(const char *, const char *);\n' + code
                code = code.replace('unveil(', 'policyUnveil(')
            (work / name).write_text(code)
        source = args.template.read_text().replace('// SUPERVISOR', supervisor)
        source = source.replace('// IPC_CALLER', caller)
        source = source.replace('// IPC_TRANSACTION', transaction)
        source = source.replace('// CHILD_CATCH', catch)
        source = source.replace('// SUPERVISION_STATE', state)
        source = source.replace('// LAUNCHER_POLICY', policy)
        source = source.replace('// CLOSE_EXTRA_FDS', descriptors)
        source = source.replace('if (unveil("/", "")', 'if (policyUnveil("/", "")')
        source = source.replace('|| unveil(nullptr, nullptr)', '|| policyUnveil(nullptr, nullptr)')
        (work / 'probe.cc').write_text(source)
        executable = work / 'probe'
        subprocess.run([args.cxx, '-std=c++23', '-Wall', '-Wextra', '-Werror',
                        *shlex.split(os.environ.get('CXXFLAGS', '')), '-I' + str(work),
                        str(work / 'probe.cc'), str(work / 'sysv-ipc.cc'), '-o', str(executable),
                        *shlex.split(os.environ.get('LDFLAGS', ''))], check=True)
        writable = work / 'writable'
        writable.mkdir()
        writable.chmod(0o777)
        fixture = writable / 'readable'
        fixture.write_text('public fixture\n')
        fixture.chmod(0o644)
        Path(str(fixture) + '.denied').write_text('not executable\n')
        Path(str(fixture) + '.format').write_text('not an executable format\n')
        Path(str(fixture) + '.interpreter').write_text('#!/no-such-interpreter\n')
        script = Path(str(fixture) + '.script')
        script.write_text('#!' + args.shell + '\nexec ' + shlex.join([
            str(executable), 'post-exec', str(fixture), args.user, 'launcher-script']) + '\n')
        for suffix in ['.format', '.interpreter', '.script']:
            Path(str(fixture) + suffix).chmod(0o755)
        cases = ['pty-success', 'pty-exit', 'pty-signal', 'pty-output', 'pty-interrupt',
                 'pty-paths', 'pty-lock', 'pty-fds', 'pty-pledge-drain',
                 'ipc-cleanup', 'ipc-paths', 'ipc-lock', 'ipc-fds',
                 'unveil-lock-only', 'unveil-empty', 'unveil-fds', 'unveil-fork',
                 'pty-fail-rule', 'pty-fail-lock', 'pty-prelocked', 'pty-highfd',
                 'ipc-fail-rule', 'ipc-fail-lock', 'ipc-prelocked', 'ipc-highfd', 'ipc-flags-failure',
                 'unveil-mutations', 'unveil-inherited-rule',
                 'drain-pledged', 'drain-attributes',
                 'launcher-success', 'launcher-missing', 'launcher-open', 'launcher-socket',
                 'launcher-fork', 'launcher-denied', 'launcher-format', 'launcher-interpreter',
                 'launcher-too-large', 'launcher-pledge-failure', 'launcher-payload',
                 'launcher-script', 'launcher-exit', 'launcher-signal', 'launcher-output',
                 'pty-fork-failure', 'pty-builtin',
                 'fds-ordinary', 'fds-soft-limit', 'fds-hard-limit', 'fds-empty',
                 'fds-chroot', 'fds-exec', 'fds-interrupted', 'fds-closed-stdin']
        failed = []
        for case in cases:
            try:
                result = subprocess.run([executable, case, fixture, args.user], capture_output=True,
                                        text=True, timeout=15, cwd=writable)
            except subprocess.TimeoutExpired:
                failed.append(case)
                print('FAIL ' + case + ': timed out', flush=True)
                continue
            if result.returncode:
                failed.append(case)
                print('FAIL ' + case + ': ' + result.stderr.strip(), flush=True)
            else:
                print('PASS ' + case, flush=True)
        if failed:
            raise SystemExit('Failed helper probes: ' + ', '.join(failed))


if __name__ == '__main__':
    main()
