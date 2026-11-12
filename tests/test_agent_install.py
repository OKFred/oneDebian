"""Installer decisions against disposable files and command stubs only."""
import hashlib
import contextlib
import configparser
import importlib.util
import json
import os
import stat
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

if sys.platform == 'win32':
    sys.modules.setdefault('pwd',types.SimpleNamespace())
spec = importlib.util.spec_from_file_location('agent_install',Path(__file__).resolve().parents[1] / 'agent/install.py')
install = importlib.util.module_from_spec(spec)
spec.loader.exec_module(install)


def options(**changes):
    values = dict(viewer_port=16080,mcp_port=18931,cdp_port=19222,mirror='keep',allow_low_resources=False,
                  adopt_user=False,wait=False,yes=False,new_instance=False,harden_wsl=False)
    values.update(changes)
    return types.SimpleNamespace(**values)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.patches = []
        for key in ['ROOT','ETC','STATE']:
            path = self.base / key.lower(); path.mkdir()
            patch = mock.patch.object(install,key,path); patch.start(); self.patches.append(patch)
            (path / '.owner').write_text(install.OWNER)

    def tearDown(self):
        for patch in reversed(self.patches):
            patch.stop()
        self.temporary.cleanup()

    def test_plan_reports_actual_pid1_and_writes_nothing(self):
        def proc_read(path,*args,**kwargs):
            normalized = path.as_posix()
            if normalized == '/proc/meminfo': return 'MemTotal: 8388608 kB\n'
            if normalized == '/proc/1/comm': return 'init\n'
            if normalized == '/proc/net/unix': return 'Num RefCount Protocol Flags Type St Inode Path\n'
            raise AssertionError('Unexpected file read: ' + normalized)
        with mock.patch.object(install,'require_debian'), mock.patch.object(install,'read_json',side_effect=lambda p,default=None: default), \
             mock.patch.object(install.Path,'read_text',autospec=True,side_effect=proc_read), \
             mock.patch.object(install.os,'cpu_count',return_value=4), \
             mock.patch.object(install.shutil,'disk_usage',return_value=types.SimpleNamespace(free=64*1024**3)), \
             mock.patch.object(install.Path,'glob',return_value=[]), mock.patch.object(install,'atomic') as write, \
             mock.patch.object(install,'run') as command:
            plan = install.plan(options())
        self.assertEqual(plan['state'],'PLAN')
        self.assertFalse(plan['systemd'])
        self.assertFalse(plan['host_driver_changes'])
        self.assertFalse(plan['full_upgrade'])
        self.assertEqual(plan['warnings'],[])
        write.assert_not_called(); command.assert_not_called()

    def test_install_refuses_config_only_systemd_before_any_write(self):
        with mock.patch.object(install,'require_root'), mock.patch.object(install,'plan',return_value={'systemd':False,'warnings':[]}), \
             mock.patch.object(install,'active',return_value=False), \
             mock.patch.object(install,'owned_directories') as write, mock.patch.object(install,'user_record') as user:
            with self.assertRaisesRegex(RuntimeError,'PID 1'):
                install.start_install(options())
        write.assert_not_called(); user.assert_not_called()

    def test_occupied_shared_x_display_uses_the_next_free_number(self):
        sockets = 'Num RefCount Protocol Flags Type St Inode Path\n0000: 2 0 10000 1 1 123 @/tmp/.X11-unix/X10\n'
        with mock.patch.object(install.Path,'read_text',return_value=sockets):
            self.assertEqual(install.config_for(options())['display'],':11')

    def test_port_collision_refuses_creation_and_keeps_other_process(self):
        with mock.patch.object(install,'require_root'), mock.patch.object(install,'plan',return_value={'systemd':True,'warnings':[]}), \
             mock.patch.object(install,'active',return_value=False), mock.patch.object(install,'port_free',return_value=False), \
             mock.patch.object(install,'owned_directories') as write, mock.patch.object(install,'run') as command:
            with self.assertRaisesRegex(RuntimeError,'occupied'):
                install.start_install(options())
        write.assert_not_called(); command.assert_not_called()

    def test_active_install_resume_never_launches_a_second_job(self):
        status = {'state':'PACKAGES','job_active':True}
        with mock.patch.object(install,'require_root'), mock.patch.object(install,'plan',return_value={'systemd':True,'warnings':[]}), \
             mock.patch.object(install,'active',return_value=True), mock.patch.object(install,'status',return_value=status), \
             mock.patch.object(install,'save_payload') as payload, mock.patch.object(install,'run') as command:
            self.assertEqual(install.start_install(options()),status)
        payload.assert_not_called(); command.assert_not_called()

    def test_ready_install_is_idempotent(self):
        install.write_json(install.STATE / 'installed.json',{'owner':install.OWNER})
        status = {'state':'READY_SOFTWARE','job_active':False}
        with mock.patch.object(install,'require_root'), mock.patch.object(install,'plan',return_value={'systemd':True,'warnings':[]}), \
             mock.patch.object(install,'active',return_value=False), mock.patch.object(install,'status',return_value=status), \
             mock.patch.object(install,'owned_directories') as write, mock.patch.object(install,'run') as command:
            self.assertEqual(install.start_install(options()),status)
        write.assert_not_called(); command.assert_not_called()

    def test_user_channel_stop_is_bounded_without_changing_browser_lifetime(self):
        account = types.SimpleNamespace(pw_name='agent',pw_dir=str(self.base/'home/agent'),pw_uid=1000,pw_gid=1000)
        with mock.patch.object(install,'run'), mock.patch.object(install,'user_ctl'), \
             mock.patch.object(install,'owned_file') as generated, \
             mock.patch.object(install,'user_files',return_value=contextlib.nullcontext()):
            install.services(account)
        units = {call.args[0].name:call.args[1] for call in generated.call_args_list}
        for part in ('mcp','novnc'):
            document = configparser.ConfigParser(interpolation=None)
            document.read_string(units[f'onedebian-agent-{part}.service'])
            self.assertEqual(document['Service']['TimeoutStopSec'],'10')
            self.assertEqual(document['Service'].get('KillMode','control-group'),'control-group')
            self.assertNotIn('chromium',document['Service']['ExecStart'])
        for part in ('desktop','chromium'):
            self.assertIn('TimeoutStopSec=30\n',units[f'onedebian-agent-{part}.service'])

    def test_adopting_existing_account_is_explicit(self):
        account = types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000,pw_gid=1000)
        with mock.patch.object(install.pwd,'getpwnam',return_value=account,create=True), mock.patch.object(install,'run') as command:
            with self.assertRaisesRegex(RuntimeError,'adopt-user'):
                install.user_record(False)
            self.assertFalse((install.STATE / 'user-owned').exists())
            self.assertEqual(install.user_record(True),account)
        command.assert_not_called()

    def test_modified_owned_file_is_not_overwritten(self):
        target = self.base / 'service'; target.write_text('locally modified')
        install.write_json(install.STATE / 'files.json',{str(target):hashlib.sha256(b'original').hexdigest()})
        with self.assertRaisesRegex(RuntimeError,'modified'):
            install.owned_file(target,'new service')
        self.assertEqual(target.read_text(),'locally modified')

    def test_unowned_directory_is_not_adopted(self):
        (install.ROOT / '.owner').unlink(); (install.ROOT / 'existing').write_text('private')
        with self.assertRaisesRegex(RuntimeError,'unowned directory'):
            install.owned_directories()
        self.assertEqual((install.ROOT / 'existing').read_text(),'private')

    def test_uninstall_retains_profile_projects_credentials_and_modified_files(self):
        owned = self.base / 'owned-script'; owned.write_text('owned')
        modified = self.base / 'modified-service'; modified.write_text('locally modified')
        data = self.base / 'home/agent/.local/share/onedebian-agent/profile/Default/Cookies'
        data.parent.mkdir(parents=True); data.write_text('synthetic-cookie')
        project = self.base / 'home/agent/workspaces/project/index.js'; project.parent.mkdir(parents=True); project.write_text('project')
        keyring = self.base / 'home/agent/.local/share/keyrings/login.keyring'; keyring.parent.mkdir(parents=True); keyring.write_text('encrypted')
        install.write_json(install.STATE / 'files.json',{str(owned):hashlib.sha256(b'owned').hexdigest(),
            str(modified):hashlib.sha256(b'old service').hexdigest()})
        account = types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000,pw_gid=1000)
        real_path = Path
        def path_factory(value):
            return self.base / 'empty-systemd' / value.rsplit('/',1)[-1] if value in ('/etc/systemd/system','/etc/systemd/user') else real_path(value)
        with mock.patch.object(install,'require_root'), mock.patch.object(install,'active',return_value=False), \
             mock.patch.object(install,'Path',side_effect=path_factory), \
             mock.patch.object(install.pwd,'getpwnam',return_value=account,create=True), \
             mock.patch.object(install.subprocess,'run'), mock.patch.object(install,'run'), mock.patch.object(install,'phase'):
            result = install.uninstall(options(yes=True))
        self.assertFalse(owned.exists()); self.assertTrue(modified.exists())
        self.assertTrue(result['data_retained'])
        self.assertIn(str(modified),result['retained_modified_files'])
        self.assertEqual(data.read_text(),'synthetic-cookie')
        self.assertEqual(project.read_text(),'project')
        self.assertEqual(keyring.read_text(),'encrypted')

    def test_interrupted_phase_requires_resume_not_fake_success(self):
        install.write_json(install.STATE / 'state.json',{'state':'RUNTIME','phase':'RUNTIME'})
        with mock.patch.object(install,'active',return_value=False):
            status = install.status()
        self.assertEqual(status['state'],'INTERRUPTED')
        self.assertFalse(status['job_active'])

    def test_modified_service_prevents_all_uninstall_side_effects(self):
        unit_dir = self.base / 'systemd-system'; unit_dir.mkdir()
        (unit_dir / 'onedebian-agent-desktop.service').write_text('local service override')
        real_path = Path
        def path_factory(value):
            return unit_dir if value == '/etc/systemd/system' else real_path(value)
        with mock.patch.object(install,'Path',side_effect=path_factory), \
             mock.patch.object(install,'require_root'), mock.patch.object(install,'active',return_value=False), \
             mock.patch.object(install.subprocess,'run') as command:
            with self.assertRaisesRegex(RuntimeError,'modified or unowned'):
                install.uninstall(options(yes=True))
        command.assert_not_called()
        self.assertEqual((unit_dir / 'onedebian-agent-desktop.service').read_text(),'local service override')

    def test_required_packages_do_not_trigger_full_upgrade(self):
        with mock.patch.object(install,'run') as command:
            install.packages(options())
        arguments = [call.args[0] for call in command.call_args_list]
        self.assertEqual(len(arguments),2)
        self.assertTrue(any('update' in args for args in arguments))
        self.assertTrue(any('install' in args for args in arguments))
        self.assertFalse(any('upgrade' in args or 'full-upgrade' in args for args in arguments))
        self.assertIn('chromium-sandbox',next(args for args in arguments if 'install' in args))

    def test_owned_home_file_is_deleted_only_with_dropped_privileges(self):
        home = self.base / 'home/agent'
        target = home / 'Desktop/onedebian-takeover.desktop'
        target.parent.mkdir(parents=True); target.write_text('owned desktop launcher')
        install.write_json(install.STATE / 'files.json',{str(target):hashlib.sha256(target.read_bytes()).hexdigest()})
        account = types.SimpleNamespace(pw_name='agent',pw_dir=str(home),pw_uid=1000,pw_gid=1000)
        real_path = Path; real_unlink = Path.unlink; scope = {'active':False,'entries':0}
        def path_factory(value):
            return self.base / 'empty-systemd' / value.rsplit('/',1)[-1] if value in ('/etc/systemd/system','/etc/systemd/user') else real_path(value)
        @contextlib.contextmanager
        def user_scope(user):
            self.assertEqual(user,account)
            scope.update(active=True,entries=scope['entries']+1)
            try: yield
            finally: scope['active'] = False
        def checked_unlink(path,*args,**kwargs):
            if path == target:
                self.assertTrue(scope['active'],'Root must not unlink through user-controlled parent directories')
            return real_unlink(path,*args,**kwargs)
        with mock.patch.object(install,'require_root'), mock.patch.object(install,'active',return_value=False), \
             mock.patch.object(install,'Path',side_effect=path_factory), \
             mock.patch.object(install.pwd,'getpwnam',return_value=account,create=True), \
             mock.patch.object(install,'user_files',side_effect=user_scope), mock.patch.object(Path,'unlink',autospec=True,side_effect=checked_unlink), \
             mock.patch.object(install.subprocess,'run'), mock.patch.object(install,'run'), mock.patch.object(install,'phase'):
            install.uninstall(options(yes=True))
        self.assertFalse(target.exists()); self.assertEqual(scope['entries'],1)

    @unittest.skipUnless(sys.platform == 'linux','Linux DRM permissions')
    def test_gpu_rejects_non_drm_and_privileged_groups_without_granting_access(self):
        account = types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000,pw_gid=1000)
        for mode,major,gid,group in [(stat.S_IFREG,226,0,'root'),(stat.S_IFCHR,1,107,'render'),
                                     (stat.S_IFCHR,226,0,'root'),(stat.S_IFCHR,226,998,'docker')]:
            node = mock.Mock(); node.lstat.return_value = types.SimpleNamespace(st_mode=mode|0o660,st_rdev=1,st_gid=gid)
            with self.subTest(mode=mode,major=major,gid=gid), \
                 mock.patch.object(install.os,'major',return_value=major), \
                 mock.patch.object(install.os,'access',return_value=False), \
                 mock.patch.object(install,'user_files',return_value=contextlib.nullcontext()), \
                 mock.patch('grp.getgrgid',return_value=types.SimpleNamespace(gr_name=group)), \
                 mock.patch.object(install,'run') as command:
                with self.assertRaises(RuntimeError):
                    install.gpu_access(account,node)
                command.assert_not_called()
        config = {'render_node':''}
        with mock.patch.object(install.Path,'glob',return_value=[self.base/'renderD130']), \
             mock.patch.object(install,'gpu_access',side_effect=RuntimeError('refusing root group')), \
             mock.patch.object(install,'start_desktop') as desktop, mock.patch.object(install.subprocess,'run'), \
             mock.patch.object(install,'write_json') as write:
            install.verify_gpu(config,account)
        desktop.assert_not_called()
        evidence = next(call.args[1] for call in write.call_args_list if call.args[0] == install.STATE/'gpu.json')
        self.assertEqual(evidence['mode'],'software')
        self.assertFalse(evidence['attempts'][0]['gpu']['passed'])
        self.assertEqual(config['render_node'],'')

    @unittest.skipUnless(sys.platform == 'linux','Linux DRM permissions')
    def test_gpu_existing_user_access_requires_no_group_lookup_or_change(self):
        account = types.SimpleNamespace(pw_name='agent',pw_uid=1000,pw_gid=1000)
        node = mock.Mock(); node.lstat.return_value = types.SimpleNamespace(st_mode=stat.S_IFCHR|0o666,st_rdev=1,st_gid=0)
        with mock.patch.object(install.os,'major',return_value=226), mock.patch.object(install.os,'access',return_value=True) as access, \
             mock.patch.object(install,'user_files',return_value=contextlib.nullcontext()), \
             mock.patch('grp.getgrgid') as group, mock.patch.object(install,'run') as command:
            install.gpu_access(account,node)
        access.assert_called_once_with(node,os.R_OK|os.W_OK,effective_ids=True)
        group.assert_not_called(); command.assert_not_called()

    @unittest.skipUnless(sys.platform == 'linux','Linux DRM permissions')
    def test_gpu_grants_only_render_group_to_the_selected_agent_user(self):
        account = types.SimpleNamespace(pw_name='agent',pw_uid=1000,pw_gid=1000)
        node = mock.Mock(); node.lstat.return_value = types.SimpleNamespace(st_mode=stat.S_IFCHR|0o660,st_rdev=1,st_gid=107)
        scope = {'active':False}
        @contextlib.contextmanager
        def user_scope(user):
            self.assertEqual(user,account); scope['active'] = True
            try: yield
            finally: scope['active'] = False
        attempts = iter([False,True])
        def access(path,mode,*,effective_ids):
            self.assertTrue(scope['active'],'DRM access must be checked under the agent identity')
            self.assertTrue(effective_ids)
            return next(attempts)
        with mock.patch.object(install.os,'major',return_value=226), mock.patch.object(install.os,'access',side_effect=access), \
             mock.patch.object(install.os,'getgrouplist',return_value=[1000]), \
             mock.patch.object(install,'user_files',side_effect=user_scope), \
             mock.patch('grp.getgrgid',return_value=types.SimpleNamespace(gr_name='render')), mock.patch.object(install,'run') as command:
            self.assertEqual(install.gpu_access(account,node),'render')
        command.assert_called_once_with(['usermod','-aG','render','agent'])

    @unittest.skipUnless(sys.platform == 'linux','Linux DRM permissions')
    def test_gpu_existing_but_insufficient_group_is_never_changed(self):
        account = types.SimpleNamespace(pw_name='agent',pw_uid=1000,pw_gid=1000)
        node = mock.Mock(); node.lstat.return_value = types.SimpleNamespace(st_mode=stat.S_IFCHR|0o600,st_rdev=1,st_gid=107)
        with mock.patch.object(install.os,'major',return_value=226), mock.patch.object(install.os,'access',return_value=False), \
             mock.patch.object(install.os,'getgrouplist',return_value=[1000,107]), \
             mock.patch.object(install,'user_files',return_value=contextlib.nullcontext()), \
             mock.patch('grp.getgrgid',return_value=types.SimpleNamespace(gr_name='render')), mock.patch.object(install,'run') as command:
            with self.assertRaisesRegex(RuntimeError,'Existing GPU group is insufficient'):
                install.gpu_access(account,node)
        command.assert_not_called()

    @unittest.skipUnless(sys.platform == 'linux','Linux DRM permissions')
    def test_gpu_failed_access_check_reverts_only_the_new_group_grant(self):
        account = types.SimpleNamespace(pw_name='agent',pw_uid=1000,pw_gid=1000)
        node = mock.Mock(); node.lstat.return_value = types.SimpleNamespace(st_mode=stat.S_IFCHR|0o600,st_rdev=1,st_gid=107)
        with mock.patch.object(install.os,'major',return_value=226), mock.patch.object(install.os,'access',side_effect=[False,False]), \
             mock.patch.object(install.os,'getgrouplist',return_value=[1000]), \
             mock.patch.object(install,'user_files',return_value=contextlib.nullcontext()), \
             mock.patch('grp.getgrgid',return_value=types.SimpleNamespace(gr_name='render')), mock.patch.object(install,'run') as command:
            with self.assertRaisesRegex(RuntimeError,'not accessible after the group grant'):
                install.gpu_access(account,node)
        self.assertEqual([call.args[0] for call in command.call_args_list],
                         [['usermod','-aG','render','agent'],['gpasswd','-d','agent','render']])

    @unittest.skipUnless(sys.platform == 'linux','Linux DRM permissions')
    def test_gpu_probe_removes_only_failed_new_grants_and_keeps_successful_or_existing_groups(self):
        account = types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000,pw_gid=1000)
        for granted,passed in [('render',False),(None,False),('render',True)]:
            config = {'render_node':''}; node = self.base/'renderD130'
            result = types.SimpleNamespace(returncode=0 if passed else 2,stdout=json.dumps({'gpu':{'passed':passed}}))
            with self.subTest(granted=granted,passed=passed), \
                 mock.patch.object(install.Path,'glob',return_value=[node]), \
                 mock.patch.object(install,'gpu_access',return_value=granted), mock.patch.object(install,'start_desktop'), \
                 mock.patch.object(install.subprocess,'run',return_value=result), \
                 mock.patch.object(install,'write_json'), mock.patch.object(install,'run') as command:
                install.verify_gpu(config,account)
            actions = [call.args[0] for call in command.call_args_list]
            if granted and not passed:
                self.assertEqual(actions,[['systemctl','stop','onedebian-agent-chromium.service','onedebian-agent-desktop.service'],
                                          ['gpasswd','-d','agent','render']])
            else:
                self.assertEqual(actions,[])
            self.assertEqual(config['render_node'],str(node) if passed else '')


if __name__ == '__main__':
    unittest.main()
