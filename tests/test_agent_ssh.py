"""Loopback SSH fixtures never install packages or start a real daemon."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('agent_ssh_setup', Path(__file__).resolve().parents[1] / 'agent/ssh_setup.py')
ssh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ssh)
PUBLIC = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREPUBLICKEYONLY'


@unittest.skipUnless(sys.platform == 'linux' and os.geteuid() == 0, 'Linux root-owned disposable fixtures')
class SshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.etc = self.base / 'etc'; self.etc.mkdir()
        self.state = self.base / 'state'; self.state.mkdir(mode=0o700)
        self.system = self.base / 'system'; self.system.mkdir()
        self.policy = self.base / 'policy-rc.d'
        self.runtime = self.base / 'run-sshd'
        self.commands = []; self.installed = {'openssh-server','netcat-openbsd'}
        self.unit_status = {}; self.busy = False; self.fail_validate = False; self.fail_restart_once = False
        self.available_global_units={'ssh.service','ssh.socket'}
        self.undo = types.SimpleNamespace(install_args=mock.Mock(side_effect=lambda _i,argv:argv),finish=mock.Mock())
        self.i = types.SimpleNamespace(ETC=self.etc,STATE=self.state,OWNER='oneDebian-agent-v1',
            require_root=lambda:None, pwd=types.SimpleNamespace(getpwnam=lambda _:types.SimpleNamespace(pw_uid=1000,pw_dir='/home/agent')),
            run=self.command, capture=self.capture, read_json=self.read_json, write_json=self.write_json,
            atomic=self.atomic, owned_file=self.owned_file, port_free=lambda _:not self.busy,
            package_undo=self.undo)
        self.patches = [mock.patch.object(ssh,'SYSTEM',self.system),mock.patch.object(ssh,'POLICY',self.policy),
                        mock.patch.object(ssh,'RUNTIME',self.runtime)]
        for patch in self.patches: patch.start()
        self.connection = mock.MagicMock()
        self.connection.__enter__.return_value.recv.return_value=b'SSH-2.0-fixture\r\n'
        patch=mock.patch.object(ssh.socket,'create_connection',return_value=self.connection)
        patch.start(); self.patches.append(patch)

    def tearDown(self):
        for patch in reversed(self.patches): patch.stop()
        self.temp.cleanup()

    def read_json(self,path,default=None):
        return json.loads(path.read_text()) if path.exists() else default

    def atomic(self,path,text,mode=0o644):
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(text); path.chmod(mode)

    def write_json(self,path,value,mode=0o644):
        self.atomic(path,json.dumps(value),mode)

    def owned_file(self,path,content,mode=0o644):
        manifest=self.read_json(self.state/'files.json',{})
        if path.exists() and manifest.get(str(path)) != ssh._hash(path): raise RuntimeError('foreign fixture')
        self.atomic(path,content,mode)
        manifest[str(path)]=ssh._hash(path)
        self.write_json(self.state/'files.json',manifest)

    def capture(self,argv):
        return self.command(argv,capture_output=True,text=True).stdout.strip()

    def command(self,argv,**kwargs):
        argv=[str(arg) for arg in argv]; self.commands.append(argv)
        output=''
        if argv[:3]==['systemctl','show',ssh.UNIT] or argv[:2]==['systemctl','show']:
            values=self.unit_status.get(argv[2],dict(LoadState='not-found',ActiveState='inactive',UnitFileState='disabled',MainPID='0'))
            output='\n'.join(key+'='+value for key,value in values.items())
        elif argv[:2]==['dpkg-query','-W']:
            if argv[-1] not in self.installed: raise subprocess.CalledProcessError(1,argv)
            output='installed'
        elif argv[0]=='ss':
            values=self.unit_status.get(ssh.UNIT,{})
            if values.get('ActiveState')=='active':
                port=argv[-1].rsplit(':',1)[-1]
                output=f'LISTEN 0 128 127.0.0.1:{port} 0.0.0.0:* users:(("sshd",pid=123,fd=3))'
        elif argv[:2]==['ssh-keygen','-q']:
            target=Path(argv[-1]); target.write_text('fixture-private-host-key'); target.chmod(0o600)
            Path(str(target)+'.pub').write_text(PUBLIC+' fixture-host\n')
        elif argv[:2]==['ssh-keygen','-y']:
            output=PUBLIC
        elif argv[:2]==[ssh.SSHD,'-t'] and self.fail_validate:
            raise RuntimeError('invalid effective fixture')
        elif argv[:2]==[ssh.SSHD,'-T']:
            values={line.split(' ',1)[0].lower():line.split(' ',1)[1].strip('"') for line in (self.etc/'sshd_config').read_text().splitlines()}
            values['listenaddress']+=':'+values['port']
            output='\n'.join(key+' '+value for key,value in values.items())
        elif argv[0]=='apt-get':
            self.assertTrue(self.policy.exists())
            self.assertTrue((self.system/'ssh.service.d/90-onedebian-agent.conf').exists())
            self.installed.update(name for name in argv if name in {'openssh-server','netcat-openbsd'})
            for name in self.available_global_units:
                self.unit_status.setdefault(name,dict(LoadState='loaded',ActiveState='inactive',UnitFileState='enabled',MainPID='0'))
        elif argv[:2] in (['systemctl','start'],['systemctl','restart']):
            if argv[-1]==ssh.UNIT:
                if self.fail_restart_once:
                    self.fail_restart_once=False
                    raise RuntimeError('start failure fixture')
                self.unit_status[ssh.UNIT]=dict(LoadState='loaded',ActiveState='active',UnitFileState='enabled',MainPID='123')
        elif argv[:2]==['systemctl','stop'] and argv[-1]==ssh.UNIT:
            self.unit_status[ssh.UNIT]['ActiveState']='inactive'
        return types.SimpleNamespace(stdout=output)

    def test_setup_is_loopback_key_only_and_repeated_setup_keeps_host_identity(self):
        first=ssh.setup(self.i,PUBLIC+' client',2222)
        private=(self.etc/'ssh_host_ed25519_key').read_bytes()
        self.busy=True
        second=ssh.setup(self.i,PUBLIC+' another comment',2222)
        self.assertEqual(first['host_public_key'],second['host_public_key'])
        self.assertEqual((self.etc/'ssh_host_ed25519_key').read_bytes(),private)
        self.assertEqual((self.etc/'ssh_authorized_keys').read_text(),PUBLIC+'\n')
        self.assertEqual(first['state'],'SSH_READY')
        self.assertEqual(sum(command[:2]==['ssh-keygen','-q'] for command in self.commands),1)
        self.assertFalse(any(command[:2] in (['apt-get','install'],['systemctl','disable']) for command in self.commands))

    def test_public_key_options_private_material_and_multiline_are_rejected_before_changes(self):
        for value in ('-----BEGIN OPENSSH PRIVATE KEY-----','command="whoami" '+PUBLIC,PUBLIC+'\n'+PUBLIC,'ssh-ed25519 invalid!',None):
            with self.subTest(value=value):
                with self.assertRaises(RuntimeError): ssh.setup(self.i,value)
        self.assertEqual(list(self.etc.iterdir()),[])
        self.assertEqual(self.commands,[])

    def test_occupied_port_and_foreign_service_are_refused(self):
        self.busy=True
        with self.assertRaisesRegex(RuntimeError,'occupied'): ssh.setup(self.i,PUBLIC)
        self.assertFalse((self.etc/'sshd_config').exists())
        self.busy=False
        self.unit_status[ssh.UNIT]=dict(LoadState='loaded',ActiveState='active',MainPID='123')
        with self.assertRaisesRegex(RuntimeError,'unowned SSH service'): ssh.setup(self.i,PUBLIC)

    def test_configured_frontend_port_cannot_be_claimed_before_it_starts(self):
        self.write_json(self.etc/'config.json',{'mcp_port':2222})
        with self.assertRaisesRegex(RuntimeError,'configured browser'): ssh.setup(self.i,PUBLIC)
        self.assertEqual(self.commands,[])

    def test_modified_owned_configuration_is_retained_before_any_install(self):
        ssh.setup(self.i,PUBLIC)
        config=self.etc/'sshd_config'; config.write_text('foreign later edit')
        before=len(self.commands)
        with self.assertRaisesRegex(RuntimeError,'modified SSH file'): ssh.setup(self.i,PUBLIC)
        self.assertEqual(config.read_text(),'foreign later edit')
        self.assertFalse(any(command[0] in ('apt-get',ssh.SSHD) for command in self.commands[before:]))

    def test_new_server_install_guards_default_services_and_records_package_transaction(self):
        self.installed.clear()
        ssh.setup(self.i,PUBLIC)
        self.assertFalse(self.policy.exists())
        self.undo.install_args.assert_called_once(); self.undo.finish.assert_called_once()
        for name in ('ssh.service','ssh.socket'):
            guard=(self.system/(name+'.d')/'90-onedebian-agent.conf').read_text()
            self.assertIn('ConditionPathExists='+str(self.state/'allow-system-ssh'),guard)
            self.assertIn(['systemctl','disable',name],self.commands)
        self.assertFalse(any(command[:2]==['systemctl','stop'] and command[-1]!='onedebian-agent-ssh.service' for command in self.commands))

    def test_existing_global_service_and_policy_are_not_modified(self):
        self.installed.clear()
        original='#!/bin/sh\nexit 101\n'; self.policy.write_text(original); self.policy.chmod(0o755)
        self.unit_status['ssh.service']=dict(LoadState='loaded',ActiveState='active',UnitFileState='enabled',MainPID='42')
        # The fixture assertion expects a guard only for genuinely new units.
        real_run=self.command
        def run(argv,**kwargs):
            if str(argv[0])=='apt-get':
                self.commands.append([str(x) for x in argv]); self.installed.update(('openssh-server','netcat-openbsd'))
                return types.SimpleNamespace(stdout='')
            return real_run(argv,**kwargs)
        self.i.run=run
        ssh.setup(self.i,PUBLIC)
        self.assertEqual(self.policy.read_text(),original)
        self.assertFalse((self.system/'ssh.service.d').exists())
        self.assertNotIn(['systemctl','disable','ssh.service'],self.commands)
        self.assertEqual(self.unit_status['ssh.service']['MainPID'],'42')

    def test_debian_without_ssh_socket_does_not_fail_while_disabling_new_defaults(self):
        self.installed.clear(); self.available_global_units={'ssh.service'}
        result=ssh.setup(self.i,PUBLIC)
        self.assertEqual(result['state'],'SSH_READY')
        self.assertIn(['systemctl','disable','ssh.service'],self.commands)
        self.assertNotIn(['systemctl','disable','ssh.socket'],self.commands)
        self.assertTrue((self.system/'ssh.socket.d/90-onedebian-agent.conf').is_file())

    def test_validation_failure_rolls_back_own_files_but_keeps_new_package_guards(self):
        self.installed.clear(); self.fail_validate=True
        with self.assertRaisesRegex(RuntimeError,'invalid effective fixture'): ssh.setup(self.i,PUBLIC)
        self.assertEqual(list(self.etc.iterdir()),[])
        self.assertFalse(self.policy.exists())
        self.assertTrue((self.system/'ssh.service.d/90-onedebian-agent.conf').is_file())
        self.assertEqual(self.read_json(self.state/'ssh.json')['state'],'ERROR')
        self.undo.finish.assert_called_once()

    def test_failed_restart_restores_prior_own_service_and_host_key(self):
        ssh.setup(self.i,PUBLIC,2222)
        before={path.name:path.read_bytes() for path in self.etc.iterdir()}
        self.fail_restart_once=True
        with self.assertRaisesRegex(RuntimeError,'start failure'): ssh.setup(self.i,PUBLIC,2223)
        self.assertEqual({path.name:path.read_bytes() for path in self.etc.iterdir()},before)
        self.assertEqual(self.unit_status[ssh.UNIT]['ActiveState'],'active')
        self.assertIn(['systemctl','stop',ssh.UNIT],self.commands)
        self.assertEqual(self.commands[-2],['systemctl','daemon-reload'])
        self.assertEqual(self.commands[-1],['systemctl','start',ssh.UNIT])

    def test_recovery_failure_cannot_leave_a_stale_ready_record(self):
        ssh.setup(self.i,PUBLIC)
        self.fail_restart_once=True
        original=self.i.run
        def command(argv,**kwargs):
            if argv[:2]==['systemctl','stop']: raise RuntimeError('recovery stop fixture')
            return original(argv,**kwargs)
        self.i.run=command
        with self.assertRaisesRegex(RuntimeError,'recovery requires review'): ssh.setup(self.i,PUBLIC,2223)
        state=self.read_json(self.state/'ssh.json')
        self.assertEqual(state['state'],'ERROR')
        self.assertIn('start failure',state['error'])
        self.assertIn('recovery stop',state['recovery_error'])


if __name__ == '__main__':
    unittest.main()
