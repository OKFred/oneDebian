"""Managed-browser focus decisions; no real browser, GUI or process is touched."""
import importlib.util
import sys
import subprocess
import types
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
        starter = mock.patch.object(focus, 'ensure_browser')
        self.starter = starter.start()
        self.addCleanup(starter.stop)

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

    def test_links_create_new_tabs_in_the_verified_browser_and_preserve_existing_pages(self):
        pages={'old':'https://existing.invalid/work'}
        active=[]
        def cdp(method,params):
            if method=='Target.createTarget':
                target='new-'+str(len(pages))
                pages[target]=params['url']
                return {'targetId':target}
            if method=='Target.activateTarget':
                active.append(params['targetId'])
                return {}
            raise AssertionError('Existing pages must not be navigated or closed: '+method)
        self.control.cdp.side_effect=cdp
        urls=['https://example.invalid/a?literal=$(echo)&q=%22quoted%22','http://[::1]:3000/']
        self.assertEqual(focus.focus_browser(self.config,{},urls),'new-2')
        self.control.browser_ready.assert_called_once()
        self.assertEqual(pages,{'old':'https://existing.invalid/work','new-1':urls[0],'new-2':urls[1]})
        self.assertEqual(active,['new-2'])
        self.assertEqual(self.control.method_calls[0],mock.call.browser_ready())

    def test_all_links_are_validated_before_identity_queries_or_any_cdp_action(self):
        invalid=['javascript:alert(1)','data:text/html,hello','file:///etc/passwd','ftp://example.invalid',
                 'http:///missing-host','https://','http://[::1','https://example.invalid:70000/',
                 'chrome://settings','chrome://gpu?query=1','about:config',' https://example.invalid',
                 'https://example.invalid/has space','https://example.invalid/\npath',
                 'https://example.invalid/\x00path','https://example.invalid/\x7fpath',None,'']
        for value in invalid:
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError,'HTTP/HTTPS'):
                focus.focus_browser(self.config,{},['https://valid.invalid',value])
        focus.Verifier.assert_not_called()
        self.starter.assert_not_called()
        self.control.cdp.assert_not_called()

    def test_supported_network_and_diagnostic_urls_remain_literal(self):
        for url in ['https://example.invalid/path?q=1#part','HTTP://localhost:3000/',
                    'https://例子.测试/路径','http://[::1]:3000/',
                    'about:blank','chrome://gpu','chrome://gpu/','chrome://version','chrome://version/']:
            with self.subTest(url=url): self.assertEqual(focus.browser_url(url),url)

    def test_single_link_and_cli_arguments_use_the_same_verified_browser(self):
        self.control.cdp.side_effect=[{'targetId':'new'},{}]
        self.assertEqual(focus.focus_browser(self.config,{},['https://example.invalid']),'new')
        self.assertEqual(self.control.cdp.call_args_list,[
            mock.call('Target.createTarget',{'url':'https://example.invalid'}),
            mock.call('Target.activateTarget',{'targetId':'new'})])
        with mock.patch.object(focus,'settings',return_value=self.config), \
             mock.patch.object(focus,'VERSIONS') as versions, \
             mock.patch.object(focus,'focus_browser') as opener, \
             mock.patch.object(focus.sys,'argv',['focus-browser.py','https://one.invalid','https://two.invalid']):
            versions.read_text.return_value='{}'
            self.assertEqual(focus.main(),0)
        opener.assert_called_once_with(self.config,{},['https://one.invalid','https://two.invalid'])

    def test_no_pages_reports_an_error_without_creating_or_navigating_a_tab(self):
        self.control.cdp.return_value = dict(targetInfos=[])
        with self.assertRaisesRegex(RuntimeError, 'no page to focus'):
            focus.focus_browser(self.config, {})
        self.control.cdp.assert_called_once_with('Target.getTargets')

    def test_unready_or_wrong_identity_never_issues_a_focus_or_create_command(self):
        for error in ('Chromium service has no main process', 'CDP browser PID differs from the managed Chromium service'):
            for urls in ([],['https://example.invalid']):
                self.control.cdp.reset_mock()
                self.control.browser_ready.side_effect = RuntimeError(error)
                with self.subTest(error=error,urls=urls), self.assertRaisesRegex(RuntimeError, error):
                    focus.focus_browser(self.config, {}, urls)
                self.control.cdp.assert_not_called()

    def test_probe_configuration_is_not_treated_as_the_working_browser(self):
        with self.assertRaisesRegex(RuntimeError, 'GPU probe is active'):
            focus.focus_browser(dict(self.config, probe_unit='onedebian-agent-gpu-probe.service'), {})
        self.control.browser_ready.assert_not_called()
        self.starter.assert_not_called()

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
        self.assertIn('Exec=/usr/bin/python3 /opt/onedebian-agent/focus-browser.py %u', desktop)
        self.assertIn('Terminal=false', desktop)
        self.assertIn('MimeType=x-scheme-handler/http;x-scheme-handler/https;', desktop)
        self.assertIn('Categories=Network;WebBrowser;', desktop)
        self.assertNotIn('text/html', desktop)
        self.assertNotIn('--user-data-dir', desktop)


