"""Browser-start authorization against disposable paths and command stubs."""
import contextlib
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

source = Path(__file__).resolve().parents[1] / 'agent'
sys.path.insert(0, str(source))
spec = importlib.util.spec_from_file_location('agent_browser_start_install', source / 'install.py')
install = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = install
spec.loader.exec_module(install)


class BrowserStartInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        for name in ('ROOT', 'ETC', 'STATE'):
            path = self.base / name.lower()
            path.mkdir()
            self.stack.enter_context(mock.patch.object(install, name, path))
        self.rule = self.base / 'system/etc/sudoers.d/onedebian-agent-browser'
        self.stack.enter_context(mock.patch.object(install, 'BROWSER_SUDOERS', self.rule))
        self.sudo = self.base / 'sudo'
        self.visudo = self.base / 'visudo'
        self.sudo.touch()
        self.visudo.touch()
        original_path = Path
        def path(value, *parts):
            mapped = {'/usr/bin/sudo': self.sudo, '/usr/sbin/visudo': self.visudo}
            return mapped.get(str(value), original_path(value, *parts))
        self.stack.enter_context(mock.patch.object(install, 'Path', side_effect=path))

    def test_fixed_rule_is_validated_before_install_and_repeat_is_owned(self):
        def validate(argv, **kwargs):
            self.assertEqual(argv[:2], ['/usr/sbin/visudo', '-cf'])
            candidate = argv[2]
            self.assertEqual(stat.S_IMODE(candidate.stat().st_mode), 0o600)
            self.assertEqual(candidate.stat().st_uid, os.geteuid())
            self.assertEqual(candidate.read_text(),
                'agent ALL=(root) NOPASSWD: NOSETENV: /usr/bin/python3 -I /opt/onedebian-agent/start-browser.py\n')
        with mock.patch.object(install, 'run', side_effect=validate) as run, \
             mock.patch.object(install.package_undo, 'prepare') as packages:
            install.install_browser_start()
            install.install_browser_start()
        self.assertEqual(run.call_count, 2)
        packages.assert_not_called()
        self.assertEqual(stat.S_IMODE(self.rule.stat().st_mode), 0o440)
        self.assertEqual(self.rule.stat().st_uid, os.geteuid())
        manifest = install.read_json(install.STATE / 'files.json')
        self.assertEqual(manifest[str(self.rule)], hashlib.sha256(self.rule.read_bytes()).hexdigest())
        self.assertEqual(list(install.STATE.glob('sudoers-browser-*')), [])

    @unittest.skipUnless(shutil.which('visudo'), 'visudo is needed for the isolated syntax check')
    def test_real_visudo_accepts_the_root_owned_fixture(self):
        with mock.patch.object(install, 'run', side_effect=lambda argv, **kwargs:
                               subprocess.run(argv, check=True, capture_output=True, text=True)):
            install.install_browser_start()
        self.assertEqual(stat.S_IMODE(self.rule.stat().st_mode), 0o440)
        if os.geteuid() == 0:
            self.assertEqual(self.rule.stat().st_uid, 0)

    def test_invalid_candidate_retains_the_existing_rule(self):
        with mock.patch.object(install, 'run'):
            install.install_browser_start()
        original = self.rule.read_bytes()
        with mock.patch.object(install, 'run', side_effect=subprocess.CalledProcessError(1, ['visudo'])):
            with self.assertRaises(subprocess.CalledProcessError):
                install.install_browser_start()
        self.assertEqual(self.rule.read_bytes(), original)
        self.assertEqual(list(install.STATE.glob('sudoers-browser-*')), [])

    def test_unowned_and_modified_rules_are_not_replaced(self):
        self.rule.parent.mkdir(parents=True)
        self.rule.write_text('# user managed\n')
        with mock.patch.object(install, 'run'):
            with self.assertRaisesRegex(RuntimeError, 'unowned file'):
                install.install_browser_start()
        self.assertEqual(self.rule.read_text(), '# user managed\n')
        self.rule.unlink()
        with mock.patch.object(install, 'run'):
            install.install_browser_start()
            self.rule.chmod(0o640)
            self.rule.write_text('# modified\n')
            with self.assertRaisesRegex(RuntimeError, 'unowned file'):
                install.install_browser_start()
        self.assertEqual(self.rule.read_text(), '# modified\n')

    def test_missing_sudo_installs_only_sudo_with_package_undo(self):
        self.sudo.unlink()
        with mock.patch.object(install, 'run') as command, \
             mock.patch.object(install.package_undo, 'prepare') as prepare, \
             mock.patch.object(install.package_undo, 'install_args', side_effect=lambda _i, argv: argv) as tracked, \
             mock.patch.object(install.package_undo, 'finish') as finish:
            install.install_browser_start()
        prepare.assert_called_once_with(install)
        finish.assert_called_once_with(install)
        apt = tracked.call_args.args[1]
        self.assertEqual(apt[:2], ['apt-get', 'install'])
        self.assertEqual(apt[-1], 'sudo')
        self.assertNotIn('update', apt)
        self.assertNotIn('upgrade', apt)
        self.assertEqual(command.call_args_list[0].args[0], apt)
        self.assertIn('sudo', install.PACKAGES)

    def test_sudo_install_failure_finishes_tracking_without_granting_access(self):
        self.visudo.unlink()
        with mock.patch.object(install, 'run', side_effect=subprocess.CalledProcessError(1, ['apt-get'])), \
             mock.patch.object(install.package_undo, 'prepare'), \
             mock.patch.object(install.package_undo, 'install_args', side_effect=lambda _i, argv: argv), \
             mock.patch.object(install.package_undo, 'finish') as finish:
            with self.assertRaises(subprocess.CalledProcessError):
                install.install_browser_start()
        finish.assert_called_once_with(install)
        self.assertFalse(self.rule.exists())

    def test_install_and_desktop_update_share_authorization_setup(self):
        user = types.SimpleNamespace(pw_dir=str(self.base / 'home'))
        with mock.patch.object(install, 'install_browser_start') as permission, \
             mock.patch.object(install, 'default_browser'), \
             mock.patch.object(install, 'user_files', return_value=contextlib.nullcontext()):
            install.desktop_launchers(user)
        permission.assert_called_once_with()

    def test_cleanup_allows_only_the_exact_sudoers_file(self):
        with mock.patch.object(install.cleanup, 'BASE', self.base / 'system'):
            self.assertTrue(install.cleanup._allowed(install, self.rule))
            self.assertFalse(install.cleanup._allowed(install, self.rule.with_name('other')))
            self.assertFalse(install.cleanup._allowed(install, self.rule.parent))


if __name__ == '__main__':
    unittest.main()
