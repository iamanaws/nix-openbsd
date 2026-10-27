"""Check focused selection, CI failures and the native fixture transfer protocol."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.request import Request, urlopen
from xml.etree import ElementTree as ET

import prepare

spec = importlib.util.spec_from_file_location('project_tests', Path(__file__).with_name('run.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SelectionTests(unittest.TestCase):
    def test_focused_suites_exclude_unrequested_work(self):
        args = runner.arguments(['--suite', 'dns'])
        self.assertEqual(runner.select_suites(args), ['dns'])
        args = runner.arguments(['--suite', 'dns', '--suite', 'local', '--suite', 'dns'])
        self.assertEqual(runner.select_suites(args), ['dns', 'local'])

    def test_regular_and_all_selections(self):
        regular = runner.select_suites(runner.arguments([]))
        self.assertEqual(set(regular), set(runner.REGULAR))
        self.assertFalse(set(regular) & set(runner.NATIVE))
        for flag in ['--all', '--full']:
            all_suites = runner.select_suites(runner.arguments([flag]))
            self.assertEqual(set(all_suites), set(regular) | {'native'})
            self.assertEqual(len(all_suites), len(set(all_suites)))

    def test_all_and_focus_cannot_silently_override_each_other(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            runner.arguments(['--all', '--suite', 'dns'])

    def test_live_only_requires_explicit_generation_suites(self):
        for argv in [['--all'], [], ['--suite', 'packages'], ['--suite', 'dns', '--suite', 'local']]:
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                runner.arguments([*argv, '--live-only'])
        args = runner.arguments(['--suite', 'dns', '--suite', 'generations', '--live-only'])
        self.assertEqual(runner.select_suites(args), ['dns', 'generations'])
        self.assertTrue(args.live_only)

    def test_listing_needs_no_nix_or_vm(self):
        with patch.object(runner, 'Runtime', side_effect=AssertionError('Unexpected test run')):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(runner.main(['--list']), 0)
        self.assertIn('dns', output.getvalue())

    def test_focused_runtime_forwards_live_only_and_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            args = runner.arguments(['--suite', 'dns', '--live-only', '--timeout', '1200'])
            runtime = runner.Runtime(args, ['dns'], work)
            runtime.launcher = Path('/launcher')
            with patch.object(runtime, 'ensure_prepared', return_value={'base': '/base', 'dns': '/dns'}), \
                 patch.object(runtime, 'command') as command:
                runtime.run_suite('dns', work / 'dns.log')
            argv = command.call_args.args[0]
            self.assertIn('--live-only', argv)
            self.assertEqual(argv[argv.index('--timeout') + 1], '1200')
            self.assertEqual(argv[argv.index('--dns-fixtures') + 1], Path('/dns'))


class ReportTests(unittest.TestCase):
    def test_failure_survives_a_later_pass(self):
        class Runtime:
            source = '/test/source'

            def run_suite(self, name, log):
                log.touch()
                if name == 'dns':
                    raise RuntimeError('DNS failed')

        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            with contextlib.redirect_stdout(io.StringIO()):
                code = runner.run_suites(Runtime(), ['dns', 'local'], work)
            self.assertEqual(code, 1)
            report = json.loads((work / 'results.json').read_text())
            self.assertEqual(report['result'], 'failed')
            self.assertEqual([r['result'] for r in report['suites']], ['failed', 'passed'])
            xml = ET.parse(work / 'junit.xml').getroot()
            self.assertEqual(xml.attrib['failures'], '1')
            self.assertEqual(xml.find('testcase/failure').attrib['message'], 'DNS failed')


class PreparationTests(unittest.TestCase):
    def prepare(self, work, upload=True):
        target = '/nix/store/' + 'a' * 32 + '-dns-fixtures'

        class Guest:
            def __init__(self, *_):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def run(self, command, _):
                url = re.search(r'http://[^ ]+', command).group().replace('10.0.2.2', '127.0.0.1')
                script = urlopen(url).read().decode()
                subprocess.run(['bash', '-n'], input=script, text=True, check=True)
                self_check.assertIn('nativeTargets.dns', script)
                self_check.assertNotIn('nativeTargets.generations', script)
                self_check.assertNotIn(' -A ', script)
                if upload:
                    request = Request(url.rsplit('/', 1)[0] + '/outputs.nar', data=b'NAR', method='PUT')
                    self_check.assertEqual(urlopen(request).status, 200)

        self_check = self
        with patch.object(prepare, 'Guest', Guest), \
             patch.object(prepare.subprocess, 'check_output', return_value=''), \
             patch.object(prepare.subprocess, 'run') as run:
            # The fake guest checks the generated shell using the real Bash.
            real_run = subprocess.Popen

            def command(args, **kwargs):
                if args[:2] == ['bash', '-n']:
                    process = real_run(args, stdin=subprocess.PIPE)
                    process.communicate(kwargs['input'].encode())
                    self.assertEqual(process.returncode, 0)
                elif '--import' in args:
                    self.assertEqual(kwargs['stdin'].read(), b'NAR')

            run.side_effect = command
            prepare.prepare(Path('/source'), Path('/launcher'), work, {'dns': target}, 10)
        return target

    def test_native_outputs_are_imported_and_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory) / 'build'
            target = self.prepare(work)
            self.assertEqual(json.loads((work / 'results.json').read_text()), {'dns': target})
            self.assertFalse((work / 'outputs.nar').exists())

    def test_missing_export_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory) / 'build'
            with self.assertRaisesRegex(RuntimeError, 'did not export'):
                self.prepare(work, upload=False)
            self.assertFalse((work / 'results.json').exists())


if __name__ == '__main__':
    unittest.main()
