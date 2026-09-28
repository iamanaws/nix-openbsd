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
            env = os.environ | {'PATH': str(root / 'bin') + ':' + os.environ['PATH']}

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


if __name__ == '__main__':
    unittest.main()
