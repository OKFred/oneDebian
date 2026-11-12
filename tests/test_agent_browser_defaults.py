"""XFCE/default-browser integration using disposable files only."""
import contextlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

source = Path(__file__).resolve().parents[1] / 'agent'
sys.path.insert(0, str(source))
spec = importlib.util.spec_from_file_location('agent_browser_install', source / 'install.py')
install = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = install
spec.loader.exec_module(install)


class BrowserDefaultTests(unittest.TestCase):
    def test_xfce_browser_changes_only_the_global_browser_key(self):
        original = '# choices\nWebBrowser=chromium\nTerminalEmulator=xfce4-terminal\n[Other]\nWebBrowser=keep\n'
        updated = install.browser_preference(original, 'WebBrowser', 'agent-browser')
        self.assertEqual(updated, original.replace('WebBrowser=chromium', 'WebBrowser=agent-browser'))
        self.assertEqual(install.browser_preference(updated, 'WebBrowser', 'agent-browser'), updated)

    def test_mime_browser_preserves_other_defaults_and_associations(self):
        original = '[Default Applications]\ntext/plain=mousepad.desktop;\nx-scheme-handler/http=chromium.desktop\n\n[Added Associations]\nx-scheme-handler/http=firefox.desktop;\n'
        updated = install.browser_preference(original, 'x-scheme-handler/http', 'agent-browser.desktop', 'Default Applications')
        updated = install.browser_preference(updated, 'x-scheme-handler/https', 'agent-browser.desktop', 'Default Applications')
        self.assertIn('text/plain=mousepad.desktop;', updated)
        self.assertIn('[Added Associations]\nx-scheme-handler/http=firefox.desktop;', updated)
        self.assertIn('x-scheme-handler/http=agent-browser.desktop\n', updated)
        self.assertIn('x-scheme-handler/https=agent-browser.desktop\n', updated)
        self.assertNotIn('text/html', updated)

    def test_missing_sections_and_unterminated_lines_remain_parseable(self):
        self.assertEqual(install.browser_preference(None, 'WebBrowser', 'agent-browser'), 'WebBrowser=agent-browser\n')
        self.assertEqual(install.browser_preference('TerminalEmulator=keep', 'WebBrowser', 'agent-browser'),
                         'TerminalEmulator=keep\nWebBrowser=agent-browser\n')
        result = install.browser_preference('[Other]\nx=y', 'x-scheme-handler/http', 'agent-browser.desktop', 'Default Applications')
        self.assertEqual(result, '[Other]\nx=y\n\n[Default Applications]\nx-scheme-handler/http=agent-browser.desktop\n')

    def test_ambiguous_defaults_are_rejected(self):
        for text, section in [('WebBrowser=a\nWebBrowser=b\n', None),
                              ('[Default Applications]\na=b\n[Default Applications]\nc=d\n', 'Default Applications')]:
            with self.subTest(text=text), self.assertRaisesRegex(RuntimeError, 'Duplicate'):
                install.browser_preference(text, 'WebBrowser', 'agent-browser', section)

    def test_default_setup_registers_both_helpers_and_journals_shared_preferences(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / '.config/xfce4').mkdir(parents=True)
            original = 'TerminalEmulator=keep\r\nWebBrowser=chromium\r\n'
            (home / '.config/xfce4/helpers.rc').write_bytes(original.encode())
            generic = '[Default Applications]\nx-scheme-handler/http=other-desktop.desktop\n'
            (home / '.config/mimeapps.list').write_text(generic)
            xfce = '[Default Applications]\nx-scheme-handler/http=chromium.desktop\nimage/png=viewer.desktop\n'
            (home / '.config/xfce-mimeapps.list').write_text(xfce)
            user = types.SimpleNamespace(pw_dir=str(home))
            with mock.patch.object(install, 'ROOT', source), \
                 mock.patch.object(install, 'user_files', side_effect=lambda _: contextlib.nullcontext()), \
                 mock.patch.object(install, 'owned_file') as owned, \
                 mock.patch.object(install.cleanup, 'set_browser_defaults') as journal:
                install.default_browser(user)
            self.assertEqual([call.args[0] for call in owned.call_args_list], [
                home / '.local/share/applications/agent-browser.desktop', home / '.local/share/xfce4/helpers/agent-browser.desktop'])
            changes = journal.call_args.args[2]
            self.assertEqual(changes[home / '.config/xfce4/helpers.rc'][0], original)
            self.assertIn('TerminalEmulator=keep\r\n', changes[home / '.config/xfce4/helpers.rc'][1])
            self.assertEqual(changes[home / '.config/xfce-mimeapps.list'][0], xfce)
            self.assertIn('x-scheme-handler/http=agent-browser.desktop\n', changes[home / '.config/xfce-mimeapps.list'][1])
            self.assertIn('image/png=viewer.desktop\n', changes[home / '.config/xfce-mimeapps.list'][1])
            self.assertNotIn(home / '.config/mimeapps.list', changes)
            self.assertEqual((home / '.config/mimeapps.list').read_text(), generic)

    def test_desktop_launchers_also_register_the_preferred_browser(self):
        with tempfile.TemporaryDirectory() as directory:
            user = types.SimpleNamespace(pw_dir=directory)
            with mock.patch.object(install, 'ROOT', source), \
                 mock.patch.object(install, 'user_files', side_effect=lambda _: contextlib.nullcontext()), \
                 mock.patch.object(install, 'owned_file'), \
                 mock.patch.object(install, 'install_browser_start'), \
                 mock.patch.object(install, 'default_browser') as preferred:
                install.desktop_launchers(user)
            preferred.assert_called_once_with(user)
        helper = (source / 'xfce/agent-browser.desktop').read_text()
        self.assertIn('Type=X-XFCE-Helper', helper)
        self.assertIn('X-XFCE-Category=WebBrowser', helper)
        self.assertIn('X-XFCE-Commands=/usr/bin/python3 /opt/onedebian-agent/focus-browser.py;', helper)
        self.assertIn('focus-browser.py "%s";', helper)

    def test_modified_browser_preferences_block_uninstall_before_any_service_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / '.owner').write_text(install.OWNER)
            real_path = Path
            def path(*parts):
                result = real_path(*parts)
                return base / result.relative_to('/') if result.is_absolute() else result
            with mock.patch.object(install, 'STATE', base), \
                 mock.patch.object(install, 'Path', side_effect=path), \
                 mock.patch.object(install, 'require_root'), \
                 mock.patch.object(install, 'active', return_value=False), \
                 mock.patch.object(install.cleanup, 'restore_browser_defaults', return_value=['modified preference']), \
                 mock.patch.object(install.subprocess, 'run') as command:
                with self.assertRaisesRegex(RuntimeError, 'Default browser preferences changed'):
                    install.uninstall(types.SimpleNamespace(yes=True))
            command.assert_not_called()

    def test_uninstall_does_not_race_another_browser_operation(self):
        with tempfile.TemporaryDirectory() as directory, \
             mock.patch.object(install, 'STATE', Path(directory)), \
             mock.patch.object(install, 'require_root'), \
             mock.patch.object(install, '_uninstall') as remove:
            with install.operation_lock():
                with self.assertRaisesRegex(RuntimeError, 'Another Agent'):
                    install.uninstall(types.SimpleNamespace(yes=True))
            remove.assert_not_called()


if __name__ == '__main__':
    unittest.main()
