"""Offline tests never start a desktop, install packages or touch user profiles."""
from email.message import Message
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('onedebian_runtime', ROOT / 'agent/runtime.py')
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


def config(home='/home/agent'):
    return dict(user='agent', home=home, uid=1001, display=':10', viewer_port=16080,
                mcp_port=18931, cdp_port=19222, render_node='')


def headers(*items):
    result = Message()
    for key, value in items:
        result[key] = value
    return result


class RuntimeTests(unittest.TestCase):
    def test_private_desktop_unix_socket_no_network_vnc(self):
        command = runtime.desktop_command(config())
        self.assertEqual(command[command.index('-rfbport') + 1], '-1')
        self.assertEqual(command[command.index('-rfbunixmode') + 1], '0600')
        self.assertEqual(command[command.index('-rfbunixpath') + 1].replace('\\', '/'), '/run/user/1001/onedebian-agent/vnc.sock')
        self.assertEqual(command[command.index('-rendernode') + 1], '')
        with self.assertRaises(RuntimeError):
            runtime.desktop_command(dict(config(), render_node='/dev/dxg'))
        self.assertIn('/dev/dri/renderD129', runtime.desktop_command(dict(config(), render_node='/dev/dri/renderD129')))

    def test_runtime_env_uses_normal_bus_and_clears_wslg(self):
        with mock.patch.dict(os.environ, {'WAYLAND_DISPLAY': 'wayland-0', 'DISPLAY': ':0',
                                          'XDG_RUNTIME_DIR': '/mnt/wslg/runtime-dir'}):
            env = runtime.environment(config())
        self.assertNotIn('WAYLAND_DISPLAY', env)
        self.assertEqual(env['DISPLAY'], ':10')
        self.assertEqual(env['XDG_RUNTIME_DIR'], '/run/user/1001')
        self.assertEqual(env['DBUS_SESSION_BUS_ADDRESS'], 'unix:path=/run/user/1001/bus')

    def test_chromium_sandbox_session_restore_and_own_profile(self):
        command = [value.replace('\\', '/') for value in runtime.chromium_command(config())]
        self.assertIn('--restore-last-session', command)
        self.assertIn('--remote-debugging-address=127.0.0.1', command)
        self.assertIn('--remote-debugging-port=19222', command)
        self.assertNotIn('--no-sandbox', command)
        self.assertFalse(any('password-store=basic' in flag for flag in command))
        self.assertIn('--user-data-dir=/home/agent/.local/share/onedebian-agent/profile', command)

    def test_probe_profile_cannot_escape_owned_probe_directory(self):
        for path in ['/tmp/profile', '/home/agent/.local/share/onedebian-agent/profile',
                     '/home/agent/.local/share/onedebian-agent/probes/../profile']:
            with self.assertRaises(RuntimeError):
                runtime.profile_path(dict(config(), probe_profile=path))
        with tempfile.TemporaryDirectory() as temporary:
            expected = Path(temporary) / '.local/share/onedebian-agent/probes/probe-123'
            self.assertEqual(runtime.profile_path(dict(config(temporary), probe_profile=str(expected))), expected)

    def test_only_first_browser_launch_opens_committed_blank_page(self):
        with tempfile.TemporaryDirectory() as temporary:
            settings = config(temporary)
            self.assertEqual(runtime.chromium_command(settings)[-1], 'about:blank')
            profile = runtime.profile_path(settings)
            profile.mkdir(parents=True)
            (profile / 'Local State').write_text('{}')
            self.assertNotIn('about:blank', runtime.chromium_command(settings))
            self.assertIn('--restore-last-session', runtime.chromium_command(settings))

    def test_preferences_written_before_first_launch_and_existing_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = Path(temporary) / 'profile'
            def directory(path):
                path.mkdir(parents=True, exist_ok=True)
                return path
            with mock.patch.object(runtime, 'private_dir', side_effect=directory):
                runtime.initialize_profile(profile)
                prefs = profile / 'Default/Preferences'
                self.assertEqual(json.loads(prefs.read_text())['session']['restore_on_startup'], 1)
                prefs.write_text('{"existing":"keep"}')
                runtime.initialize_profile(profile)
                self.assertEqual(prefs.read_text(), '{"existing":"keep"}')

    def test_fnm_uses_recorded_exact_version_and_never_npx(self):
        with mock.patch.object(runtime, 'VERSIONS') as path:
            path.read_text.return_value = '{"node":"v26.13.0"}'
            command = runtime.mcp_command(config())
            self.assertIn('--using=v26.13.0', command)
            self.assertIn('--fnm-dir', command)
            self.assertIn('--cdp-endpoint', command)
            self.assertIn('http://127.0.0.1:19222', command)
            self.assertIn('--shared-browser-context', command)
            self.assertNotIn('npx', command)
            path.read_text.return_value = '{"node":"26"}'
            with self.assertRaises(RuntimeError):
                runtime.mcp_command(config())

    def test_manual_marker_treats_any_existing_path_as_pause(self):
        with mock.patch.object(runtime.os.path, 'lexists', return_value=True):
            self.assertTrue(runtime.manual(config()))
        with mock.patch.object(runtime.os.path, 'lexists', return_value=False):
            self.assertFalse(runtime.manual(config()))

    def test_disable_idle_lock_only_uses_the_private_user_environment(self):
        env = runtime.environment(config())
        with mock.patch.object(runtime.subprocess, 'run', return_value=mock.Mock(returncode=1)) as execute:
            runtime.configure_private_desktop(env)
        self.assertTrue(any('/lock/enabled' in call.args[0] for call in execute.call_args_list))
        self.assertTrue(any('/xfce4-power-manager/inactivity-on-ac' in call.args[0] for call in execute.call_args_list))
        self.assertTrue(all(call.kwargs['env'] is env for call in execute.call_args_list))

    def test_takeover_keeps_marker_on_failure_and_does_not_stop_chromium(self):
        with tempfile.TemporaryDirectory() as temporary:
            cfg = config(temporary)
            directory = Path(temporary)
            with mock.patch.object(runtime, 'private_dir', return_value=directory), \
                 mock.patch.object(runtime.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'stop')) as execute:
                with self.assertRaises(subprocess.CalledProcessError):
                    runtime.handoff(cfg, True)
                self.assertTrue((directory / 'manual').is_file())
                self.assertEqual(execute.call_args.args[0], ['systemctl', '--user', 'stop', runtime.MCP_UNIT])

    def test_token_is_not_present_in_status(self):
        with mock.patch.object(runtime.subprocess, 'run', return_value=mock.Mock(stdout='active\n')), \
             mock.patch.object(runtime, 'manual', return_value=False), \
             mock.patch.object(runtime, 'viewer_token', side_effect=AssertionError('Must never read token')):
            result = runtime.status(config())
        self.assertEqual(result['viewer'], 'http://127.0.0.1:16080/')
        self.assertEqual(result['mcp'], 'http://127.0.0.1:18931/mcp')
        self.assertNotIn('token', json.dumps(result))


