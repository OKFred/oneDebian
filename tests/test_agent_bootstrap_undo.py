"""Bootstrap undo shell integration entirely inside a disposable Linux tree."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import unittest

import test_agent_cleanup as fixtures

cleanup = fixtures.cleanup


class BootstrapUndoTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.CleanupTests('test_plan_is_read_only_and_rejects_active_install_on_apply')
        self.fixture.setUp()
        self.addCleanup(self.fixture.tearDown)
        self.base, self.i = self.fixture.base, self.fixture.i
        self.apt = self.base / 'etc/apt'
        (self.apt / 'sources.list.d').mkdir(parents=True)
        self.source = self.apt / 'sources.list'
        self.source.write_text('deb https://before.invalid/debian trixie main\n')
        text = (Path(__file__).resolve().parents[1] / 'agent/undo-bootstrap-sources.sh').read_text()
        text = text.replace('state=/var/lib/onedebian-agent', 'state=' + shlex.quote(str(self.i.STATE)))
        text = text.replace('for directory in /var /var/lib ',
                            'for directory in ' + shlex.quote(str(self.base/'var')) + ' ' + shlex.quote(str(self.base/'var/lib')) + ' ')
        text = text.replace('/etc/apt', str(self.apt))
        self.script = self.base / 'undo-bootstrap-sources.sh'
        self.script.write_text(text)

    def run_shell(self, action, env=None):
        return subprocess.run(['/bin/sh',str(self.script),action], env=env,
                              capture_output=True,text=True,timeout=15)

    def completed(self):
        cleanup.prepare(self.i)
        ledger = self.i.read_json(self.i.STATE / cleanup.LEDGER)
        ledger['applied'] = True
        self.i.write_json(self.i.STATE / cleanup.LEDGER,ledger,0o600)
        self.i.write_json(self.i.STATE/'cleanup-completed.json',
                          dict(owner=self.i.OWNER,state='CLEANED',receipt_id='fixture'),0o600)
        self.i.write_json(self.i.STATE/'package-undo.json',{'fixture':'old package record'},0o600)
        pending=self.i.STATE/'package-undo-reset-pending'
        pending.write_text('a'*32+'\n'); pending.chmod(0o600)
        self.i.write_json(self.i.STATE/'state.json',{'state':'CLEANED'},0o644)

    def test_before_seal_import_restores_original_and_preview_hides_contents(self):
        before=self.source.read_bytes()
        result=self.run_shell('before'); self.assertEqual(result.returncode,0,result.stderr)
        self.source.write_text('deb https://localized.invalid/debian trixie main\n')
        after=self.source.read_bytes()
        result=self.run_shell('seal'); self.assertEqual(result.returncode,0,result.stderr)
        data=cleanup.prepare(self.i)
        self.assertEqual(data['before'][str(self.source)]['sha256'],hashlib.sha256(before).hexdigest())
        self.assertEqual(data['after'][str(self.source)]['sha256'],hashlib.sha256(after).hexdigest())
        preview=json.dumps(self.fixture.plan())
        self.assertNotIn(before.decode().strip(),preview)
        self.fixture.apply()
        self.assertEqual(self.source.read_bytes(),before)

    def test_reset_archives_only_metadata_and_next_prepare_is_fresh(self):
        self.completed()
        for name in ('installed.json', 'gpu.json'):
            self.i.write_json(self.i.STATE/name, {'old_generation':name})
        state=(self.i.STATE/'state.json').read_bytes()
        result=self.run_shell('reset'); self.assertEqual(result.returncode,0,result.stderr)
        archives=list(self.i.STATE.glob('cleanup-bootstrap-history.*'))
        self.assertEqual(len(archives),1)
        self.assertTrue((archives[0]/'package-undo-reset-pending').is_file())
        self.assertFalse((self.i.STATE/'package-undo-reset-pending').exists())
        self.assertTrue((archives[0]/cleanup.LEDGER).is_file())
        self.assertTrue((archives[0]/'package-undo.json').is_file())
        for name in ('installed.json', 'gpu.json'):
            self.assertFalse((self.i.STATE/name).exists())
            self.assertEqual(self.i.read_json(archives[0]/name), {'old_generation':name})
        self.assertFalse((self.i.STATE/'cleanup-completed.json').exists())
        self.assertEqual((self.i.STATE/'cleanup-reset').read_text(),self.i.OWNER)
        self.assertEqual((self.i.STATE/'state.json').read_bytes(),state)
        kept=self.fixture.home_file('.local/share/fnm/later-user-node','retained user runtime')
        new=cleanup.prepare(self.i)
        self.assertFalse(new['legacy'])
        self.assertIn(str(kept),new['before'][str(self.fixture.home/'.local/share/fnm')])
        self.assertFalse((self.i.STATE/'cleanup-reset').exists())

    def test_reset_can_resume_after_first_metadata_move_is_interrupted(self):
        self.completed()
        bindir=self.base/'bin'; bindir.mkdir()
        marker=self.base/'mv-interrupted'
        stub=bindir/'mv'
        stub.write_text('#!/bin/sh\nset -eu\nif [ ! -e '+shlex.quote(str(marker))+' ]; then\n'
                        '  : > '+shlex.quote(str(marker))+'\n  /usr/bin/mv "$@"\n  exit 91\nfi\nexec /usr/bin/mv "$@"\n')
        stub.chmod(0o755)
        env=dict(os.environ,PATH=str(bindir)+':'+os.environ['PATH'])
        result=self.run_shell('reset',env)
        self.assertEqual(result.returncode,91,result.stderr)
        self.assertTrue((self.i.STATE/'cleanup-bootstrap-reset').exists())
        self.assertTrue((self.i.STATE/'cleanup-completed.json').exists())
        result=self.run_shell('reset',env); self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(list(self.i.STATE.glob('cleanup-bootstrap-history.*'))),1)
        self.assertFalse((self.i.STATE/'cleanup-bootstrap-reset').exists())
        self.assertFalse((self.i.STATE/'cleanup-completed.json').exists())
        self.assertEqual((self.i.STATE/'cleanup-reset').read_text(),self.i.OWNER)
        self.assertFalse(cleanup.prepare(self.i)['legacy'])

    def test_symlink_metadata_refuses_before_markers_or_external_changes(self):
        self.completed()
        external=self.base/'external'; external.write_text('external state remains')
        original=external.read_bytes()
        for name in ('package-undo.json','cleanup-reset','package-undo-reset','cleanup-bootstrap-reset'):
            with self.subTest(name=name):
                path=self.i.STATE/name
                if path.exists(): path.unlink()
                path.symlink_to(external)
                result=self.run_shell('reset')
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(external.read_bytes(),original)
                self.assertTrue((self.i.STATE/cleanup.LEDGER).exists())
                self.assertTrue((self.i.STATE/'cleanup-completed.json').exists())
                self.assertFalse(list(self.i.STATE.glob('cleanup-bootstrap-history.*')))
                self.assertFalse((self.i.STATE/'cleanup-reset').exists() and not (self.i.STATE/'cleanup-reset').is_symlink())
                path.unlink()
                if name=='package-undo.json':
                    self.i.write_json(path,{'fixture':'old package record'},0o600)


if __name__ == '__main__': unittest.main()
