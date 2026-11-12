"""Install is a repair operation: private files and stubbed commands only."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

if sys.platform != 'linux':
    raise unittest.SkipTest('Agent convergence uses Linux account and service APIs')
source = Path(__file__).resolve().parents[1] / 'agent'
spec = importlib.util.spec_from_file_location('agent_reinstall', source / 'install.py')
install = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = install
spec.loader.exec_module(install)


def options(**changes):
    result = dict(viewer_port=16080, mcp_port=18931, cdp_port=19222, mirror='keep',
                  allow_low_resources=False, adopt_user=False, wait=False, yes=True)
    return types.SimpleNamespace(**dict(result, **changes))


class ReinstallTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        self.stack = stack
        for name in ('ROOT', 'ETC', 'STATE'):
            directory = self.base / name.lower()
            directory.mkdir()
            stack.enter_context(mock.patch.object(install, name, directory))
            (directory / '.owner').write_text(install.OWNER)
        self.home = self.base / 'home/agent'
        self.home.mkdir(parents=True)
        self.user = types.SimpleNamespace(pw_name='agent', pw_dir=str(self.home), pw_uid=1000, pw_gid=1000)
        self.config = dict(user='agent', home=str(self.home), display=':12', viewer_port=16081,
                           mcp_port=18932, cdp_port=19223, render_node='', gpu_backend='d3d12', keyring_mode='password')
        install.write_json(install.ETC / 'config.json', self.config)
        install.write_json(install.STATE / 'state.json', dict(state='READY_GPU', mirror='tuna', allow_low_resources=True))
        install.write_json(install.STATE / 'installed.json', dict(owner=install.OWNER, installed_at=123))
        install.write_json(install.STATE / 'gpu.json', dict(backend='d3d12', production={'passed': True}))
        self.commands = stack.enter_context(mock.patch.object(install, 'run'))
        stack.enter_context(mock.patch.object(install, 'require_root'))
        stack.enter_context(mock.patch.object(install, 'user_files', side_effect=lambda _: contextlib.nullcontext()))
        stack.enter_context(mock.patch.object(install.package_undo, 'prepare'))
        stack.enter_context(mock.patch.object(install.package_undo, 'finish'))
        stack.enter_context(mock.patch.object(install.package_undo, 'install_args', side_effect=lambda _, argv: argv))
        stack.enter_context(mock.patch.object(install.cleanup, 'tracking', side_effect=lambda _: contextlib.nullcontext()))
        self.inventory = {name: 'installed' for name in install.PACKAGES}
        self.states = {name: ('active', str(pid)) for name, pid in [('desktop', 111), ('chromium', 222), ('novnc', 333), ('mcp', 444)]}
        self.capture = stack.enter_context(mock.patch.object(install, 'capture', side_effect=self.capture_command))
        self.user_control = stack.enter_context(mock.patch.object(install, 'user_ctl', side_effect=self.user_command))

    def capture_command(self, argv):
        if argv[:2] == ['dpkg-query', '-W']:
            return '\n'.join(name + '\tamd64\t' + value for name, value in self.inventory.items())
        if argv == ['dpkg', '--print-architecture']: return 'amd64'
        if argv[:2] == ['systemctl', 'show']: return self.state_output(argv[2])
        raise AssertionError('Unexpected command: ' + repr(argv))

    def state_output(self, unit):
        part = unit.removeprefix('onedebian-agent-').removesuffix('.service')
        state, pid = self.states[part]
        return f'ActiveState={state}\nMainPID={pid}\n'

    def user_command(self, user, *argv, **kwargs):
        if argv[0] == 'show': return types.SimpleNamespace(stdout=self.state_output(argv[1]))
        return types.SimpleNamespace(stdout='')

    def runtime_fixture(self):
        fnm = self.home / '.local/share/fnm/fnm'
        fnm.parent.mkdir(parents=True)
        fnm.write_text('fixture binary; never executed')
        self.node_bin = fnm.parent / 'node-versions' / install.VERSIONS['node'] / 'installation/bin'
        self.node_bin.mkdir(parents=True)
        for binary in ('node', 'pnpm'): (self.node_bin / binary).write_text('fixture; never executed')
        self.runtime_state = {'node': install.VERSIONS['node'], 'pnpm': install.VERSIONS['pnpm']}
        self.tools = self.home / '.local/share/onedebian-agent/tools/node_modules'
        for key, package, entry in [('mcp', '@playwright/mcp', 'cli.js'), ('codex', '@openai/codex', 'bin/codex.js')]:
            self.tool_file(key, package, entry)
        install.write_json(install.ETC / 'versions.json', install.VERSIONS)
        (install.ETC / 'node-version').write_text(install.VERSIONS['node'] + '\n')
        self.runtime_commands = self.stack.enter_context(mock.patch.object(install, 'as_user', side_effect=self.runtime_command))

    def tool_file(self, key, package, entry):
        path = self.tools / package / entry
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('fixture; never executed')
        install.write_json(self.tools / package / 'package.json', {'version': install.VERSIONS[key]})

    def runtime_command(self, user, argv, **kwargs):
        if 'install' in argv:
            if 'npm' not in argv or '@playwright/mcp@' + install.VERSIONS['mcp'] in argv:
                self.assertTrue(install.read_json(install.STATE / 'state.json')['runtime_refresh_pending'])
            if '--global' in argv:
                self.runtime_state['pnpm'] = install.VERSIONS['pnpm']
                (self.node_bin / 'pnpm').write_text('repaired fixture')
            elif '--prefix' in argv:
                for key, package, entry in [('mcp', '@playwright/mcp', 'cli.js'), ('codex', '@openai/codex', 'bin/codex.js')]:
                    if package + '@' + install.VERSIONS[key] in argv: self.tool_file(key, package, entry)
            else:
                self.runtime_state['node'] = install.VERSIONS['node']
                (self.node_bin / 'node').write_text('repaired fixture')
        if argv[-1:] == ['--version']:
            if 'exec' not in argv: value = 'fnm ' + install.VERSIONS['fnm'].removeprefix('v')
            elif Path(argv[-2]).name in ('node', 'pnpm'): value = self.runtime_state[Path(argv[-2]).name]
            elif argv[-2].endswith('/@playwright/mcp/cli.js'): value = 'Version ' + install.VERSIONS['mcp']
            elif argv[-2].endswith('/@openai/codex/bin/codex.js'): value = 'codex-cli ' + install.VERSIONS['codex']
            else: raise AssertionError('Unexpected runtime command: ' + repr(argv))
            if value is None: raise subprocess.CalledProcessError(1, argv)
            return types.SimpleNamespace(stdout=value + '\n')
        return types.SimpleNamespace(stdout='')

    def worker_fixtures(self):
        self.runtime_fixture()
        self.stack.enter_context(mock.patch.object(install, 'user_record', return_value=self.user))
        self.stack.enter_context(mock.patch.object(install, 'services'))
        self.controls = self.stack.enter_context(mock.patch.object(install, 'restart_controls'))
        self.gpu = self.stack.enter_context(mock.patch.object(install, 'verify_gpu'))
        self.stack.enter_context(mock.patch.object(install, 'boot_id', return_value='fixture-boot'))
        self.stack.enter_context(mock.patch.object(install.subprocess, 'run', return_value=types.SimpleNamespace(
            returncode=0, stdout=json.dumps({'passed': True}), stderr='')))

    def test_all_packages_present_needs_no_apt_or_undo_transaction(self):
        self.assertFalse(install.packages(options()))
        self.commands.assert_not_called()
        install.package_undo.prepare.assert_not_called()
        install.package_undo.finish.assert_not_called()

    def test_only_missing_and_unconfigured_required_packages_are_installed(self):
        del self.inventory['chromium']
        self.inventory['pnpm-unrelated'] = 'unpacked'
        self.inventory['fonts-noto-cjk'] = 'unpacked'
        self.assertTrue(install.packages(options()))
        argv = next(call.args[0] for call in self.commands.call_args_list if 'install' in call.args[0])
        self.assertEqual(argv[-2:], ['chromium', 'fonts-noto-cjk'])
        self.assertNotIn('xfce4-session', argv)
        self.assertNotIn('pnpm-unrelated', argv)
        install.package_undo.finish.assert_called_once()

    def test_foreign_architecture_does_not_satisfy_native_dependencies(self):
        self.capture.side_effect = lambda argv: 'amd64' if argv[0] == 'dpkg' else '\n'.join(
            name + ('\ti386\tinstalled' if name == 'libegl1' else '\tall\tinstalled') for name in install.PACKAGES)
        install.packages(options())
        argv = next(call.args[0] for call in self.commands.call_args_list if 'install' in call.args[0])
        self.assertEqual(argv[-1], 'libegl1')
        self.assertNotIn('chromium', argv)

    def test_healthy_runtime_needs_no_download_node_install_or_npm(self):
        self.runtime_fixture()
        self.assertFalse(install.install_runtime(self.user))
        self.commands.assert_not_called()
        self.assertFalse(any('install' in call.args[1] for call in self.runtime_commands.call_args_list))

    def test_missing_runtime_entry_is_repaired_even_with_complete_version_record(self):
        self.runtime_fixture()
        (self.tools / '@playwright/mcp/cli.js').unlink()
        (self.tools / '@playwright/mcp/user-added.txt').write_text('retained user modification')
        self.assertTrue(install.install_runtime(self.user))
        installs = [call.args[1] for call in self.runtime_commands.call_args_list if 'install' in call.args[1]]
        self.assertEqual(len(installs), 1)
        self.assertEqual(installs[0][-1], '@playwright/mcp@' + install.VERSIONS['mcp'])
        self.assertTrue((self.tools / '@playwright/mcp/cli.js').exists())
        retained = list((self.home / '.local/share/onedebian-agent/retained-packages').glob('mcp-*'))
        self.assertEqual(len(retained), 1)
        self.assertEqual(len(list(retained[0].parent.iterdir())), 1)
        self.assertEqual((retained[0] / 'user-added.txt').read_text(), 'retained user modification')
        self.assertFalse(retained[0].is_relative_to(self.tools.parent))

    def test_missing_real_pnpm_binary_is_repaired_without_calling_fallback_wrapper(self):
        self.runtime_fixture()
        (self.node_bin / 'pnpm').unlink()
        self.assertTrue(install.install_runtime(self.user))
        installs = [call.args[1] for call in self.runtime_commands.call_args_list if 'install' in call.args[1]]
        self.assertEqual(installs[0][-2:], ['--global', 'pnpm@' + install.VERSIONS['pnpm']])
        self.assertTrue((self.node_bin / 'pnpm').is_file())
        pnpm_checks = [call.args[1] for call in self.runtime_commands.call_args_list
                       if call.args[1][-1] == '--version' and Path(call.args[1][-2]).name == 'pnpm']
        self.assertEqual(len(pnpm_checks), 1)
        self.assertEqual(pnpm_checks[0][-2], str(self.node_bin / 'pnpm'))

    def test_symlinked_tool_package_is_never_executed_or_moved(self):
        self.runtime_fixture()
        package = self.tools / '@playwright/mcp'
        retained = self.base / 'external-project'
        package.rename(retained)
        package.symlink_to(retained, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'Symlink'):
            install.install_runtime(self.user)
        self.assertTrue(package.is_symlink())
        self.assertTrue((retained / 'cli.js').is_file())
        self.assertFalse(any('install' in call.args[1] for call in self.runtime_commands.call_args_list))

    def test_wrapper_conflict_keeps_external_file_and_old_version_record(self):
        self.runtime_fixture()
        wrappers = self.home / '.local/bin'
        wrappers.mkdir(parents=True)
        (wrappers / 'node').write_text('external wrapper')
        old = {'node': 'old recorded version'}
        install.write_json(install.ETC / 'versions.json', old)
        with self.assertRaisesRegex(RuntimeError, 'wrapper requires review'):
            install.install_runtime(self.user)
        self.assertEqual((wrappers / 'node').read_text(), 'external wrapper')
        self.assertEqual(install.read_json(install.ETC / 'versions.json'), old)

    def test_ready_install_checks_again_and_repairs_missing_pnpm_without_touching_session(self):
        self.worker_fixtures()
        self.runtime_state['pnpm'] = None
        preserved = {'.codex/auth.json': '{"fixture":"authorization"}', '.local/share/keyrings/login.keyring': 'fixture keyring',
                     '.local/share/onedebian-agent/profile/Default/Cookies': 'fixture cookie'}
        for relative, content in preserved.items():
            path = self.home / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        (self.home / '.bashrc').write_text('# user customization\n')
        self.stack.enter_context(mock.patch.object(install, 'active', return_value=False))
        self.stack.enter_context(mock.patch.object(install, 'plan', return_value={'systemd': True, 'warnings': ['low resources']}))
        self.stack.enter_context(mock.patch.object(install, 'prepare_changes', return_value=install))
        self.stack.enter_context(mock.patch.object(install, 'save_payload'))
        self.stack.enter_context(mock.patch.object(install, 'owned_file'))
        install.start_install(options())
        self.assertIn(mock.call(['systemctl', 'start', '--no-block', install.JOB]), self.commands.call_args_list)
        install.worker(options())
        self.assertEqual(self.runtime_state['pnpm'], install.VERSIONS['pnpm'])
        self.assertEqual(install.read_json(install.ETC / 'config.json'), self.config)
        self.assertEqual(install.read_json(install.STATE / 'state.json')['state'], 'READY_GPU')
        self.assertEqual(install.read_json(install.STATE / 'installed.json')['installed_at'], 123)
        self.gpu.assert_not_called()
        self.assertEqual(self.states['desktop'], ('active', '111'))
        self.assertEqual(self.states['chromium'], ('active', '222'))
        for relative, content in preserved.items(): self.assertEqual((self.home / relative).read_text(), content)
        self.assertIn('# user customization\n', (self.home / '.bashrc').read_text())
        self.assertFalse(any('restart' in call.args[0] for call in self.commands.call_args_list))
        self.assertFalse(any(call.args[1:] == ('restart', 'onedebian-agent-mcp.service') for call in self.user_control.call_args_list))
        self.controls.assert_called_once_with(self.config, self.user, only_missing=True)

    def test_interrupted_runtime_retries_through_the_same_install_worker(self):
        self.worker_fixtures()
        self.runtime_state['pnpm'] = None
        before = (install.ETC / 'versions.json').read_bytes()
        def interrupted(user, argv, **kwargs):
            if '--global' in argv: raise subprocess.TimeoutExpired(argv, 600)
            return self.runtime_command(user, argv, **kwargs)
        with mock.patch.object(install, 'as_user', side_effect=interrupted), self.assertRaises(subprocess.TimeoutExpired):
            install.worker(options())
        self.assertEqual(install.read_json(install.STATE / 'state.json')['state'], 'ERROR')
        self.assertFalse(install.read_json(install.STATE / 'state.json').get('runtime_refresh_pending', False))
        self.assertEqual((install.ETC / 'versions.json').read_bytes(), before)
        install.worker(options())
        self.assertEqual(install.read_json(install.STATE / 'state.json')['state'], 'READY_GPU')
        self.assertEqual(self.runtime_state['pnpm'], install.VERSIONS['pnpm'])
        self.gpu.assert_not_called()
        self.assertFalse(any('restart' in call.args[0] for call in self.commands.call_args_list))

    def test_manual_repair_keeps_marker_and_pending_mcp_reload(self):
        self.worker_fixtures()
        (self.tools / '@playwright/mcp/cli.js').unlink()
        marker = self.home / '.local/share/onedebian-agent/manual'
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text('manual retained')
        self.states['mcp'] = ('inactive', '0')
        install.worker(options())
        self.assertEqual(marker.read_text(), 'manual retained')
        self.assertTrue(install.read_json(install.STATE / 'state.json')['runtime_refresh_pending'])
        self.assertFalse(any('onedebian-agent-mcp.service' in call.args for call in self.user_control.call_args_list))
        self.gpu.assert_not_called()

    def test_pending_mcp_reload_survives_runtime_completion_then_worker_interruption(self):
        self.runtime_fixture()
        (self.tools / '@playwright/mcp/cli.js').unlink()
        install.install_runtime(self.user)
        self.assertFalse(install.install_runtime(self.user))
        self.assertTrue(install.read_json(install.STATE / 'state.json')['runtime_refresh_pending'])
        install.ensure_services(self.user, self.config, runtime_changed=True)
        self.user_control.assert_any_call(self.user, 'restart', 'onedebian-agent-mcp.service')
        self.assertNotIn('runtime_refresh_pending', install.read_json(install.STATE / 'state.json'))

    def test_codex_only_repair_does_not_restart_healthy_mcp(self):
        self.worker_fixtures()
        (self.tools / '@openai/codex/bin/codex.js').unlink()
        install.worker(options())
        self.assertTrue((self.tools / '@openai/codex/bin/codex.js').is_file())
        self.assertFalse(install.read_json(install.STATE / 'state.json').get('runtime_refresh_pending', False))
        self.assertFalse(any(call.args[1:] == ('restart', 'onedebian-agent-mcp.service') for call in self.user_control.call_args_list))

    def test_mcp_repair_restarts_only_mcp_using_the_persisted_pending_flag(self):
        self.worker_fixtures()
        (self.tools / '@playwright/mcp/cli.js').unlink()
        install.worker(options())
        self.user_control.assert_any_call(self.user, 'restart', 'onedebian-agent-mcp.service')
        self.assertFalse(install.read_json(install.STATE / 'state.json').get('runtime_refresh_pending', False))
        self.commands.assert_not_called()

    def test_pnpm_and_codex_version_record_changes_do_not_mark_mcp_for_reload(self):
        self.runtime_fixture()
        for key in ('pnpm', 'codex'):
            old = dict(install.VERSIONS, **{key: 'old recorded version'})
            install.write_json(install.ETC / 'versions.json', old)
            with self.subTest(key=key): self.assertTrue(install.install_runtime(self.user))
            self.assertFalse(install.read_json(install.STATE / 'state.json').get('runtime_refresh_pending', False))

    def test_stopped_services_only_are_started_without_restarting_healthy_ones(self):
        self.states.update(chromium=('inactive', '0'), novnc=('failed', '0'))
        self.assertEqual(install.ensure_services(self.user, self.config), ['chromium', 'novnc'])
        self.commands.assert_called_once_with(['systemctl', 'start', 'onedebian-agent-chromium.service'])
        self.user_control.assert_any_call(self.user, 'start', 'onedebian-agent-novnc.service')
        self.assertFalse(any('restart' in call.args for call in self.user_control.call_args_list))

    def test_service_stopping_or_inconsistent_state_is_not_overridden(self):
        for value in [('deactivating', '111'), ('inactive', '111'), ('unknown', '0')]:
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, 'stopping or inconsistent'):
                self.states['desktop'] = value
                install.ensure_services(self.user, self.config)
        self.commands.assert_not_called()

    def test_install_and_resume_share_interrupted_defaults_but_finished_install_keeps_current_mirror(self):
        self.stack.enter_context(mock.patch.object(install, 'start_install', return_value={'state': 'PRECHECK'}))
        for action in ('install', 'resume'):
            for completed in (False, True):
                installed = install.STATE / 'installed.json'
                if completed: install.write_json(installed, {'owner': install.OWNER})
                else: installed.unlink(missing_ok=True)
                with self.subTest(action=action, completed=completed), \
                        mock.patch.object(sys, 'argv', ['agent.sh', action, '--json']), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(install.main(), 0)
                selected = install.start_install.call_args.args[0]
                self.assertEqual(selected.mirror, 'keep' if completed else 'tuna')
                self.assertTrue(selected.allow_low_resources)
        with mock.patch.object(sys, 'argv', ['agent.sh', 'install', '--json', '--mirror=ustc']), contextlib.redirect_stdout(io.StringIO()):
            install.main()
        self.assertEqual(install.start_install.call_args.args[0].mirror, 'ustc')

    def test_prechecked_install_does_not_reapply_initial_free_space_recommendation(self):
        self.stack.enter_context(mock.patch.object(install, 'active', return_value=False))
        self.stack.enter_context(mock.patch.object(install, 'plan', return_value={'systemd': True, 'warnings': ['Disk: less than 32 GiB free']}))
        self.stack.enter_context(mock.patch.object(install, 'prepare_changes', return_value=install))
        self.stack.enter_context(mock.patch.object(install, 'user_record', return_value=self.user))
        self.stack.enter_context(mock.patch.object(install, 'save_payload'))
        self.stack.enter_context(mock.patch.object(install, 'owned_file'))
        self.stack.enter_context(mock.patch.object(install.subprocess, 'run', return_value=types.SimpleNamespace(returncode=1)))
        for state in ('READY_GPU', 'PACKAGES', 'ERROR'):
            if state != 'READY_GPU': (install.STATE / 'installed.json').unlink(missing_ok=True)
            install.write_json(install.STATE / 'state.json', {'state': state, 'allow_low_resources': False})
            with self.subTest(state=state): install.start_install(options())
            self.assertTrue(install.read_json(install.STATE / 'state.json')['precheck_passed'])
        install.write_json(install.STATE / 'state.json', {})
        with self.assertRaisesRegex(RuntimeError, 'allow-low-resources'):
            install.start_install(options())

    def test_status_exposes_existing_guest_ssh_port_without_private_credentials(self):
        install.write_json(install.STATE / 'ssh.json', {'port': 2233, 'host_key': 'public fixture'})
        with mock.patch.object(install, 'active', return_value=False):
            self.assertEqual(install.status()['ssh']['port'], 2233)

    def test_reinstall_preserves_previously_journaled_user_browser_preferences(self):
        preference = self.home / '.config/xfce4/helpers.rc'
        preference.parent.mkdir(parents=True)
        preference.write_text('WebBrowser=user-selected-browser\n')
        install.write_json(install.STATE / install.cleanup.LEDGER, {'browser_defaults': {str(preference): {'before': None}}})
        with mock.patch.object(install, 'ROOT', source), mock.patch.object(install, 'owned_file'), \
                mock.patch.object(install.cleanup, 'set_browser_defaults') as shared:
            install.default_browser(self.user, preserve_preferences=True)
        self.assertEqual(preference.read_text(), 'WebBrowser=user-selected-browser\n')
        self.assertNotIn(preference, shared.call_args.args[2])


if __name__ == '__main__':
    unittest.main()
