"""APT undo fixtures never install/remove real packages or touch real system state."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('agent_package_undo', Path(__file__).resolve().parents[1] / 'agent/package_undo.py')
undo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(undo)


def protocol(*rows):
    return 'VERSION 3\nAPT::Architecture=amd64\n\n' + '\n'.join(rows) + '\n'


def package(version='1', essential=False, priority='optional', status_name='installed'):
    return dict(version=version, essential=essential, priority=priority, status=status_name)


@unittest.skipUnless(sys.platform == 'linux' and os.geteuid() == 0, 'Linux root-owned file fixtures')
class PackageUndoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.state = self.base / 'state'
        self.state.mkdir(mode=0o700)
        (self.state / '.owner').write_text(undo.OWNER)
        self.current = {'basepkg:amd64': package(essential=True, priority='required')}
        self.manual = ['basepkg']
        self.held = []
        self.calls = []
        self.extra_simulation = ''
        self.i = types.SimpleNamespace(STATE=self.state, OWNER=undo.OWNER, PACKAGES=['desktop', 'tool'],
                                       atomic=self.atomic, write_json=self.write_json, run=self.run_command)

    def tearDown(self):
        self.temp.cleanup()

    def atomic(self, path, text, mode=0o600):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(mode)

    def write_json(self, path, value, mode=0o600):
        self.atomic(path, json.dumps(value), mode)

    def run_command(self, argv, **kwargs):
        argv = [str(x) for x in argv]
        self.calls.append(argv)
        if argv[:2] == ['dpkg-query', '-W']:
            rows = []
            for key, info in self.current.items():
                name, arch = key.split(':')
                rows.append('\t'.join([name, arch, info['version'], info['status'], 'yes' if info['essential'] else 'no', info['priority']]))
            output = '\n'.join(rows)
        elif argv == ['apt-mark', 'showmanual']:
            output = '\n'.join(self.manual)
        elif argv == ['apt-mark', 'showhold']:
            output = '\n'.join(self.held)
        elif argv == ['dpkg', '--print-architecture']:
            output = 'amd64'
        elif argv[0] == 'apt-get':
            names = argv[argv.index('remove') + 1:]
            if '--simulate' in argv:
                output = '\n'.join('Remv ' + key + ' [' + self.current[key]['version'] + ']' for key in names) + self.extra_simulation
            else:
                for key in names:
                    self.current.pop(key)
                    self.manual = [x for x in self.manual if x not in (key, key.split(':')[0])]
                output = ''
        elif argv[:2] == ['apt-mark', 'auto']:
            self.manual = [x for x in self.manual if x not in argv[2:] and x + ':amd64' not in argv[2:]]
            output = ''
        else:
            raise AssertionError('Unexpected command: ' + str(argv))
        return types.SimpleNamespace(stdout=output, returncode=0)

    def own(self, name='desktop', version='2'):
        record = undo.prepare(self.i)
        undo._record_actions(record, protocol(f'{name} - - none < {version} amd64 none /cache/{name}.deb'))
        undo._save(self.i, record)
        self.current[name + ':amd64'] = package(version)
        self.manual.append(name)
        undo.finish(self.i)

    def test_baseline_and_protocol_attribute_only_new_actions(self):
        first = undo.prepare(self.i)
        text = protocol('desktop - - none < 2 amd64 none /cache/desktop.deb',
                        'basepkg 1 amd64 none < 2 amd64 none /cache/basepkg.deb',
                        'desktop 2 amd64 none = 2 amd64 none **CONFIGURE**')
        undo._record_actions(first, text)
        undo._save(self.i, first)
        self.current['foreign:amd64'] = package()
        again = undo.prepare(self.i)
        self.assertEqual(again['added'], {'desktop:amd64':'2'})
        self.assertNotIn('foreign:amd64', again['before']['packages'])
        self.assertEqual(again['before']['packages']['basepkg:amd64']['version'], '1')
        self.assertTrue(again['baseline_complete'])

    def test_protocol_refuses_missing_downgraded_and_malformed_formats(self):
        for value in ['', '/cache/a.deb\n', 'VERSION 2\n\na - < 1 /cache/a.deb\n', protocol('invalid !')]:
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                list(undo.actions(value))

    def test_legacy_plan_does_not_guess_package_ownership_or_write(self):
        (self.state / 'state.json').write_text('{"state":"READY_SOFTWARE"}')
        before = sorted(p.name for p in self.state.iterdir())
        missing = undo.plan(self.i)
        self.assertEqual(missing['remove'], [])
        self.assertFalse(missing['baseline_complete'])
        self.assertEqual(before, sorted(p.name for p in self.state.iterdir()))
        record = undo.prepare(self.i)
        self.assertFalse(record['baseline_complete'])
        self.assertEqual(undo.plan(self.i)['remove'], [])

    def test_new_uninstalled_directory_plan_is_zero_write(self):
        self.i.STATE = self.base / 'absent'
        self.assertFalse(undo.plan(self.i)['baseline_complete'])
        self.assertFalse(self.i.STATE.exists())

    def test_plan_retains_modified_essential_held_and_preexisting_packages(self):
        record = undo.prepare(self.i)
        for name in ('modified', 'essential', 'held', 'ordinary'):
            record['added'][name + ':amd64'] = '2'
            self.current[name + ':amd64'] = package('2')
        record['added']['basepkg:amd64'] = '1'
        undo._save(self.i, record)
        self.current['modified:amd64']['version'] = '3'
        self.current['essential:amd64']['essential'] = True
        self.held = ['held']
        plan = undo.plan(self.i)
        self.assertEqual(plan['remove'], ['ordinary:amd64'])
        self.assertEqual({x['name'] for x in plan['retained']}, {'modified:amd64','essential:amd64','held:amd64','basepkg:amd64'})
        self.assertFalse(plan['blocked'])

    def test_solver_cannot_remove_foreign_dependents_or_install_packages(self):
        self.own()
        self.current['foreign:amd64'] = package()
        self.extra_simulation = '\nRemv foreign [1]\nInst surprise (1 repo)\n'
        plan = undo.plan(self.i)
        self.assertTrue(plan['blocked'])
        with self.assertRaisesRegex(RuntimeError, 'blocked'):
            undo.apply(self.i, plan)
        self.assertFalse(any(x[0] == 'apt-get' and '--simulate' not in x for x in self.calls))

    def test_guard_checks_inventory_and_every_actual_action(self):
        self.own()
        plan = undo.plan(self.i)
        good = protocol('desktop 2 amd64 none > - - none **REMOVE**')
        undo.guard(self.i, plan, good)
        for bad in [protocol('basepkg 1 amd64 none > - - none **REMOVE**'),
                    protocol('desktop 2 amd64 none = 2 amd64 none **CONFIGURE**'),
                    protocol('desktop 2 amd64 none < 3 amd64 none /cache/desktop.deb'), protocol()]:
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                undo.guard(self.i, plan, bad)
        self.current['desktop:amd64']['version'] = '3'
        with self.assertRaisesRegex(RuntimeError, 'inventory changed'):
            undo.guard(self.i, plan, good)

    def test_apply_rejects_changed_plan_and_uses_transaction_guard_without_autoremove(self):
        self.own()
        plan = undo.plan(self.i)
        self.current['foreign:amd64'] = package()
        with self.assertRaisesRegex(RuntimeError, 'changed'):
            undo.apply(self.i, plan)
        result = undo.apply(self.i, undo.plan(self.i))
        self.assertEqual(result['removed'], ['desktop:amd64'])
        self.assertTrue(result['configuration_files_retained'])
        command = next(x for x in self.calls if x[0] == 'apt-get' and '--simulate' not in x)
        self.assertIn('remove', command)
        self.assertNotIn('purge', command)
        self.assertNotIn('autoremove', command)
        self.assertIn('DPkg::Pre-Install-Pkgs::=' + str(self.state / 'package-undo-hook.sh') + ' guard', command)
        self.assertTrue((self.state / 'package-undo-approved.json').exists())

    def test_auto_marks_restore_only_when_owned_after_state_still_matches(self):
        self.current['tool:amd64'] = package()
        undo.prepare(self.i)
        undo.install_args(self.i, ['apt-get', 'install', 'tool'])
        self.manual.append('tool')
        undo.finish(self.i)
        self.assertEqual(undo.plan(self.i)['restore_auto'], ['tool:amd64'])
        self.manual.append('foreign')
        changed = undo.plan(self.i)
        self.assertEqual(changed['restore_auto'], [])
        self.assertTrue(any(x['name'] == 'tool:amd64' and 'flag' in x['reason'] for x in changed['retained']))

    def test_manual_flag_restore_is_verified_and_missing_restore_is_reported(self):
        self.current['tool:amd64'] = package()
        undo.prepare(self.i)
        undo.install_args(self.i, ['apt-get', 'install', 'tool'])
        self.manual.append('tool')
        undo.finish(self.i)
        expected = undo.plan(self.i)
        original = self.i.run
        def ignored_mark(argv, **kwargs):
            if list(argv)[:2] == ['apt-mark', 'auto']:
                return types.SimpleNamespace(stdout='', returncode=0)
            return original(argv, **kwargs)
        self.i.run = ignored_mark
        failed = undo.apply(self.i, expected)
        self.assertEqual(failed['restored_auto'], [])
        self.assertEqual(failed['unrestored_auto'], ['tool:amd64'])
        self.assertTrue(failed['warnings'])
        self.assertTrue(any(x['name'] == 'tool:amd64' for x in failed['retained']))
        self.i.run = original
        done = undo.apply(self.i, undo.plan(self.i))
        self.assertEqual(done['restored_auto'], ['tool:amd64'])
        self.assertEqual(done['unrestored_auto'], [])
        self.assertEqual(done['warnings'], [])

    def test_manual_flags_changed_during_remove_are_reported_not_silently_skipped(self):
        self.current['tool:amd64'] = package()
        undo.prepare(self.i)
        undo.install_args(self.i, ['apt-get', 'install', 'tool'])
        self.manual.append('tool')
        self.own()
        expected = undo.plan(self.i)
        original = self.i.run
        def changed_after_remove(argv, **kwargs):
            result = original(argv, **kwargs)
            if argv[0] == 'apt-get' and '--simulate' not in argv:
                self.manual.append('foreign')
            return result
        self.i.run = changed_after_remove
        result = undo.apply(self.i, expected)
        self.assertEqual(result['unrestored_auto'], ['tool:amd64'])
        self.assertTrue(result['warnings'])
        self.assertFalse(any(x[:2] == ['apt-mark', 'auto'] for x in self.calls))

    def test_already_removed_packages_with_retained_conffiles_are_not_removed_again(self):
        self.own()
        self.current['desktop:amd64']['status'] = 'config-files'
        self.manual.remove('desktop')
        plan = undo.plan(self.i)
        self.assertEqual(plan['remove'], [])
        self.assertEqual(plan['retained'], [{'name':'desktop:amd64','reason':'configuration files retained'}])
        result = undo.apply(self.i, plan)
        self.assertEqual(result['removed'], [])
        self.assertFalse(any(x[0] == 'apt-get' and '--simulate' not in x for x in self.calls))

    def test_bootstrap_raw_protocol_import_and_reinstallation_baseline(self):
        (self.state / 'package-undo-baseline.tsv').write_text('basepkg\tamd64\t1\tinstalled\tyes\trequired\n')
        (self.state / 'package-undo-manual.before').write_text('basepkg\n')
        (self.state / 'package-undo-held.before').write_text('')
        (self.state / 'package-undo-architecture.before').write_text('amd64\n')
        (self.state / 'package-undo-bootstrap-actions.log').write_text(protocol('python3 - - none < 3.13 amd64 none /cache/python.deb'))
        record = undo.prepare(self.i)
        self.assertTrue(record['baseline_complete'])
        self.assertEqual(record['added'], {'python3:amd64':'3.13'})
        generation = record['generation']
        undo.reset(self.i)
        (self.state / 'state.json').write_text('{"state":"UNINSTALLED"}')
        self.current['foreign:amd64'] = package()
        next_record = undo.prepare(self.i)
        self.assertTrue(next_record['baseline_complete'])
        self.assertNotEqual(next_record['generation'], generation)
        self.assertEqual(next_record['added'], {})
        self.assertIn('foreign:amd64', next_record['before']['packages'])
        self.assertTrue((self.state / 'package-undo-history' / generation / 'package-undo.json').exists())

    def test_reset_resumes_existing_generation_directory_and_partial_archival(self):
        generation = undo.prepare(self.i)['generation']
        archive = self.state / 'package-undo-history'
        target = archive / generation
        target.mkdir(mode=0o700, parents=True)
        archive.chmod(0o700)
        (self.state / 'package-undo-baseline.tsv').write_text('test baseline\n')
        (self.state / 'package-undo-manual.before').write_text('basepkg\n')
        original = Path.rename
        def interrupted(path, destination):
            if path.name == 'package-undo-manual.before':
                raise RuntimeError('fixture interruption')
            return original(path, destination)
        with mock.patch.object(Path, 'rename', autospec=True, side_effect=interrupted):
            with self.assertRaisesRegex(RuntimeError, 'fixture interruption'):
                undo.reset(self.i)
        self.assertFalse((self.state / 'package-undo.json').exists())
        self.assertTrue((self.state / 'package-undo-reset-pending').exists())
        undo.reset(self.i)
        self.assertEqual((self.state / 'package-undo-reset').read_text().strip(), generation)
        self.assertFalse((self.state / 'package-undo-reset-pending').exists())
        self.assertTrue((target / 'package-undo-manual.before').exists())
        undo.reset(self.i)
        self.assertEqual(list(archive.iterdir()), [target])

    def test_reset_refuses_an_existing_nonprivate_generation_directory(self):
        generation = undo.prepare(self.i)['generation']
        target = self.state / 'package-undo-history' / generation
        target.mkdir(mode=0o755, parents=True)
        target.parent.chmod(0o700)
        with self.assertRaisesRegex(RuntimeError, 'Untrusted package undo generation'):
            undo.reset(self.i)
        self.assertTrue((self.state / 'package-undo.json').exists())

    def test_root_state_trust_and_symlink_checks_precede_mutation(self):
        outside = self.base / 'outside'
        outside.mkdir()
        link = self.base / 'link'
        link.symlink_to(outside, target_is_directory=True)
        self.i.STATE = link
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            undo.prepare(self.i)
        self.assertFalse(any(outside.iterdir()))
        self.i.STATE = self.state
        target = self.state / 'package-undo.json'
        target.symlink_to(self.base / 'unrelated')
        with self.assertRaises(RuntimeError):
            undo.prepare(self.i)

    def test_bootstrap_shell_captures_before_python_and_spools_protocol_privately(self):
        scripts = self.base / 'bootstrap-source'
        scripts.mkdir()
        target = self.base / 'bootstrap-state'
        source = Path(undo.__file__).parent
        body = (source / 'package-undo-hook.sh').read_text()
        self.assertEqual(body.count('state=/var/lib/onedebian-agent'), 1)
        body = body.replace('state=/var/lib/onedebian-agent', 'state=' + shlex.quote(str(target)))
        body = body.replace('[ -x /usr/bin/python3 ]', '[ -x ' + shlex.quote(str(self.base / 'no-python')) + ' ]')
        helper = scripts / 'package-undo-hook.sh'
        helper.write_text(body)
        (scripts / 'package_undo.py').write_text(Path(undo.__file__).read_text())
        subprocess.run(['/bin/sh', str(helper), 'bootstrap-init'], check=True, capture_output=True)
        self.assertTrue((target / 'package-undo-baseline.tsv').exists())
        self.assertEqual((target / 'package-undo-baseline.tsv').stat().st_mode & 0o777, 0o600)
        stream = protocol('onedebian-fixture - - none < 1 amd64 none /cache/fixture.deb')
        subprocess.run(['/bin/sh', str(helper), 'record'], input=stream, text=True, check=True, capture_output=True)
        self.assertEqual((target / 'package-undo-bootstrap-actions.log').read_text(), stream)
        self.i.STATE = target
        record = undo.prepare(self.i)
        self.assertTrue(record['baseline_complete'])
        self.assertEqual(record['added'], {'onedebian-fixture:amd64':'1'})
        generation = record['generation']
        (target / 'state.json').write_text('{"state":"CLEANED_PARTIAL"}')
        (target / 'user-owned').write_text('agent\n')
        undo.reset(self.i)
        subprocess.run(['/bin/sh', str(helper), 'bootstrap-init'], check=True, capture_output=True)
        self.assertTrue((target / 'package-undo-baseline.tsv').exists())
        self.assertFalse((target / 'package-undo-legacy').exists())
        after_reset = undo.prepare(self.i)
        self.assertTrue(after_reset['baseline_complete'])
        self.assertNotEqual(after_reset['generation'], generation)
        self.assertEqual(after_reset['added'], {})
        (target / 'package-undo-reset').chmod(0o644)
        refused = subprocess.run(['/bin/sh', str(helper), 'bootstrap-init'], capture_output=True)
        self.assertNotEqual(refused.returncode, 0)
        (target / 'package-undo-reset').chmod(0o600)
        target.chmod(0o777)
        refused = subprocess.run(['/bin/sh', str(helper), 'bootstrap-init'], capture_output=True)
        self.assertNotEqual(refused.returncode, 0)

    def test_real_apt_delivers_v3_guard_before_any_dpkg_action_in_private_database(self):
        root = self.base / 'private-apt'
        for part in ('state/lists/partial', 'cache/archives/partial', 'log', 'etc/parts'):
            (root / part).mkdir(parents=True)
        status_file = root / 'state/status'
        status_text = ('Package: onedebian-fixture\nStatus: install ok installed\nPriority: optional\n'
                       'Section: misc\nInstalled-Size: 1\nMaintainer: oneDebian test\nArchitecture: amd64\n'
                       'Version: 1\nDescription: disposable package metadata\n\n')
        status_file.write_text(status_text)
        for part in ('etc/sources.list', 'etc/empty.conf'):
            (root / part).write_text('')
        sentinel = root / 'dpkg-sentinel'
        sentinel.write_text('#!/bin/sh\nprintf %s called > ' + shlex.quote(str(root / 'dpkg-called')) + '\nexit 99\n')
        sentinel.chmod(0o700)
        stream = root / 'hook-stream'
        hook = root / 'guard-hook'
        hook.write_text('#!/bin/sh\ncat > ' + shlex.quote(str(stream)) + '\nexit 73\n')
        hook.chmod(0o700)
        config = root / 'apt.conf'
        config.write_text('\n'.join([
            f'Dir::State "{root}/state";', f'Dir::State::status "{status_file}";',
            f'Dir::State::extended_states "{root}/state/extended_states";',
            f'Dir::Cache "{root}/cache";', f'Dir::Log "{root}/log";',
            f'Dir::Etc::sourcelist "{root}/etc/sources.list";', f'Dir::Etc::sourceparts "{root}/etc/parts";',
            f'Dir::Etc::parts "{root}/etc/parts";', f'Dir::Etc::main "{root}/etc/empty.conf";',
            f'Dir::Bin::dpkg "{sentinel}";', 'APT::Architecture "amd64";',
            'APT::Architectures:: "amd64";', 'DPkg::Inhibit-Shutdown "false";', 'Debug::NoLocking "true";',
        ]))
        result = subprocess.run(['apt-get', '-y', '-o', 'DPkg::Pre-Install-Pkgs::=' + str(hook) + ' guard',
                                 '-o', 'DPkg::Tools::Options::' + str(hook) + '::Version=3',
                                 'remove', 'onedebian-fixture'],
                                env=dict(os.environ, APT_CONFIG=str(config), LC_ALL='C', LANG='C'),
                                capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(stream.exists(), result.stdout + result.stderr)
        self.assertEqual(list(undo.actions(stream.read_text())),
                         [dict(name='onedebian-fixture:amd64', old='1', new='-', action='**REMOVE**')])
        self.assertFalse((root / 'dpkg-called').exists(), 'Private fake dpkg must not be reached after guard rejection')
        self.assertEqual(status_file.read_text(), status_text)


if __name__ == '__main__':
    unittest.main()
