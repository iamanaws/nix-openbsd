"""Exercise recipe transfer and output import with a simulated console guest."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="openbsd-runner-test-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.state = self.work / "state"
        self.state.mkdir()
        self.write_executable("nix-store", '''
import os, pathlib, sys
args = sys.argv[1:]
if '--query' in args:
    print('/nix/store/00000000000000000000000000000000-base')
    if args[-1].endswith('recipes'):
        print('/nix/store/11111111111111111111111111111111-recipes')
elif '--export' in args:
    sys.stdout.buffer.write(b'recipes')
elif '--import' in args:
    assert sys.stdin.buffer.read() == b'outputs'
    print('/nix/store/22222222222222222222222222222222-native')
elif '--add-root' in args:
    pathlib.Path(args[args.index('--add-root')+1]).symlink_to(args[-1])
else:
    raise AssertionError(args)
''')
        self.launcher = self.write_executable("guest", '''
import os, re, sys, urllib.request
print('login:', flush=True)
assert input() == 'root'
print('Password:', flush=True)
assert input() == 'toor'
print('root@guest:~#', flush=True)
command = input()
url = re.search(r'http://[^ ]+', command).group().replace('10.0.2.2', '127.0.0.1')
assert urllib.request.urlopen(url).read() == b'recipes'
print('\\nIMPORT_DONE:0', flush=True)
command = input()
if '--all;' in command:
    export = re.search(r'NATIVE_EXPORT_URL=([^ ]+)', command).group(1).replace('10.0.2.2', '127.0.0.1')
    known = re.search(r'NATIVE_KNOWN_URL=([^ ]+)', command).group(1).replace('10.0.2.2', '127.0.0.1')
    assert b'-base' in urllib.request.urlopen(known).read()
    if not os.environ.get('SKIP_EXPORT'):
        request = urllib.request.Request(export, data=b'outputs', method='PUT')
        assert urllib.request.urlopen(request).status == 200
print('\\nTEST_DONE:0', flush=True)
assert input() == 'shutdown -p now'
''')

    def write_executable(self, name, text):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + text.lstrip())
        path.chmod(0o755)
        return path

    def run_runner(self, *flags, skip_export=False):
        env = os.environ | {
            'PATH': str(self.bin) + os.pathsep + os.environ['PATH'],
            'OPENBSD_VM_TIMEOUT': '10',
        }
        if skip_export:
            env['SKIP_EXPORT'] = '1'
        return subprocess.run([
            sys.executable, str(Path(__file__).with_name('run.py')),
            str(self.launcher), '/nix/store/11111111111111111111111111111111-recipes',
            '--state-dir', str(self.state), *flags,
        ], env=env, text=True, capture_output=True, timeout=20)

    def test_all_imports_and_roots_outputs(self):
        result = self.run_runner('--all')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        root = self.state / 'outputs/22222222222222222222222222222222-native'
        self.assertTrue(root.is_symlink())
        self.assertFalse((self.state / 'native-outputs.nar').exists())
        self.assertFalse((self.state / 'recipes.nar').exists())

    def test_existing_mode_needs_no_export(self):
        result = self.run_runner('--nix')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.state / 'outputs').exists())

    def test_stale_export_cannot_pass_a_new_run(self):
        (self.state / 'native-outputs.nar').write_bytes(b'outputs')
        result = self.run_runner('--all', skip_export=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Guest did not export native outputs', result.stderr)
        self.assertTrue(self.state.exists())


if __name__ == '__main__':
    unittest.main()
