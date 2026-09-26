"""Test boot transaction failures without touching the host's profiles or boot files."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


class BootTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ('nix/store', 'nix/var/nix/profiles', 'boot/nixos', 'run', 'bin'):
            (self.root / directory).mkdir(parents=True)
        self.profile = self.root / 'nix/var/nix/profiles/system'
        self.a = self.system('a')
        self.b = self.system('b')
        self.profile.with_name('system-1-link').symlink_to(self.a)
        self.profile.symlink_to('system-1-link')
        (self.root / 'run/current-system').symlink_to(self.a)
        self.default = self.root / 'boot/nixos/default.conf'
        self.default.write_text(f'set image {self.a}/kernel\n')
        script = (Path(__file__).parents[2] / 'modules/system/generations.sh').read_text()
        script = re.sub(r'(?<![\w/])/(?:nix|boot|run|var)\b',
                        lambda match: str(self.root) + match[0], script)
        self.script = self.root / 'manager.sh'
        self.script.write_text(script)
        self.executable('id', 'echo 0')
        self.executable('sync', ':')
        self.executable('nix-store', '''
case "$1" in
    --query) echo "$3" ;;
    --add-root) ln -s "$4" "$2" ;;
esac
''')
        self.executable('nix-env', '''
profile=$2; action=$3; value=${4:-}
if test "$action" = --set; then
    number=1
    while test -e "$profile-$number-link"; do number=$((number + 1)); done
    ln -s "$value" "$profile-$number-link"
else
    number=$value
fi
ln -sfn "system-$number-link" "$profile"
''')
        self.env = os.environ | {'PATH': str(self.root / 'bin') + ':' + os.environ['PATH']}

    def executable(self, name, body):
        path = self.root / 'bin' / name
        path.write_text('#!' + shutil.which('bash') + '\nset -eu\n' + body + '\n')
        path.chmod(0o755)

    def system(self, name):
        path = self.root / 'nix/store' / name
        (path / 'bin').mkdir(parents=True)
        (path / 'system').write_text('x86_64-openbsd')
        (path / 'kernel').touch()
        (path / 'bin/activate-init-native').touch(mode=0o755)
        return path

    def run_manager(self, *args, success=True):
        result = subprocess.run(['bash', str(self.script), *map(str, args)],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_boot_and_rollback_preserve_running_system(self):
        self.run_manager('boot', self.b)
        self.assertEqual(self.profile.resolve(), self.b)
        self.assertIn(str(self.b), self.default.read_text())
        self.assertEqual((self.root / 'run/current-system').resolve(), self.a)
        self.run_manager('rollback')
        self.assertEqual(self.profile.resolve(), self.a)
        self.assertIn(str(self.a), self.default.read_text())
        self.assertTrue(self.profile.with_name('system-2-link').exists())

    def test_failed_boot_file_commit_restores_profile(self):
        old = self.default.read_text()
        self.executable('mv', 'exit 1')
        self.run_manager('boot', self.b, success=False)
        self.assertEqual(self.profile.resolve(), self.a)
        self.assertEqual(self.default.read_text(), old)
        self.assertFalse((self.root / 'run/openbsd-system.lock').exists())

    def test_invalid_system_does_not_change_selection(self):
        (self.b / 'system').write_text('x86_64-linux')
        self.run_manager('boot', self.b, success=False)
        self.assertEqual(self.profile.resolve(), self.a)

    def test_lock_prevents_concurrent_selection(self):
        (self.root / 'run/openbsd-system.lock').mkdir()
        self.run_manager('boot', self.b, success=False)
        self.assertEqual(self.profile.resolve(), self.a)


if __name__ == '__main__':
    unittest.main()
