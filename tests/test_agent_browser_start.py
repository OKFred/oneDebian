"""Fixed privileged browser starts against private files and command stubs only."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

if sys.platform != 'linux':
    raise unittest.SkipTest('The privileged browser starter is Linux-only')
source = Path(__file__).resolve().parents[1] / 'agent'
spec = importlib.util.spec_from_file_location('agent_browser_start', source / 'start-browser.py')
starter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(starter)


@unittest.skipUnless(os.geteuid() == 0, 'Root-owned temporary fixtures need the isolated root test environment')
class BrowserStartTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.installer = mock.Mock()
        for name in ('ROOT', 'ETC', 'STATE'):
            path = self.base / name.lower()
            path.mkdir()
            setattr(self.installer, name, path)
        self.installer.OWNER = 'oneDebian-agent-v1'
        self.installer.operation_lock.side_effect = lambda: contextlib.nullcontext()
        self.installer.active.return_value = False
        self.installer.read_json.side_effect = lambda path, default=None: json.loads(path.read_text())
        self.installer.pwd.getpwnam.return_value = types.SimpleNamespace(pw_name='agent', pw_uid=1000, pw_dir='/home/agent')
        self.unit_path = self.base / starter.UNIT
        self.unit_path.write_text('[Service]\nUser=agent\nExecStart=/opt/onedebian-agent/runtime.py chromium\n')
        patch = mock.patch.object(starter, 'UNIT_PATH', self.unit_path)
        patch.start()
        self.addCleanup(patch.stop)
        self.write(self.installer.ETC / 'config.json', {'user': 'agent', 'home': '/home/agent'})
        self.write(self.installer.STATE / 'installed.json', {'owner': self.installer.OWNER})
        self.write(self.installer.STATE / 'state.json', {'state': 'READY_GPU'})
        self.write(self.installer.STATE / 'files.json', {str(self.unit_path): hashlib.sha256(self.unit_path.read_bytes()).hexdigest()})
        self.browser = dict(LoadState='loaded', ActiveState='inactive', MainPID='0', FragmentPath=str(self.unit_path), DropInPaths='')
        self.desktop = dict(LoadState='loaded', ActiveState='active', MainPID='123', FragmentPath='/etc/systemd/system/' + starter.DESKTOP, DropInPaths='')
        self.installer.capture.side_effect = lambda argv, **kwargs: '\n'.join(k + '=' + v for k, v in (self.browser if argv[2] == starter.UNIT else self.desktop).items())

    def write(self, path, value):
        path.write_text(json.dumps(value))

    def test_cleanly_stopped_or_failed_browser_starts_only_exact_unit(self):
        for state in ('inactive', 'failed'):
            with self.subTest(state=state):
                self.installer.run.reset_mock()
                self.browser['ActiveState'] = state
                self.assertTrue(starter.start_browser(self.installer))
                self.installer.run.assert_called_once_with(['systemctl', 'start', starter.UNIT], timeout=30)
                self.assertEqual(self.installer.capture.call_args.kwargs['timeout'], 5)
        self.installer.cleanup._trusted.assert_called_with(self.installer)

    def test_active_or_starting_browser_is_never_restarted(self):
        for state in ('active', 'activating', 'reloading'):
            with self.subTest(state=state):
                self.browser.update(ActiveState=state, MainPID='456')
                self.assertFalse(starter.start_browser(self.installer))
        self.installer.run.assert_not_called()

    def test_busy_operation_lock_refuses_without_querying_or_starting_services(self):
        self.installer.operation_lock.side_effect = RuntimeError('Another Agent installation or cleanup is running')
        with self.assertRaisesRegex(RuntimeError, 'Another Agent'):
            starter.start_browser(self.installer)
        self.installer.capture.assert_not_called()
        self.installer.run.assert_not_called()

    def test_modified_unowned_or_overridden_unit_is_rejected(self):
        self.unit_path.write_text('modified')
        with self.assertRaisesRegex(RuntimeError, 'modified or unowned'):
            starter.start_browser(self.installer)
        self.write(self.installer.STATE / 'files.json', {str(self.unit_path): hashlib.sha256(self.unit_path.read_bytes()).hexdigest()})
        for changes in ({'DropInPaths': '/etc/systemd/system/example.conf'}, {'FragmentPath': '/run/other.service'}):
            original = dict(self.browser)
            self.browser.update(changes)
            with self.subTest(changes=changes), self.assertRaisesRegex(RuntimeError, 'override'):
                starter.start_browser(self.installer)
            self.browser = original
        self.installer.run.assert_not_called()

    def test_missing_desktop_and_inconsistent_browser_never_start(self):
        for changes in ({'LoadState': 'not-found'}, {'ActiveState': 'deactivating'}, {'MainPID': '999'}, {'MainPID': 'unknown'}):
            original = dict(self.browser)
            self.browser.update(changes)
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                starter.start_browser(self.installer)
            self.browser = original
        self.desktop.update(ActiveState='inactive', MainPID='0')
        with self.assertRaisesRegex(RuntimeError, 'desktop is not running'):
            starter.start_browser(self.installer)
        self.installer.run.assert_not_called()

    def test_installation_and_account_boundaries_are_checked(self):
        for state in ('ERROR', 'PACKAGES', 'UNINSTALLED', 'CLEANED'):
            self.write(self.installer.STATE / 'state.json', {'state': state})
            with self.subTest(state=state), self.assertRaisesRegex(RuntimeError, 'incomplete or uninstalled'):
                starter.start_browser(self.installer)
        self.write(self.installer.STATE / 'state.json', {'state': 'READY_SOFTWARE'})
        self.installer.active.return_value = True
        with self.assertRaisesRegex(RuntimeError, 'installation is active'):
            starter.start_browser(self.installer)
        self.installer.active.return_value = False
        self.installer.pwd.getpwnam.return_value.pw_uid = 0
        with self.assertRaisesRegex(RuntimeError, 'Unexpected Agent'):
            starter.start_browser(self.installer)
        self.installer.run.assert_not_called()

    def test_arguments_and_nonroot_fail_before_import_or_action(self):
        for argv, uid in ((['start-browser.py', 'anything'], 0), (['start-browser.py'], 1000)):
            with self.subTest(argv=argv, uid=uid), mock.patch.object(starter.sys, 'argv', argv), \
                    mock.patch.object(starter.os, 'geteuid', return_value=uid), \
                    mock.patch.object(starter, 'load_installer') as loader, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(starter.main(), 1)
                loader.assert_not_called()

    def test_bootstrap_refuses_writable_source_cache_and_symlink(self):
        with mock.patch.object(starter, 'ROOT', self.installer.ROOT):
            for name in ('install', 'runtime', 'cleanup', 'package_undo'):
                (self.installer.ROOT / (name + '.py')).write_text('# fixture\n')
            source_file = self.installer.ROOT / 'install.py'
            source_file.chmod(0o666)
            with self.assertRaisesRegex(RuntimeError, 'Untrusted'):
                starter.load_installer()
            source_file.chmod(0o644)
            cache = self.installer.ROOT / '__pycache__'
            cache.mkdir()
            bytecode = Path(importlib.util.cache_from_source(str(source_file)))
            bytecode.write_bytes(b'unused fixture')
            bytecode.chmod(0o666)
            with self.assertRaisesRegex(RuntimeError, 'Untrusted'):
                starter.load_installer()
            bytecode.unlink()
            bytecode.symlink_to(source_file)
            with self.assertRaisesRegex(RuntimeError, 'Untrusted'):
                starter.load_installer()


if __name__ == '__main__':
    unittest.main()