class ViewerPolicyTests(unittest.TestCase):
    def setUp(self):
        self.policy = runtime.ViewerPolicy(16080, 'a' * 43)

    def test_exact_one_allowlisted_host(self):
        for name in ['127.0.0.1:16080', 'localhost:16080']:
            self.assertTrue(self.policy.host_allowed(headers(('Host', name))))
        for values in [[], [('Host', '127.0.0.1:16080'), ('Host', '127.0.0.1:16080')],
                       [('Host', 'localhost:16080.evil')], [('Host', '192.168.1.2:16080')]]:
            self.assertFalse(self.policy.host_allowed(headers(*values)))

    def test_origin_must_match_host_no_cross_origin_cookie_use(self):
        self.assertTrue(self.policy.origin_allowed(headers(('Host', 'localhost:16080'), ('Origin', 'http://localhost:16080'))))
        for origins in [[], ['null'], ['http://evil.test'], ['http://127.0.0.1:16080'],
                        ['http://localhost:16080', 'http://localhost:16080']]:
            self.assertFalse(self.policy.origin_allowed(headers(('Host', 'localhost:16080'),
                                                               *[('Origin', value) for value in origins])))

    def test_cookie_requires_session_nonce_not_access_token(self):
        self.assertFalse(self.policy.authenticated(headers()))
        self.assertFalse(self.policy.authenticated(headers(('Cookie', self.policy.cookie_name + '=' + self.policy.token))))
        self.assertTrue(self.policy.authenticated(headers(('Cookie', self.policy.cookie_name + '=' + self.policy.session))))
        self.assertFalse(self.policy.authenticated(headers(('Cookie', self.policy.cookie_name + '=wrong'))))
        self.assertFalse(self.policy.authenticated(headers(('Cookie', self.policy.cookie_name + '=' + self.policy.session),
                                                          ('Cookie', self.policy.cookie_name + '=' + self.policy.session))))
        with mock.patch.object(runtime, 'SimpleCookie', side_effect=runtime.CookieError('bad cookie')):
            self.assertFalse(self.policy.authenticated(headers(('Cookie', 'malformed'))))

    def test_separate_viewer_ports_have_independent_cookies(self):
        other = runtime.ViewerPolicy(16081, 'b' * 43)
        self.assertNotEqual(self.policy.cookie_name, other.cookie_name)
        self.assertFalse(other.authenticated(headers(('Cookie', self.policy.cookie_name + '=' + self.policy.session))))

    def test_viewer_removes_fragment_before_authentication_and_does_not_embed_token(self):
        script = (ROOT / 'agent/viewer/login.js').read_text(encoding='utf-8')
        self.assertLess(script.index('history.replaceState'), script.index("fetch('/auth'"))
        self.assertIn('view_only=1', script)
        self.assertIn('credentials: \'same-origin\'', script)
        self.assertNotIn(self.policy.token, script)


if __name__ == '__main__':
    unittest.main()
