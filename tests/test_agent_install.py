"""Installer decisions against disposable files and command stubs only."""
import hashlib
import contextlib
import configparser
import importlib.util
import io
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
sys.modules[spec.name] = install
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
        for module, name in [(install.cleanup, 'prepare'), (install.cleanup, 'reset'),
                             (install.package_undo, 'prepare'), (install.package_undo, 'finish'),
                             (install.package_undo, 'reset')]:
            patch = mock.patch.object(module, name)
            patch.start(); self.patches.append(patch)
        patch = mock.patch.object(install.cleanup, 'tracking', side_effect=lambda *_a, **_k: contextlib.nullcontext())
        patch.start(); self.patches.append(patch)
        patch = mock.patch.object(install.package_undo, 'install_args', side_effect=lambda _i, argv: argv)
        patch.start(); self.patches.append(patch)
        patch = mock.patch.object(install, 'd3d12_available', return_value=False)
        patch.start(); self.patches.append(patch)
        patch = mock.patch.object(install.runtime, 'manual', return_value=False)
        patch.start(); self.patches.append(patch)
        patch = mock.patch.object(install, 'graphics_browser_state', return_value=('active',123))
        patch.start(); self.patches.append(patch)

    def test_first_install_can_prove_d3d12_without_a_drm_render_node(self):
        cfg = {'render_node':'', 'gpu_backend':'software'}
        user = types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000)
        proof = {'passed':True,'gpu':{'passed':True,'backend':'d3d12'}}
        with mock.patch.object(install.Path,'glob',return_value=[]), \
             mock.patch.object(install,'d3d12_available',return_value=True), \
             mock.patch.object(install,'probe_graphics',return_value=proof), \
             mock.patch.object(install,'run'), mock.patch.object(install.subprocess,'run'), \
             mock.patch.object(install,'write_json') as write:
            install.verify_gpu(cfg,user)
        self.assertEqual(cfg,{'render_node':'','gpu_backend':'d3d12'})
        record = next(call.args[1] for call in write.call_args_list if call.args[0]==install.STATE/'gpu.json')
        self.assertEqual((record['mode'],record['backend']),('gpu','d3d12'))

    def test_runtime_installs_and_records_global_pnpm_in_the_pinned_fnm_node(self):
        home=self.base/'agent-home'
        user=types.SimpleNamespace(pw_dir=str(home))
        downloads=install.STATE/'downloads'; downloads.mkdir()
        archive=downloads/'fnm-fixture.zip'
        with install.zipfile.ZipFile(archive,'w') as zipped: zipped.writestr('fnm',b'fixture-fnm')
        digest=hashlib.sha256(archive.read_bytes()).hexdigest()
        install.write_json(install.ETC/'config.json',{'mcp_port':18931})
        def command(_user,argv,**kwargs):
            value=install.VERSIONS['pnpm'] if argv[-2:]==['pnpm','--version'] else install.VERSIONS['node']
            return types.SimpleNamespace(stdout=value+'\n')
        with mock.patch.object(install,'capture',return_value='amd64'), \
             mock.patch.object(install,'FNM',{'amd64':('fnm-fixture.zip',digest)}), \
             mock.patch.object(install,'user_files',return_value=contextlib.nullcontext()), \
             mock.patch.object(install,'as_user',side_effect=command) as run:
            install.install_runtime(user)
        calls=[call.args[1] for call in run.call_args_list]
        global_install=next(argv for argv in calls if '--global' in argv)
        self.assertEqual(global_install[-4:],['npm','install','--global','pnpm@'+install.VERSIONS['pnpm']])
        self.assertEqual(install.read_json(install.ETC/'versions.json')['pnpm'],install.VERSIONS['pnpm'])
        self.assertIn('exec --using=', (home/'.local/bin/pnpm').read_text())

    def test_manual_takeover_rejects_gpu_adjustment_before_any_payload_change(self):
        install.write_json(install.ETC/'config.json',{'user':'agent','home':'/home/agent','render_node':''})
        user = types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000)
        with mock.patch.object(install,'require_root'), mock.patch.object(install,'require_debian'), \
             mock.patch.object(install.cleanup,'_trusted'), mock.patch.object(install.pwd,'getpwnam',return_value=user), \
             mock.patch.object(install.runtime,'manual',return_value=True), mock.patch.object(install,'save_payload') as save:
            with self.assertRaisesRegex(RuntimeError,'Manual takeover'):
                install.configure_graphics(options(yes=True))
        save.assert_not_called()
        self.assertFalse((install.STATE/'gpu.log').exists())

    def test_keyring_repair_preserves_existing_policy_and_reports_creation_failures(self):
        cfg={'user':'agent','home':'/home/agent','keyring_mode':'manual'}
        user=types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000)
        for state in ('INITIALIZED','RETAINED','ERROR'):
            install.write_json(install.ETC/'config.json',cfg)
            with self.subTest(state=state), contextlib.ExitStack() as stack:
                for name,value in [('require_root',None),('require_debian',None),('active',False),('prepare_changes',install),('save_payload',None)]:
                    stack.enter_context(mock.patch.object(install,name,return_value=value))
                stack.enter_context(mock.patch.object(install.cleanup,'_trusted'))
                stack.enter_context(mock.patch.object(install.pwd,'getpwnam',return_value=user))
                command=stack.enter_context(mock.patch.object(install,'as_user',return_value=types.SimpleNamespace(stdout=json.dumps({'state':state}))))
                if state=='ERROR':
                    command.side_effect=install.subprocess.CalledProcessError(1,['python3'],output='{"state":"ERROR","error":"unsafe fixture"}')
                    with self.assertRaisesRegex(RuntimeError,'unsafe fixture'): install.configure_keyring(options(yes=True))
                else: self.assertEqual(install.configure_keyring(options(yes=True))['state'],state)
                expected='empty' if state=='INITIALIZED' else 'manual'
                self.assertEqual(install.read_json(install.ETC/'config.json')['keyring_mode'],expected)

    def test_desktop_update_only_deploys_owned_assets_and_restarts_controls(self):
        cfg={'user':'agent','home':'/home/agent','display':':11'}
        user=types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000)
        for restarted in (False,True):
            install.write_json(install.ETC/'config.json',cfg)
            with self.subTest(restarted=restarted), contextlib.ExitStack() as stack:
                for name,value in [('require_root',None),('require_debian',None),('active',False),('prepare_changes',install)]:
                    stack.enter_context(mock.patch.object(install,name,return_value=value))
                stack.enter_context(mock.patch.object(install.cleanup,'_trusted'))
                stack.enter_context(mock.patch.object(install.pwd,'getpwnam',return_value=user))
                save=stack.enter_context(mock.patch.object(install,'save_payload'))
                launchers=stack.enter_context(mock.patch.object(install,'desktop_launchers'))
                controls=stack.enter_context(mock.patch.object(install,'restart_controls',return_value=restarted))
                command=stack.enter_context(mock.patch.object(install,'run'))
                result=install.update_desktop(options(yes=True))
                self.assertEqual(result['state'],'DESKTOP_UPDATED')
                self.assertIs(result['controls_restarted'],restarted)
                save.assert_called_once();launchers.assert_called_once_with(user);controls.assert_called_once_with(cfg,user)
                command.assert_not_called()

    def test_controls_update_waits_for_a_stopped_desktop_without_starting_it(self):
        with mock.patch.object(install,'capture',return_value='0'), mock.patch.object(install,'run') as command:
            self.assertFalse(install.restart_controls({},None))
        command.assert_not_called()

    def test_controls_update_rejects_an_unowned_desktop_before_stopping_any_process(self):
        unit=self.base/'unowned-desktop.service';unit.write_text('foreign desktop')
        real_path=Path
        def path(value,*parts):
            return unit if str(value)=='/etc/systemd/system/onedebian-agent-desktop.service' else real_path(value,*parts)
        with mock.patch.object(install,'capture',return_value='321'), mock.patch.object(install,'Path',side_effect=path), \
             mock.patch.object(install.os,'kill') as signal, mock.patch.object(install,'run') as command:
            with self.assertRaisesRegex(RuntimeError,'modified or unowned'): install.restart_controls({},None)
        signal.assert_not_called();command.assert_not_called()

    def test_gpu_adjustment_records_production_proof_and_recovers_on_failure(self):
        cfg = {'user':'agent','home':'/home/agent','render_node':''}
        user = types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000)
        proof = {'passed':True,'gpu':{'passed':True,'backend':'d3d12','reason':'shader readback passed'}}
        preserved = {'pages_before':2,'pages_after':2,'page_urls_preserved':True}
        for case in ('pass','production-fails','production-raises','candidate-start-fails','tabs-lost','fallback-fails','fallback-raises','mcp-start-fails'):
            with self.subTest(case=case), contextlib.ExitStack() as stack:
                install.write_json(install.ETC/'config.json',cfg)
                for name,value in [('require_root',None),('require_debian',None),('active',False),
                                   ('status',{'state':'READY_SOFTWARE'}),('prepare_changes',install),
                                   ('save_payload',None),('d3d12_available',True),('probe_graphics',proof),
                                   ('phase',None),('user_ctl',types.SimpleNamespace(stdout='active'))]:
                    stack.enter_context(mock.patch.object(install,name,return_value=value))
                stack.enter_context(mock.patch.object(install.cleanup,'_trusted'))
                stack.enter_context(mock.patch.object(install.pwd,'getpwnam',return_value=user))
                stack.enter_context(mock.patch.object(install.runtime,'manual',return_value=False))
                changes = stack.enter_context(mock.patch.object(install,'change_graphics_browser',return_value=preserved))
                if case=='candidate-start-fails': changes.side_effect=[RuntimeError('CDP unavailable'),preserved]
                if case=='tabs-lost': changes.side_effect=[dict(preserved,page_urls_preserved=False),preserved]
                check = stack.enter_context(mock.patch.object(install,'graphics_check',return_value=proof))
                if case=='production-fails': check.side_effect=[{'passed':False,'gpu':{'reason':'production draw failed'}},{'passed':True}]
                if case=='production-raises': check.side_effect=[RuntimeError('production CDP timed out'),{'passed':True}]
                if case=='fallback-fails': check.side_effect=[{'passed':False},{'passed':False}]
                if case=='fallback-raises': check.side_effect=[RuntimeError('production failed'),RuntimeError('software check failed')]
                if case=='mcp-start-fails':
                    def user_command(_user, action, *_args, **_kwargs):
                        if action=='start': raise RuntimeError('fixture MCP restart failed')
                        return types.SimpleNamespace(stdout='active')
                    install.user_ctl.side_effect=user_command
                result = install.configure_graphics(options(yes=True))
                expected='READY_GPU' if case=='pass' else 'ERROR' if case in ('tabs-lost','fallback-fails','fallback-raises','mcp-start-fails') else 'READY_SOFTWARE'
                self.assertEqual(result['state'],expected)
                record = install.read_json(install.STATE/'gpu.json')
                self.assertEqual(record['result_state'],expected)
                self.assertEqual(record['operation'],'graphics')
                self.assertEqual(install.phase.call_args.args[0],expected)
                self.assertIn('production',record)
                if case in ('candidate-start-fails','tabs-lost','fallback-fails','fallback-raises'):
                    self.assertTrue(changes.call_args.kwargs['recover'])
                    self.assertEqual(changes.call_args.args[1]['gpu_backend'],'software')
                if expected=='READY_SOFTWARE': self.assertTrue(record['fallback']['passed'])
                if case=='production-raises': self.assertIn('production CDP timed out',record['reason'])
                install.user_ctl.assert_any_call(user,'start','onedebian-agent-mcp.service')

    def test_manual_takeover_during_production_check_prevents_recovery_and_mcp_restart(self):
        cfg={'user':'agent','home':'/home/agent','render_node':'','gpu_backend':'software'}
        install.write_json(install.ETC/'config.json',cfg)
        user=types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000)
        proof={'passed':True,'gpu':{'passed':True,'reason':'trial passed'}}
        manual={'active':False}
        def change(_previous,candidate,_user,**_kwargs):
            install.write_json(install.ETC/'config.json',candidate)
            return {'page_urls_preserved':True}
        def check(*_args):
            manual['active']=True
            return {'passed':False,'gpu':{'reason':'Manual takeover is active'}}
        with contextlib.ExitStack() as stack:
            for name,value in [('require_root',None),('require_debian',None),('active',False),
                               ('status',{'state':'READY_SOFTWARE'}),('prepare_changes',install),('save_payload',None),
                               ('d3d12_available',True),('probe_graphics',proof),('phase',None),
                               ('user_ctl',types.SimpleNamespace(stdout='active'))]:
                stack.enter_context(mock.patch.object(install,name,return_value=value))
            stack.enter_context(mock.patch.object(install.cleanup,'_trusted'))
            stack.enter_context(mock.patch.object(install.pwd,'getpwnam',return_value=user))
            stack.enter_context(mock.patch.object(install.runtime,'manual',side_effect=lambda _cfg:manual['active']))
            changes=stack.enter_context(mock.patch.object(install,'change_graphics_browser',side_effect=change))
            stack.enter_context(mock.patch.object(install,'graphics_check',side_effect=check))
            result=install.configure_graphics(options(yes=True))
            self.assertEqual(result['state'],'ERROR')
            self.assertTrue(manual['active'])
            self.assertEqual(changes.call_count,1)
            self.assertEqual(result['backend'],'d3d12')
            self.assertIn('Manual takeover',result['reason'])
            self.assertNotIn(mock.call(user,'start','onedebian-agent-mcp.service'),install.user_ctl.call_args_list)

    def test_browser_change_respects_manual_takeover_even_during_software_recovery(self):
        cfg={'user':'agent','home':'/home/agent','render_node':''}
        for recover in (False,True):
            active={'manual':False}
            control=mock.Mock()
            control.browser_ready.side_effect=lambda:active.update(manual=True)
            control.cdp.return_value={'targetInfos':[]}
            module=types.SimpleNamespace(Verifier=mock.Mock(return_value=control))
            with self.subTest(recover=recover), mock.patch.dict(sys.modules,{'verify':module}), \
                 mock.patch.object(install.runtime,'manual',side_effect=lambda _cfg:active['manual']), \
                 mock.patch.object(install,'run') as command:
                with self.assertRaisesRegex(RuntimeError,'Manual takeover'):
                    install.change_graphics_browser(cfg,cfg,None,recover=recover)
            self.assertNotIn(mock.call('Browser.close'),control.cdp.call_args_list)
            command.assert_not_called()

    def test_gpu_retry_requires_an_owned_completed_install_and_graphics_error_record(self):
        cfg={'user':'agent','home':'/home/agent','render_node':''}
        install.write_json(install.ETC/'config.json',cfg)
        user=types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000)
        for installed,record,accepted in [({}, {}, False), ({'owner':install.OWNER}, {}, False),
                 ({'owner':install.OWNER},{'operation':'graphics','result_state':'ERROR'},True)]:
            install.write_json(install.STATE/'installed.json',installed)
            install.write_json(install.STATE/'gpu.json',record)
            with self.subTest(installed=installed,record=record), \
                 mock.patch.object(install,'require_root'),mock.patch.object(install,'require_debian'), \
                 mock.patch.object(install.cleanup,'_trusted'),mock.patch.object(install.pwd,'getpwnam',return_value=user), \
                 mock.patch.object(install,'active',return_value=False),mock.patch.object(install,'status',return_value={'state':'ERROR'}), \
                 mock.patch.object(install,'prepare_changes',side_effect=RuntimeError('fixture retry reached')):
                with self.assertRaisesRegex(RuntimeError,'fixture retry reached' if accepted else 'Finish the current installation'):
                    install.configure_graphics(options(yes=True))

    def test_software_recovery_does_not_require_the_failed_browser_cdp(self):
        cfg={'user':'agent','home':'/home/agent','render_node':''}
        broken=mock.Mock(); broken.browser_ready.side_effect=RuntimeError('CDP unavailable')
        recovered=mock.Mock(); recovered.cdp.return_value={'targetInfos':[{'type':'page','url':'http://fixture.invalid'}]}
        module=types.SimpleNamespace(Verifier=mock.Mock(side_effect=[broken,recovered]))
        with mock.patch.dict(sys.modules,{'verify':module}), mock.patch.object(install,'run') as command, \
             mock.patch.object(install,'graphics_browser_owned',return_value=True) as identity:
            result=install.change_graphics_browser(cfg,dict(cfg,gpu_backend='software'),None,recover=True)
        self.assertIsNone(result['page_urls_preserved'])
        self.assertEqual(module.HELPERS,install.ROOT)
        self.assertEqual(install.read_json(install.ETC/'config.json')['gpu_backend'],'software')
        identity.assert_called_once_with(cfg,None,123)
        command.assert_any_call(['systemctl','start','onedebian-agent-chromium.service'])

    def test_stopped_browser_starts_the_candidate_without_waiting_for_old_cdp(self):
        cfg={'user':'agent','home':'/home/agent','render_node':'','gpu_backend':'software','cdp_port':19222}
        user=types.SimpleNamespace(pw_name='agent',pw_dir='/home/agent',pw_uid=1000)
        proof={'passed':True,'gpu':{'passed':True,'reason':'hardware shader proof'}}
        for stopped_state in ('inactive','failed'):
            install.write_json(install.ETC/'config.json',cfg)
            control=mock.Mock()
            control.cdp.return_value={'targetInfos':[{'type':'page','url':'http://restored.invalid'}]}
            module=types.SimpleNamespace(Verifier=mock.Mock(return_value=control))
            with self.subTest(state=stopped_state), contextlib.ExitStack() as stack:
                for name,value in [('require_root',None),('require_debian',None),('active',False),
                                   ('status',{'state':'READY_SOFTWARE'}),('prepare_changes',install),('save_payload',None),
                                   ('d3d12_available',True),('probe_graphics',proof),('graphics_check',proof),('phase',None),
                                   ('graphics_browser_state',(stopped_state,0)),('user_ctl',types.SimpleNamespace(stdout='inactive'))]:
                    stack.enter_context(mock.patch.object(install,name,return_value=value))
                stack.enter_context(mock.patch.object(install.cleanup,'_trusted'))
                stack.enter_context(mock.patch.object(install.pwd,'getpwnam',return_value=user))
                stack.enter_context(mock.patch.dict(sys.modules,{'verify':module}))
                command=stack.enter_context(mock.patch.object(install,'run'))
                result=install.configure_graphics(options(yes=True))
            self.assertEqual(result['state'],'READY_GPU')
            self.assertEqual(result['backend'],'d3d12')
            self.assertEqual(module.Verifier.call_count,1)
            self.assertEqual(module.Verifier.call_args.args[0]['gpu_backend'],'d3d12')
            control.browser_ready.assert_called_once()
            self.assertNotIn(mock.call('Browser.close'),control.cdp.call_args_list)
            self.assertNotIn(mock.call(['systemctl','stop','onedebian-agent-chromium.service']),command.call_args_list)
            command.assert_called_once_with(['systemctl','start','onedebian-agent-chromium.service'])
            self.assertFalse(result['preservation']['browser_previously_running'])
            self.assertIsNone(result['preservation']['pages_before'])
            self.assertIsNone(result['preservation']['page_urls_preserved'])
            self.assertEqual(result['preservation']['pages_after'],1)
            self.assertTrue(install.read_json(install.STATE/'gpu.json')['production']['passed'])

    def test_running_browser_without_cdp_is_not_blindly_stopped(self):
        cfg={'user':'agent','home':'/home/agent','render_node':'','cdp_port':19222}
        control=mock.Mock(); control.browser_ready.side_effect=RuntimeError('CDP unavailable')
        module=types.SimpleNamespace(Verifier=mock.Mock(return_value=control))
        for recover in (False,True):
            with self.subTest(recover=recover), mock.patch.dict(sys.modules,{'verify':module}), \
                 mock.patch.object(install,'graphics_browser_owned',return_value=False), mock.patch.object(install,'run') as command:
                with self.assertRaisesRegex(RuntimeError,'identity could not be verified' if recover else 'CDP unavailable'):
                    install.change_graphics_browser(cfg,dict(cfg,gpu_backend='software'),None,recover=recover)
            command.assert_not_called()
            self.assertFalse((install.ETC/'config.json').exists())

    def test_browser_recovery_identity_requires_exact_user_profile_and_cdp_port(self):
        import verify
        cfg={'user':'agent','home':'/home/agent','cdp_port':19222}
        user=types.SimpleNamespace(pw_dir='/home/agent',pw_uid=1000)
        process=self.base/'proc/123'; process.mkdir(parents=True)
        os.chown(process,1000,1000)
        (process/'exe').symlink_to('/usr/lib/chromium/chromium')
        good=b'chromium\0--user-data-dir=/home/agent/.local/share/onedebian-agent/profile\0--remote-debugging-port=19222\0'
        real_path=Path
        def path(*parts):
            return process if parts==('/proc','123') else real_path(*parts)
        for args,expected in [(good,True),(good.replace(b'\0',b' ').rstrip(),True),
                              (good.replace(b'19222',b'19223'),False),
                              (good.replace(b'/profile',b'/some-other-profile'),False),
                              (good+b'--type=gpu-process\0',False),(good+b'--no-sandbox\0',False)]:
            (process/'cmdline').write_bytes(args)
            with self.subTest(args=args), mock.patch.object(install,'Path',side_effect=path):
                self.assertEqual(install.graphics_browser_owned(cfg,user,123),expected)

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

    def test_timeout_keeps_failure_state_and_original_diagnostic(self):
        with mock.patch.object(install,'require_root'), mock.patch.object(install,'user_record'), \
             mock.patch.object(install,'packages',side_effect=install.subprocess.TimeoutExpired('curl',600)), \
             mock.patch.object(install,'boot_id',return_value='fixture-boot'), \
             contextlib.redirect_stderr(io.StringIO()) as log:
            with self.assertRaises(install.subprocess.TimeoutExpired):
                install.worker(options())
        result = install.read_json(install.STATE / 'state.json')
        self.assertEqual(result['state'],'ERROR')
        self.assertIn('timed out',result['error'])
        self.assertIn('timed out',log.getvalue())

    def test_package_failure_still_finishes_ownership_recording(self):
        def command(argv, **kwargs):
            if 'install' in argv:
                raise install.subprocess.CalledProcessError(100,argv)
        with mock.patch.object(install,'run',side_effect=command):
            with self.assertRaises(install.subprocess.CalledProcessError):
                install.packages(options())
        install.package_undo.install_args.assert_called_once()
        install.package_undo.finish.assert_called_once()

    def test_undo_baseline_precedes_user_and_payload_changes(self):
        events = []
        with mock.patch.object(install,'prepare_changes',side_effect=lambda: events.append('baseline') or install), \
             mock.patch.object(install,'user_record',side_effect=lambda *_:events.append('user')), \
             mock.patch.object(install,'save_payload',side_effect=lambda:events.append('payload')), \
             mock.patch.object(install,'Path',side_effect=lambda value:self.base/'wsl.conf' if str(value)=='/etc/wsl.conf' else Path(value)):
            install.set_wsl_config(options())
        self.assertEqual(events,['baseline','user','payload'])

    def test_first_wsl_preparation_holds_operation_lock_before_baseline(self):
        def prepare():
            self.assertTrue((install.STATE/'install.lock').is_file())
            with self.assertRaisesRegex(RuntimeError,'cleanup is running'):
                with install.operation_lock(): pass
            return install
        with mock.patch.object(install,'prepare_changes',side_effect=prepare), \
             mock.patch.object(install,'configure_wsl',return_value={'state':'PREPARED'}):
            self.assertEqual(install.set_wsl_config(options()),{'state':'PREPARED'})

    def test_cleanup_formatter_never_prints_backup_contents(self):
        data = dict(state='CLEANUP_PLAN',plan_id='a'*64,restore_files=[
            dict(path='/home/agent/.bashrc',content='private-backup-must-not-print')])
        with contextlib.redirect_stdout(io.StringIO()) as output:
            install.show_cleanup(data)
        self.assertIn('/home/agent/.bashrc',output.getvalue())
        self.assertIn('plan_id: '+'a'*64,output.getvalue())
        self.assertNotIn('private-backup-must-not-print',output.getvalue())

    def test_ready_install_cannot_race_an_active_cleanup(self):
        install.write_json(install.STATE / 'installed.json',{'owner':install.OWNER})
        with mock.patch.object(install,'require_root'), mock.patch.object(install,'active',return_value=False), \
             mock.patch.object(install,'status',return_value={'state':'READY_SOFTWARE'}), \
             mock.patch.object(install,'run') as command:
            with install.operation_lock():
                with self.assertRaisesRegex(RuntimeError,'cleanup is running'):
                    install.start_install(options())
        command.assert_not_called()
        with install.operation_lock():
            pass

    def test_cleanup_json_is_separate_from_native_progress_and_has_private_log(self):
        def apply(_module, _plan):
            os.write(1,b'APT removal progress\n')
            os.write(2,b'Native diagnostic\n')
            return {'state':'CLEANED'}
        with mock.patch.object(sys,'argv',['agent.sh','cleanup','--yes','--json','--plan-id','a'*64]), \
             mock.patch.object(install,'require_root'), \
             mock.patch.object(install.cleanup,'cleanup_plan',return_value={'plan_id':'a'*64,'blockers':[]}), \
             mock.patch.object(install.cleanup,'cleanup_apply',side_effect=apply), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(install.main(),0)
        result=json.loads(output.getvalue())
        self.assertEqual(result['state'],'CLEANED')
        log=Path(result['log'])
        self.assertIn('APT removal progress',log.read_text())
        self.assertIn('Native diagnostic',log.read_text())
        self.assertEqual(stat.S_IMODE(log.stat().st_mode),0o600)

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
            config = {'render_node':''}; node = Path('/dev/dri/renderD130')
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
