"""Exercise live-switch recovery with controlled service and activation failures."""
import json
from pathlib import Path
import re
import shutil
import unittest
import test_boot


class LiveTests(test_boot.BootTests):
    def setUp(self):
        super().setUp()
        self.running = self.root / 'running'
        self.running.touch()
        self.events = self.root / 'events'
        self.events.touch()
        (self.b / 'kernel').unlink()
        (self.b / 'kernel').symlink_to(self.a / 'kernel')
        (self.a / 'init').touch()
        (self.b / 'init').symlink_to(self.a / 'init')
        live = (Path(__file__).parents[2] / 'modules/system/live.sh').read_text()
        live = re.sub(r'(?<![\w/])/(?:nix|boot|run)\b',
                      lambda match: str(self.root) + match[0], live)
        self.script.write_text(live + '\n' + self.script.read_text())
        for system in (self.a, self.b):
            (system / 'etc/rc.d').mkdir(parents=True)
            (system / 'etc/rc.order').mkdir()
            # NixBSD generates phase files without a final newline.
            (system / 'etc/rc.order/40').write_text('start_daemon app')
            script = system / 'etc/rc.d/app'
            script.write_text(f'''#!{shutil.which('bash')}
echo '{system.name}' "$1" >> {self.events}
case "$1" in
    check) test -f {self.running} ;;
    start) test ! -f {system}/fail-start && touch {self.running} ;;
    reload) test ! -f {system}/fail-reload ;;
    stop) rm {self.running} 2>/dev/null || true ;;
esac
''')
            script.chmod(0o755)
            activate = system / 'activate'
            activate.write_text(f'''#!{shutil.which('bash')}
set -e
echo 'activate {system.name}' >> {self.events}
test "$(readlink -f {self.root}/nix/var/nix/gcroots/openbsd-system.*/current)" = {self.a}
test "$(readlink -f {self.root}/nix/var/nix/gcroots/openbsd-system.*/target)" = {self.b}
ln -sfn {system} {self.root}/run/current-system
test ! -f {system}/fail-activate
''')
            activate.chmod(0o755)
            (system / 'openbsd-system.json').write_text(json.dumps({
                'version': 1, 'boot': {},
                'etc': {'app.conf': str(system / 'config'), 'terminfo': str(system / 'terminfo')},
                'services': {'app': {'script': str(script), 'live': True,
                                    'files': ['app.conf'], 'check': ''}},
            }))

    def test_temporary_activation_keeps_boot_selection(self):
        self.run_manager('test', self.b)
        self.assertEqual((self.root / 'run/current-system').resolve(), self.b)
        self.assertEqual(self.profile.resolve(), self.a)
        self.assertTrue(self.running.exists())

    def test_failed_start_restores_old_system_and_service(self):
        (self.b / 'fail-start').touch()
        self.run_manager('switch', self.b, success=False)
        self.assertEqual((self.root / 'run/current-system').resolve(), self.a)
        self.assertEqual(self.profile.resolve(), self.a)
        self.assertTrue(self.running.exists())
        self.assertIn('activate a', self.events.read_text())

    def test_activation_failure_recovers(self):
        (self.b / 'fail-activate').touch()
        self.run_manager('switch', self.b, success=False)
        self.assertEqual((self.root / 'run/current-system').resolve(), self.a)
        self.assertTrue(self.running.exists())

    def test_failed_boot_commit_restores_live_configuration(self):
        default = self.default.read_text()
        self.executable('mv', 'exit 1')
        self.run_manager('switch', self.b, success=False)
        self.assertEqual((self.root / 'run/current-system').resolve(), self.a)
        self.assertEqual(self.profile.resolve(), self.a)
        self.assertEqual(self.default.read_text(), default)
        self.assertTrue(self.running.exists())

    def test_dry_activation_does_not_stop_or_activate(self):
        self.run_manager('dry-activate', self.b)
        self.assertEqual((self.root / 'run/current-system').resolve(), self.a)
        self.assertNotIn('stop', self.events.read_text())
        self.assertNotIn('activate', self.events.read_text())

    def test_invalid_configuration_does_not_stop_or_activate(self):
        meta = self.b / 'openbsd-system.json'
        content = json.loads(meta.read_text())
        content['services']['app']['check'] = 'false'
        meta.write_text(json.dumps(content))
        self.run_manager('switch', self.b, success=False)
        self.assertEqual(self.events.read_text(), '')
        self.assertEqual((self.root / 'run/current-system').resolve(), self.a)
        self.assertEqual(self.profile.resolve(), self.a)

    def enable_oneshot(self):
        for system in (self.a, self.b):
            meta = system / 'openbsd-system.json'
            content = json.loads(meta.read_text())
            content['services']['app']['oneshot'] = True
            meta.write_text(json.dumps(content))

    def test_oneshot_success_does_not_require_a_running_process(self):
        self.enable_oneshot()
        self.running.unlink()
        # A completed oneshot has no process for rc.d check to find.
        script = self.b / 'etc/rc.d/app'
        script.write_text(script.read_text().replace(f'touch {self.running}', ':'))
        self.run_manager('switch', self.b)
        self.assertFalse(self.running.exists())
        self.assertIn('b start', self.events.read_text())
        self.assertNotIn('b check', self.events.read_text())
        self.assertNotIn('stop', self.events.read_text())

    def test_failed_oneshot_recovers_the_previous_configuration(self):
        self.enable_oneshot()
        self.running.unlink()
        (self.b / 'fail-start').touch()
        self.run_manager('switch', self.b, success=False)
        self.assertEqual((self.root / 'run/current-system').resolve(), self.a)
        self.assertEqual(self.profile.resolve(), self.a)

    def test_unknown_service_change_requires_reboot(self):
        meta = self.b / 'openbsd-system.json'
        content = json.loads(meta.read_text())
        content['services']['app']['live'] = False
        meta.write_text(json.dumps(content))
        self.run_manager('switch', self.b, success=False)
        self.assertEqual(self.events.read_text(), '')

    def enable_reload(self):
        for system in (self.a, self.b):
            meta = system / 'openbsd-system.json'
            content = json.loads(meta.read_text())
            # The daemon script stays the same; only app.conf changes.
            content['services']['app'].update(script='unchanged-rc-script', reload=True)
            meta.write_text(json.dumps(content))

    def test_configuration_reload_keeps_service_running(self):
        self.enable_reload()
        self.run_manager('switch', self.b)
        events = self.events.read_text()
        self.assertIn('b reload', events)
        self.assertNotIn('stop', events)
        self.assertNotIn('start', events)
        self.assertTrue(self.running.exists())
        self.assertEqual(self.profile.resolve(), self.b)

    def test_failed_reload_restores_configuration_without_restart(self):
        self.enable_reload()
        (self.b / 'fail-reload').touch()
        self.run_manager('switch', self.b, success=False)
        events = self.events.read_text()
        self.assertIn('b reload', events)
        self.assertIn('a reload', events)
        self.assertNotIn('stop', events)
        self.assertNotIn('start', events)
        self.assertTrue(self.running.exists())
        self.assertEqual(self.profile.resolve(), self.a)
        self.assertEqual((self.root / 'run/current-system').resolve(), self.a)

    def test_changed_daemon_still_restarts(self):
        self.enable_reload()
        meta = self.b / 'openbsd-system.json'
        content = json.loads(meta.read_text())
        content['services']['app']['flags'] = '--changed'
        meta.write_text(json.dumps(content))
        self.run_manager('switch', self.b)
        events = self.events.read_text()
        self.assertIn('a stop', events)
        self.assertIn('b start', events)
        self.assertNotIn('reload', events)

    def test_configuration_reload_keeps_stopped_service_stopped(self):
        self.enable_reload()
        self.running.unlink()
        self.run_manager('switch', self.b)
        events = self.events.read_text()
        self.assertNotIn('reload', events)
        self.assertNotIn('start', events)
        self.assertFalse(self.running.exists())


if __name__ == '__main__':
    unittest.main()
