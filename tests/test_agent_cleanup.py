"""Cleanup decisions against disposable files; no real services or packages change."""
import base64
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('agent_cleanup', Path(__file__).resolve().parents[1] / 'agent/cleanup.py')
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.base.chmod(0o755)
        self.patch = mock.patch.object(cleanup, 'BASE', self.base)
        self.patch.start()
        self.calls = []
        self.group_names = ['agent']
        self.home_scope = False
        self.home = self.base / 'home/agent'
        self.home.mkdir(parents=True)
        os.chown(self.home, 1000, 1000)
        self.account = types.SimpleNamespace(pw_uid=1000, pw_gid=1000, pw_name='agent', pw_dir=str(self.home))
        self.i = types.SimpleNamespace(ROOT=self.base/'opt/onedebian-agent', ETC=self.base/'etc/onedebian-agent',
                                       STATE=self.base/'var/lib/onedebian-agent', OWNER='oneDebian-agent-v1', JOB='onedebian-agent-install.service')
        self.i.require_root = lambda: None
        self.i.active = lambda: False
        self.i.pwd = types.SimpleNamespace(getpwnam=lambda name: self.account)
        self.i.capture = lambda args: ' '.join(self.group_names)
        self.i.read_json = lambda path, default=None: json.loads(path.read_text()) if path.exists() else default
        def write_json(path, value, mode=0o644):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))
            path.chmod(mode)
        self.i.write_json = write_json
        def owned():
            for path in (self.i.ROOT,self.i.ETC,self.i.STATE):
                path.mkdir(parents=True, exist_ok=True)
                (path/'.owner').write_text(self.i.OWNER)
        self.i.owned_directories = owned
        owned()
        @contextlib.contextmanager
        def user_files(account):
            self.assertEqual(account, self.account)
            before_uid, before_gid, before_groups = os.geteuid(), os.getegid(), os.getgroups()
            self.home_scope = True
            try:
                os.setgroups([1000]); os.setegid(1000); os.seteuid(1000)
                yield
            finally:
                os.seteuid(before_uid); os.setegid(before_gid); os.setgroups(before_groups)
                self.home_scope = False
        self.i.user_files = user_files
        self.i.run = lambda args, **kw: self.calls.append(list(args))
        self.i.user_ctl = lambda account, *args, **kw: types.SimpleNamespace(stdout='')
        self.i.phase = lambda state: self.calls.append(['phase',state])
        self.pkg = types.SimpleNamespace(plan=lambda i: {'remove':[], 'blockers':[], 'warnings':[]},
                                         apply=lambda i, plan: self.calls.append(['packages']))
        self.modules = mock.patch.dict(sys.modules, {'package_undo':self.pkg})
        self.modules.start()

    def tearDown(self):
        self.modules.stop(); self.patch.stop(); self.tmp.cleanup()

    def home_file(self, relative, content):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        for directory in [path.parent, *path.parent.parents]:
            if directory.is_relative_to(self.home):
                os.chown(directory,1000,1000)
        path.write_text(content)
        os.chown(path,1000,1000)
        return path

    def plan(self):
        return cleanup.cleanup_plan(self.i)

    def apply(self):
        return cleanup.cleanup_apply(self.i,self.plan()['plan_id'])

    def test_global_ssh_guard_remains_until_ssh_package_removal_is_approved(self):
        path=self.base/'etc/systemd/system/ssh.service.d/90-onedebian-agent.conf'
        path.parent.mkdir(parents=True); path.write_text('[Unit]\nConditionPathExists=/fixture/opt-in\n')
        self.i.write_json(self.i.STATE/'files.json',{str(path):hashlib.sha256(path.read_bytes()).hexdigest()})
        plan=self.plan()
        self.assertNotIn(str(path),[entry['path'] for entry in plan['remove_files']])
        self.assertTrue(any(entry['path']==str(path) for entry in plan['retained']))
        self.pkg.plan=lambda _:dict(remove=['openssh-server:amd64'],retained=[])
        self.assertIn(str(path),[entry['path'] for entry in self.plan()['remove_files']])

    def test_plan_is_read_only_and_rejects_active_install_on_apply(self):
        cleanup.prepare(self.i)
        before={str(p):p.read_bytes() for p in self.i.STATE.iterdir() if p.is_file()}
        self.i.active=lambda: True
        plan=self.plan()
        self.assertTrue(plan['active']); self.assertTrue(plan['blockers'])
        self.assertEqual(before,{str(p):p.read_bytes() for p in self.i.STATE.iterdir() if p.is_file()})
        with self.assertRaisesRegex(RuntimeError,'Installation is active'):
            cleanup.cleanup_apply(self.i,plan['plan_id'])
        self.assertFalse(self.calls)

    def test_only_new_runtime_files_are_deleted_and_later_user_files_survive(self):
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i):
            node=self.home_file('.local/share/fnm/node-versions/v26/bin/node','owned node')
            wrapper=self.home_file('.local/bin/node','owned wrapper')
        user=self.home_file('.local/share/fnm/new-project-note','user data')
        project=self.home_file('workspaces/app/index.js','project')
        auth=self.home_file('.codex/auth.json','private auth')
        profile=self.home_file('.local/share/onedebian-agent/profile/Preferences','login state')
        self.apply()
        self.assertFalse(node.exists()); self.assertFalse(wrapper.exists())
        for path in (user,project,auth,profile): self.assertTrue(path.exists())

    def test_preexisting_tree_keeps_existing_files_but_removes_added_version(self):
        existing=self.home_file('.local/share/fnm/node-versions/v20/bin/node','old node')
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i):
            added=self.home_file('.local/share/fnm/node-versions/v26/bin/node','new node')
        self.apply()
        self.assertEqual(existing.read_text(),'old node'); self.assertFalse(added.exists())

    def test_record_cannot_adopt_pre_stage_user_files_or_modifications(self):
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i):
            wrapper=self.home_file('.local/bin/node','owned')
            old=self.home_file('.local/share/fnm/node','original')
        wrapper.write_text('user edited'); os.chown(wrapper,1000,1000)
        new=self.home_file('.local/share/fnm/user-note','user added')
        with cleanup.tracking(self.i):
            pass
        cleanup.record(self.i)
        self.apply()
        self.assertEqual(wrapper.read_text(),'user edited'); self.assertEqual(new.read_text(),'user added')
        self.assertFalse(old.exists())

    def test_failed_stage_records_partial_new_files_for_cleanup(self):
        cleanup.prepare(self.i)
        with self.assertRaisesRegex(RuntimeError,'download failed'):
            with cleanup.tracking(self.i):
                path=self.home_file('.local/share/onedebian-agent/tools/partial','half installed')
                raise RuntimeError('download failed')
        self.apply(); self.assertFalse(path.exists())

    def test_restore_configuration_only_if_unchanged_and_preview_hides_content(self):
        conf=self.base/'etc/wsl.conf'; conf.write_text('original private setting')
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i): conf.write_text('tool setting')
        plan=self.plan()
        self.assertNotIn('original private setting',json.dumps(plan))
        self.assertNotIn(base64.b64encode(b'original private setting').decode(),json.dumps(plan))
        cleanup.cleanup_apply(self.i,plan['plan_id'])
        self.assertEqual(conf.read_text(),'original private setting')

    def test_modified_configuration_is_not_overwritten(self):
        conf=self.base/'etc/wsl.conf'; conf.write_text('before')
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i): conf.write_text('after')
        conf.write_text('later user setting')
        result=self.apply()
        self.assertEqual(conf.read_text(),'later user setting'); self.assertEqual(result['state'],'CLEANED_PARTIAL')

    def test_bashrc_removes_only_known_inserted_fragments_and_keeps_user_edit(self):
        shell=self.home_file('.bashrc','echo original\n')
        cleanup.prepare(self.i)
        prefix='# oneDebian Agent fnm\nexport FNM_DIR="$HOME/.local/share/fnm"\nexport PATH="$HOME/.local/bin:$FNM_DIR:$PATH"\n'
        suffix='\nif [[ $- == *i* ]]; then eval "$("$FNM_DIR/fnm" env --use-on-cd --shell bash)"; fi\n'
        with cleanup.tracking(self.i): shell.write_text(prefix+'echo original\n'+suffix)
        shell.write_text(prefix+'echo original\necho later user change\n'+suffix)
        self.apply()
        self.assertEqual(shell.read_text(),'echo original\necho later user change\n')

    def test_legacy_state_never_claims_existing_runtime_or_settings(self):
        self.i.write_json(self.i.STATE/'state.json',{'state':'READY_SOFTWARE'})
        runtime=self.home_file('.local/share/fnm/bin/fnm','unknown')
        self.assertTrue(cleanup.prepare(self.i)['legacy'])
        cleanup.record(self.i)
        plan=self.plan()
        self.assertTrue(plan['warnings']); self.assertFalse(plan['remove_files'])
        self.apply(); self.assertTrue(runtime.exists())
        cleanup.reset(self.i)
        self.assertFalse(cleanup.prepare(self.i)['legacy'])

    def test_modified_unit_blocks_before_stopping_anything(self):
        cleanup.prepare(self.i)
        path=self.base/'etc/systemd/system/onedebian-agent-desktop.service'; path.parent.mkdir(parents=True)
        path.write_text('user custom unit')
        self.i.write_json(self.i.STATE/'files.json',{str(path):hashlib.sha256(b'original').hexdigest()})
        plan=self.plan(); self.assertTrue(plan['blockers'])
        with self.assertRaisesRegex(RuntimeError,'Modified or unowned'):
            cleanup.cleanup_apply(self.i,plan['plan_id'])
        self.assertFalse(self.calls)

    def test_unapproved_plan_or_changed_file_cannot_execute(self):
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i): path=self.home_file('.local/bin/node','one')
        plan=self.plan(); path.write_text('two')
        with self.assertRaisesRegex(RuntimeError,'plan changed'):
            cleanup.cleanup_apply(self.i,plan['plan_id'])
        self.assertFalse(self.calls)

    def test_symlink_parent_and_outside_manifest_cannot_delete_external_file(self):
        cleanup.prepare(self.i)
        outside=self.base/'outside'; outside.write_text('keep')
        self.i.write_json(self.i.STATE/'files.json',{str(outside):hashlib.sha256(b'keep').hexdigest()})
        self.apply(); self.assertTrue(outside.exists())
        cleanup.reset(self.i); cleanup.prepare(self.i)
        with cleanup.tracking(self.i): self.home_file('.local/bin/node','managed')
        local=self.home/'.local'; (local/'bin').rename(local/'old-bin'); (local/'bin').symlink_to(self.base)
        with self.assertRaisesRegex(RuntimeError,'Symlink'):
            self.plan()

    def test_new_install_after_cleanup_takes_new_baseline(self):
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i): first=self.home_file('.local/bin/node','first')
        self.apply(); self.assertFalse(first.exists())
        user=self.home_file('.local/bin/node','new user node')
        with self.assertRaisesRegex(RuntimeError,'reset'):
            cleanup.prepare(self.i)
        cleanup.reset(self.i)
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i): pass
        self.apply(); self.assertEqual(user.read_text(),'new user node')

    def test_completed_reset_archives_stale_install_and_gpu_evidence(self):
        cleanup.prepare(self.i)
        for name in ('installed.json', 'gpu.json'):
            self.i.write_json(self.i.STATE/name, {'old_generation':name})
        state=self.i.STATE/'state.json'
        self.i.write_json(state, {'state':'READY_GPU'})
        cleanup.reset(self.i)
        self.assertTrue((self.i.STATE/'installed.json').exists())
        self.assertTrue((self.i.STATE/'gpu.json').exists())
        self.apply()
        state_before=state.read_bytes()
        cleanup.reset(self.i)
        for name in ('installed.json', 'gpu.json'):
            self.assertFalse((self.i.STATE/name).exists())
            archives=list(self.i.STATE.glob('cleanup-history-*-'+name))
            self.assertEqual(len(archives),1)
            self.assertEqual(self.i.read_json(archives[0]), {'old_generation':name})
        self.assertEqual(state.read_bytes(),state_before)
        self.assertFalse(cleanup.prepare(self.i)['legacy'])

    def test_runtime_symlink_is_unlinked_without_following_its_target(self):
        cleanup.prepare(self.i)
        outside=self.base/'external'; outside.write_text('keep')
        with cleanup.tracking(self.i):
            root=self.home/'.local/share/fnm'; root.mkdir(parents=True)
            for directory in [root,*root.parents]:
                if directory.is_relative_to(self.home): os.chown(directory,1000,1000)
            link=root/'owned-link'; link.symlink_to(outside); os.lchown(link,1000,1000)
        self.apply(); self.assertFalse(link.is_symlink()); self.assertEqual(outside.read_text(),'keep')

    def test_package_blockers_prevent_service_mutation(self):
        cleanup.prepare(self.i)
        self.pkg.plan=lambda i: {'blocked':['Foreign package dependency'], 'warnings':[]}
        plan=self.plan()
        with self.assertRaisesRegex(RuntimeError,'Foreign package'):
            cleanup.cleanup_apply(self.i,plan['plan_id'])
        self.assertFalse(self.calls)

    def test_cleanup_before_agent_creation_restores_root_settings_and_packages(self):
        self.home.rmdir()
        self.i.pwd.getpwnam = mock.Mock(side_effect=KeyError('agent'))
        self.i.user_ctl = mock.Mock(side_effect=AssertionError('No user service manager exists'))
        source=self.base/'etc/wsl.conf'; source.write_text('original')
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i): source.write_text('Agent settings')
        result=self.apply()
        self.assertEqual(result['state'],'CLEANED')
        self.assertEqual(source.read_text(),'original')
        self.assertIn(['packages'],self.calls)
        self.i.user_ctl.assert_not_called()

    def test_missing_agent_with_home_or_user_services_is_blocked_in_preview(self):
        cleanup.prepare(self.i)
        self.i.pwd.getpwnam = mock.Mock(side_effect=KeyError('agent'))
        plan=self.plan()
        self.assertTrue(any('account is missing' in message for message in plan['blockers']))
        self.home.rmdir()
        unit=self.base/'etc/systemd/user/onedebian-agent-mcp.service'
        unit.parent.mkdir(parents=True); unit.write_text('owned user unit')
        self.i.write_json(self.i.STATE/'files.json',{str(unit):hashlib.sha256(unit.read_bytes()).hexdigest()})
        plan=self.plan()
        self.assertTrue(any('user services remain' in message for message in plan['blockers']))
        with self.assertRaisesRegex(RuntimeError,'user services remain'):
            cleanup.cleanup_apply(self.i,plan['plan_id'])
        self.assertFalse(self.calls)

    def test_package_apply_conflicts_are_reported_once_as_partial_cleanup(self):
        cleanup.prepare(self.i)
        original={'name':'kept-package','reason':'modified by another installer'}
        late={'name':'manual-mark','reason':'automatic installation mark was not restored'}
        self.pkg.plan=lambda i: {'remove':[], 'retained':[original], 'warnings':['manual marks changed']}
        self.pkg.apply=lambda i, plan: {'retained':[original,late,late],
                                       'warnings':['manual marks changed','post-removal marks changed','post-removal marks changed']}
        result=self.apply()
        self.assertEqual(result['state'],'CLEANED_PARTIAL')
        self.assertEqual(result['retained'],[
            {'path':'package:kept-package','reason':original['reason']},
            {'path':'package:manual-mark','reason':late['reason']}])
        self.assertEqual(result['warnings'],['manual marks changed','post-removal marks changed'])

    def test_bootstrap_source_backup_restores_original_not_localized_snapshot(self):
        source=self.base/'etc/apt/sources.list'; source.parent.mkdir(parents=True)
        source.write_text('localized mirror')
        directory=self.i.STATE/'cleanup-bootstrap-sources'; directory.mkdir(mode=0o700)
        key=hashlib.sha256(str(source).encode()).hexdigest()
        values={'.owner':self.i.OWNER,'sealed':'sealed',key+'.path':str(source)+'\n',
                key+'.before.meta':'644 0 0',key+'.before':'private original source',
                key+'.after.meta':hashlib.sha256(b'localized mirror').hexdigest()+' 644 0 0'}
        for name,value in values.items():
            path=directory/name; path.write_text(value); path.chmod(0o600)
        cleanup.prepare(self.i)
        self.assertNotIn('private original source',json.dumps(self.plan()))
        self.apply(); self.assertEqual(source.read_text(),'private original source')

    def test_preexisting_default_alias_is_restored_without_following_link(self):
        self.home_file('.local/share/fnm/node-versions/v20/bin/node','original Node')
        aliases=self.home/'.local/share/fnm/aliases'; aliases.mkdir(); os.chown(aliases,1000,1000)
        default=aliases/'default'; default.symlink_to('../node-versions/v20'); os.lchown(default,1000,1000)
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i):
            self.home_file('.local/share/fnm/node-versions/v26/bin/node','Agent Node')
            default.unlink(); default.symlink_to('../node-versions/v26'); os.lchown(default,1000,1000)
        self.apply(); self.assertEqual(os.readlink(default),'../node-versions/v20')

    def test_only_groups_added_inside_the_stage_are_removed(self):
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i):
            self.group_names.append('render')
            flag=self.base/'var/lib/systemd/linger/agent'; flag.parent.mkdir(parents=True); flag.touch()
        self.group_names.append('video')
        with cleanup.tracking(self.i): pass
        plan=self.plan()
        self.assertEqual(plan['account_changes']['remove_groups'],['render'])
        self.assertTrue(plan['account_changes']['disable_linger'])
        self.apply()
        self.assertIn(['gpasswd','-d','agent','render'],self.calls)
        self.assertNotIn(['gpasswd','-d','agent','video'],self.calls)

    def test_private_ledger_and_completion_receipt_are_required(self):
        cleanup.prepare(self.i)
        (self.i.STATE/cleanup.LEDGER).chmod(0o644)
        with self.assertRaisesRegex(RuntimeError,'private root-owned'):
            self.plan()
        (self.i.STATE/cleanup.LEDGER).chmod(0o600)
        self.i.write_json(self.i.STATE/'cleanup-completed.json',{'owner':self.i.OWNER,'state':'CLEANED'},0o600)
        with self.assertRaisesRegex(RuntimeError,'not recorded complete'):
            cleanup.validate_reset(self.i)

    def test_repeated_cleanup_keeps_the_restored_configuration(self):
        source=self.base/'etc/wsl.conf'; source.write_text('original')
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i): source.write_text('Agent setting')
        self.apply(); result=self.apply()
        self.assertEqual(source.read_text(),'original'); self.assertEqual(result['state'],'CLEANED')

    def test_legacy_apply_without_ledger_still_allows_safe_new_baseline(self):
        self.i.write_json(self.i.STATE/'state.json',{'state':'READY_SOFTWARE'})
        self.assertFalse((self.i.STATE/cleanup.LEDGER).exists())
        self.apply()
        self.assertTrue(self.i.read_json(self.i.STATE/cleanup.LEDGER)['applied'])
        self.assertIsNotNone(cleanup.validate_reset(self.i))
        cleanup.reset(self.i)
        self.assertFalse(cleanup.prepare(self.i)['legacy'])

    def test_home_backup_refuses_leaf_symlink_swap_without_reading_root_secret(self):
        shell=self.home_file('.bashrc','ordinary shell')
        secret=self.base/'root-only'; secret.write_text('private root secret'); secret.chmod(0o600)
        real_open=os.open
        def swap(path,flags,*args,**kwargs):
            if Path(path)==shell:
                self.assertEqual(os.geteuid(),1000)
                shell.unlink(); shell.symlink_to(secret)
            return real_open(path,flags,*args,**kwargs)
        with mock.patch.object(cleanup.os,'open',side_effect=swap):
            with self.assertRaises(OSError): cleanup.prepare(self.i)
        self.assertFalse((self.i.STATE/cleanup.LEDGER).exists())

    def test_concurrent_user_codex_config_is_not_claimed_as_generated(self):
        cleanup.prepare(self.i)
        with cleanup.tracking(self.i):
            config=self.home_file('.codex/config.toml','user-defined providers')
        self.apply(); self.assertEqual(config.read_text(),'user-defined providers')


if __name__ == '__main__': unittest.main()
