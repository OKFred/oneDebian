"""Offline tests never start a desktop, install packages or touch user profiles."""
from email.message import Message
import hashlib
import hmac
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
    def test_new_empty_keyring_is_initialized_before_chromium_can_request_credentials(self):
        for mode in ('empty','manual'):
            events=[]
            initializer=mock.Mock(side_effect=lambda _cfg:events.append('keyring') or {'state':'INITIALIZED'})
            with self.subTest(mode=mode), mock.patch.dict('sys.modules',{'keyring':mock.Mock(ensure_empty=initializer)}), \
                 mock.patch.object(runtime,'wait_x',side_effect=lambda _cfg:events.append('display')), \
                 mock.patch.object(runtime,'initialize_profile',side_effect=lambda _p:events.append('profile')), \
                 mock.patch.object(runtime,'chromium_command',return_value=['chromium']), \
                 mock.patch.object(runtime.os,'execvpe',side_effect=lambda *_args:events.append('browser')):
                runtime.chromium(dict(config(),keyring_mode=mode))
            self.assertEqual(events,['display']+(['keyring'] if mode=='empty' else [])+['profile','browser'])

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

    def test_graphics_backend_is_compatible_with_old_config_and_rejects_dxg_as_drm(self):
        self.assertEqual(runtime.gpu_backend(config()), 'software')
        self.assertEqual(runtime.gpu_backend(dict(config(), render_node='/dev/dri/renderD129')), 'drm')
        for backend, node in [('d3d12', ''), ('software', ''), ('drm', '/dev/dri/renderD129')]:
            self.assertEqual(runtime.gpu_backend(dict(config(), gpu_backend=backend, render_node=node)), backend)
        for backend, node in [('d3d12', '/dev/dxg'), ('drm', '/dev/dxg'), ('d3d12', '/dev/dri/renderD129'),
                              ('software', '/dev/dri/renderD129'), ('drm', ''), ('unknown', ''), ('drm', 3)]:
            with self.subTest(backend=backend, node=node), self.assertRaises(RuntimeError):
                runtime.gpu_backend(dict(config(), gpu_backend=backend, render_node=node))

    @unittest.skipIf(os.name == 'nt', 'Linux ordinary-user configuration validation')
    def test_settings_rejects_backend_conflicts_before_starting_processes(self):
        account = mock.Mock(pw_uid=1001, pw_dir='/home/agent')
        with mock.patch.object(runtime, 'CONFIG') as path, \
             mock.patch('pwd.getpwnam', return_value=account), \
             mock.patch.object(runtime.os, 'getuid', return_value=1001), \
             mock.patch.object(runtime.subprocess, 'run') as execute:
            path.lstat.return_value = mock.Mock(st_mode=runtime.stat.S_IFREG | 0o644, st_uid=0)
            path.read_text.return_value = json.dumps(dict(config(), gpu_backend='d3d12', render_node='/dev/dri/renderD129'))
            with self.assertRaisesRegex(RuntimeError, 'backend'):
                runtime.settings()
            path.read_text.return_value = json.dumps(config())
            self.assertEqual(runtime.settings()['gpu_backend'], 'software')
            execute.assert_not_called()

    def test_graphics_env_is_scoped_and_fallback_removes_hardware_overrides(self):
        inherited = {name: 'inherited-override' for name in runtime.GRAPHICS_VARIABLES}
        with mock.patch.dict(os.environ, inherited):
            for backend, node, expected in [('software', '', {'LIBGL_ALWAYS_SOFTWARE':'true', 'GALLIUM_DRIVER':'llvmpipe'}),
                    ('d3d12', '', {'GALLIUM_DRIVER':'d3d12', 'MESA_D3D12_DEFAULT_ADAPTER_NAME':'Intel'}),
                    ('drm', '/dev/dri/renderD129', {})]:
                with self.subTest(backend=backend):
                    cfg = dict(config(), gpu_backend=backend, render_node=node)
                    env = runtime.environment(cfg)
                    self.assertEqual({key:env[key] for key in runtime.GRAPHICS_VARIABLES if key in env}, expected)
                    self.assertEqual(runtime.graphics_environment(cfg), expected)
                    self.assertEqual(env['DISPLAY'], ':10')
                    self.assertNotIn('WAYLAND_DISPLAY', env)
            self.assertTrue(all(os.environ[name] == value for name, value in inherited.items()))

    def test_d3d12_keeps_the_private_desktop_and_sandboxed_browser(self):
        cfg = dict(config(), gpu_backend='d3d12')
        desktop = runtime.desktop_command(cfg)
        self.assertEqual(desktop[desktop.index('-rendernode') + 1], '')
        self.assertNotIn('/dev/dxg', desktop)
        self.assertEqual(runtime.chromium_command(cfg), runtime.chromium_command(config()))
        self.assertEqual(runtime.profile_path(cfg), runtime.profile_path(config()))

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
        self.assertEqual(result['gpu_backend'], 'software')
        self.assertEqual(result['render_node'], '')
        with mock.patch.object(runtime.subprocess, 'run', return_value=mock.Mock(stdout='active\n')), \
             mock.patch.object(runtime, 'manual', return_value=False):
            accelerated = runtime.status(dict(config(), gpu_backend='d3d12'))
        self.assertEqual(accelerated['gpu_backend'], 'd3d12')
        self.assertEqual(accelerated['render_node'], '')


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

    def test_backend_identity_proves_secret_without_sending_or_revealing_it(self):
        nonce = '0' * 64
        proof = self.policy.identity(nonce)
        message = f'oneDebian-viewer-v1\n16080\n{nonce}'.encode('ascii')
        self.assertEqual(proof, dict(nonce=nonce, proof=hmac.new(self.policy.token.encode('ascii'), message, hashlib.sha256).hexdigest()))
        self.assertNotIn(self.policy.token, json.dumps(proof))
        self.assertNotEqual(proof['proof'], self.policy.identity('1' * 64)['proof'])
        self.assertNotEqual(proof['proof'], runtime.ViewerPolicy(16081, self.policy.token).identity(nonce)['proof'])
        self.assertNotEqual(proof['proof'], runtime.ViewerPolicy(16080, 'z' * 43).identity(nonce)['proof'])
        for invalid in ['', '0' * 63, '0' * 65, 'A' * 64, None]:
            with self.assertRaises(ValueError):
                self.policy.identity(invalid)

    def test_viewer_removes_fragment_before_authentication_and_does_not_embed_token(self):
        script = (ROOT / 'agent/viewer/login.js').read_text(encoding='utf-8')
        self.assertLess(script.index('history.replaceState'), script.index("fetch('/auth'"))
        self.assertIn('view_only=1', script)
        self.assertIn('credentials: \'same-origin\'', script)
        self.assertNotIn(self.policy.token, script)


if __name__ == '__main__':
    unittest.main()
