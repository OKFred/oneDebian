"""Managed-browser focus decisions; no real browser, GUI or process is touched."""
import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

if sys.platform != 'linux':
    raise unittest.SkipTest('The workstation browser helper uses Linux account validation')
source = Path(__file__).resolve().parents[1] / 'agent'
sys.path.insert(0, str(source))
spec = importlib.util.spec_from_file_location('agent_focus_browser', source / 'focus-browser.py')
focus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(focus)


class FocusBrowserTests(unittest.TestCase):
    def setUp(self):
        self.config = dict(user='agent', home='/home/agent')
        self.control = mock.Mock()
        self.factory = mock.patch.object(focus, 'Verifier', return_value=self.control)
        self.factory.start()
        self.addCleanup(self.factory.stop)

    def test_existing_page_is_activated_after_identity_verification_without_new_profile(self):
        self.control.cdp.side_effect = [dict(targetInfos=[
            dict(type='service_worker', targetId='worker', url='http://fixture.invalid'),
            dict(type='page', targetId='blank', url='about:blank'),
            dict(type='page', targetId='work', url='http://fixture.invalid')]), {}]
        self.assertEqual(focus.focus_browser(self.config, {}), 'work')
        self.control.browser_ready.assert_called_once()
        self.assertEqual(self.control.method_calls, [
            mock.call.browser_ready(), mock.call.cdp('Target.getTargets'),
            mock.call.cdp('Target.activateTarget', {'targetId': 'work'})])
        self.assertFalse(self.control.manual())

    def test_existing_blank_page_is_reused(self):
        self.control.cdp.side_effect = [dict(targetInfos=[dict(type='page', targetId='blank', url='about:blank')]), {}]
        self.assertEqual(focus.focus_browser(self.config, {}), 'blank')
        self.assertNotIn('Target.createTarget', [call.args[0] for call in self.control.cdp.call_args_list])

    def test_no_pages_reports_an_error_without_creating_or_navigating_a_tab(self):
        self.control.cdp.return_value = dict(targetInfos=[])
        with self.assertRaisesRegex(RuntimeError, 'no page to focus'):
            focus.focus_browser(self.config, {})
        self.control.cdp.assert_called_once_with('Target.getTargets')

    def test_unready_or_wrong_identity_never_issues_a_focus_or_create_command(self):
        for error in ('Chromium service has no main process', 'CDP browser PID differs from the managed Chromium service'):
            self.control.cdp.reset_mock()
            self.control.browser_ready.side_effect = RuntimeError(error)
            with self.subTest(error=error), self.assertRaisesRegex(RuntimeError, error):
                focus.focus_browser(self.config, {})
            self.control.cdp.assert_not_called()

    def test_probe_configuration_is_not_treated_as_the_working_browser(self):
        with self.assertRaisesRegex(RuntimeError, 'GPU probe is active'):
            focus.focus_browser(dict(self.config, probe_unit='onedebian-agent-gpu-probe.service'), {})
        self.control.browser_ready.assert_not_called()

    def test_failure_is_shown_as_a_gtk_error_without_starting_another_browser(self):
        with mock.patch.object(focus, 'settings', return_value=self.config), \
             mock.patch.object(focus, 'VERSIONS') as versions, \
             mock.patch.object(focus, 'focus_browser', side_effect=RuntimeError('Managed browser unavailable')), \
             mock.patch.object(focus, 'show_error') as dialog:
            versions.read_text.return_value = '{}'
            self.assertEqual(focus.main(), 1)
        dialog.assert_called_once()
        self.assertIn('Managed browser unavailable', str(dialog.call_args.args[0]))

    def test_launcher_points_to_the_focus_helper(self):
        desktop=(source/'desktop/agent-browser.desktop').read_text()
        self.assertIn('Name=Agent 工作浏览器', desktop)
        self.assertIn('Exec=/usr/bin/python3 /opt/onedebian-agent/focus-browser.py', desktop)
        self.assertIn('Terminal=false', desktop)
        self.assertNotIn('--user-data-dir', desktop)


if __name__ == '__main__':
    unittest.main()