class BrowserStartTests(unittest.TestCase):
    def status(self, active='inactive', pid='0', loaded='loaded'):
        return types.SimpleNamespace(stdout=f'LoadState={loaded}\nActiveState={active}\nMainPID={pid}\n')

    def test_stopped_or_failed_service_uses_only_the_fixed_privileged_start_helper(self):
        for active in ('inactive', 'failed'):
            with self.subTest(active=active), mock.patch.object(focus.subprocess, 'run',
                    side_effect=[self.status(active), types.SimpleNamespace(returncode=0)]) as command:
                focus.ensure_browser()
            self.assertEqual(command.call_count, 2)
            self.assertEqual(command.call_args.args[0], ['/usr/bin/sudo', '-n', '--', '/usr/bin/python3', '-I',
                                                        '/opt/onedebian-agent/start-browser.py'])
            self.assertTrue(command.call_args.kwargs['check'])

    def test_active_and_starting_services_are_never_restarted(self):
        for active, pid in [('active', '12'), ('reloading', '12'), ('activating', '0')]:
            with self.subTest(active=active), mock.patch.object(focus.subprocess, 'run',
                    return_value=self.status(active, pid)) as command:
                focus.ensure_browser()
            command.assert_called_once()
            self.assertEqual(command.call_args.args[0][0:2], ['/usr/bin/systemctl', 'show'])

    def test_missing_stopping_and_inconsistent_services_are_not_started(self):
        cases = [('inactive', '0', 'not-found'), ('deactivating', '12', 'loaded'),
                 ('unknown', '0', 'loaded'), ('inactive', '12', 'loaded'),
                 ('active', '0', 'loaded'), ('inactive', 'unknown', 'loaded')]
        for active, pid, loaded in cases:
            with self.subTest(active=active, pid=pid, loaded=loaded), \
                 mock.patch.object(focus.subprocess, 'run', return_value=self.status(active, pid, loaded)) as command:
                with self.assertRaises(RuntimeError): focus.ensure_browser()
            command.assert_called_once()

    def test_start_denial_and_timeouts_offer_a_root_recovery_without_retrying(self):
        for error in [subprocess.CalledProcessError(1, focus.START_BROWSER, stderr='A password is required'),
                      subprocess.TimeoutExpired(focus.START_BROWSER, 45)]:
            with self.subTest(error=error), mock.patch.object(focus.subprocess, 'run',
                    side_effect=[self.status(), error]) as command:
                with self.assertRaisesRegex(RuntimeError, 'journalctl -u onedebian-agent-chromium.service'):
                    focus.ensure_browser()
            self.assertEqual(command.call_count, 2)


if __name__ == '__main__':
    unittest.main()
