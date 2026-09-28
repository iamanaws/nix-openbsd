"""Check that rebuilding never activates after a failed build."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RebuildTests(unittest.TestCase):
    def test_build_and_activation(self):
        script = Path(__file__).parents[2] / 'modules/system/rebuild.sh'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            (root / 'system/bin').mkdir(parents=True)

            def executable(path, text):
                path.write_text('#!' + shutil.which('bash') + '\nset -eu\n' + text)
                path.chmod(0o755)

            executable(root / 'bin/id', 'echo "${TEST_UID:-0}"\n')
            executable(root / 'bin/nix', '''
printf '%s\n' "$@" > build-args
test "${FAIL_BUILD:-0}" = 0
ln -sfn "$PWD/system" result-system
''')
            executable(root / 'system/bin/switch-to-configuration',
                       'printf "%s\\n" "$@" > activated\n')
            env = os.environ | {'PATH': str(root / 'bin') + ':' + os.environ['PATH'],
                                'generation_manager': str(root / 'bin/generation-manager')}

            def run(action, **extra):
                return subprocess.run(['bash', str(script.resolve()), action, '--flake',
                                       './a directory#my-openbsd'], cwd=root,
                                      env=env | extra, capture_output=True, text=True)

            self.assertEqual(run('build', TEST_UID='1000').returncode, 0)
            self.assertFalse((root / 'activated').exists())
            self.assertEqual((root / 'build-args').read_text().splitlines(), [
                'build', '--out-link', 'result-system',
                './a directory#nixosConfigurations.my-openbsd.config.system.build.toplevel'])
            self.assertNotEqual(run('switch', FAIL_BUILD='1').returncode, 0)
            self.assertFalse((root / 'activated').exists())
            self.assertNotEqual(run('switch', TEST_UID='1000').returncode, 0)
            self.assertFalse((root / 'activated').exists())
            self.assertEqual(run('test').returncode, 0)
            self.assertEqual((root / 'activated').read_text(), 'test\n')

    def test_generation_commands(self):
        script = Path(__file__).parents[2] / 'modules/system/rebuild.sh'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bin').mkdir()

            def executable(name, text):
                path = root / 'bin' / name
                path.write_text('#!' + shutil.which('bash') + '\nset -eu\n' + text)
                path.chmod(0o755)

            executable('id', 'echo "${TEST_UID:-0}"\n')
            executable('nix', 'touch unexpected-build; exit 1\n')
            executable('generation-manager', 'printf "%s\\n" "$@" > manager-args; exit "${MANAGER_STATUS:-0}"\n')
            env = os.environ | {'PATH': str(root / 'bin') + ':' + os.environ['PATH'],
                                'generation_manager': str(root / 'bin/generation-manager')}

            def run(*args, **extra):
                (root / 'manager-args').unlink(missing_ok=True)
                return subprocess.run(['bash', str(script.resolve()), *args], cwd=root,
                                      env=env | extra, capture_output=True, text=True)

            cases = [
                (['list-generations'], ['list']),
                (['list'], ['list']),
                (['switch', '--rollback'], ['rollback', '--live']),
                (['--rollback', 'boot'], ['rollback']),
            ]
            for action in ('switch', 'boot', 'test', 'dry-activate'):
                cases.append(([action, '--store-path', './a directory'],
                              [action, './a directory']))
            for args, expected in cases:
                with self.subTest(args=args):
                    self.assertEqual(run(*args).returncode, 0)
                    self.assertEqual((root / 'manager-args').read_text().splitlines(), expected)
                    self.assertFalse((root / 'unexpected-build').exists())

            for args in (['switch', '--rollback'], ['boot', '--store-path', './system']):
                self.assertNotEqual(run(*args, TEST_UID='1000').returncode, 0)
                self.assertFalse((root / 'manager-args').exists())
            self.assertEqual(run('switch', '--rollback', MANAGER_STATUS='7').returncode, 7)

            invalid = [[], ['rollback'], ['build', '--rollback'], ['test', '--rollback'],
                       ['build', '--store-path', './system'], ['switch', '--store-path'],
                       ['switch', '--rollback', '--flake', '.#test'],
                       ['switch', '--flake', '.#test', '--rollback'],
                       ['switch', '--store-path', './system', '--rollback'],
                       ['list', '--rollback'], ['list-generations', 'switch'],
                       ['switch', '--flake', '.#invalid.name'],
                       ['switch', '--flake', '.#test', 'extra']]
            for args in invalid:
                with self.subTest(args=args):
                    self.assertNotEqual(run(*args).returncode, 0)
                    self.assertFalse((root / 'manager-args').exists())
                    self.assertFalse((root / 'unexpected-build').exists())
            self.assertEqual(run('--help').returncode, 0)


if __name__ == '__main__':
    unittest.main()
