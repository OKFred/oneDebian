"""Keyring initialization uses disposable files and a private D-Bus replacement."""
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('agent_keyring', Path(__file__).resolve().parents[1] / 'agent/keyring.py')
keyring = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(keyring)
IDENTITY = keyring._identity


class KeyringTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.config = dict(home=str(self.home), uid=os.getuid())
        self.store = self.home / '.local/share/keyrings'
        identity = mock.patch.object(keyring, '_identity', return_value=os.getuid())
        identity.start(); self.addCleanup(identity.stop)
        bus = mock.patch.dict(os.environ, {'DBUS_SESSION_BUS_ADDRESS': 'unix:path=/fixture/private-bus',
                                          'XDG_DATA_HOME': str(self.home / '.local/share')})
        bus.start(); self.addCleanup(bus.stop)

    def create(self):
        login = self.store / 'Login.keyring'
        login.write_bytes(b'[keyring]\nname=Login\n')
        login.chmod(0o600)
        return '/org/freedesktop/secrets/collection/Login'

    def test_new_keyring_verifies_default_unlocked_collection_and_private_file(self):
        with mock.patch.object(keyring, '_create_default', side_effect=self.create) as create:
            result = keyring.ensure_empty(self.config)
        self.assertEqual(result['state'], 'INITIALIZED')
        self.assertFalse(result['locked'])
        create.assert_called_once_with()

    def test_repeated_call_retains_existing_keyring_without_dbus_modifications(self):
        with mock.patch.object(keyring, '_create_default', side_effect=self.create):
            keyring.ensure_empty(self.config)
        before = (self.store / 'Login.keyring').read_bytes()
        with mock.patch.object(keyring, '_create_default') as create:
            result = keyring.ensure_empty(self.config)
        self.assertEqual(result['state'], 'RETAINED')
        self.assertEqual((self.store / 'Login.keyring').read_bytes(), before)
        create.assert_not_called()

    def test_existing_encrypted_or_unknown_data_is_never_changed(self):
        self.store.mkdir(parents=True)
        encrypted = self.store / 'login.keyring'
        encrypted.write_bytes(b'GnomeKeyring\n\r\0\nprivate-fixture-bytes')
        before = encrypted.read_bytes()
        with mock.patch.object(keyring, '_create_default') as create:
            self.assertEqual(keyring.ensure_empty(self.config)['state'], 'RETAINED')
        self.assertEqual(encrypted.read_bytes(), before)
        create.assert_not_called()

    @unittest.skipIf(os.name == 'nt', 'Linux filesystem boundary')
    def test_symlink_in_keyring_path_or_entries_is_rejected(self):
        outside = self.home / 'outside'; outside.mkdir()
        (self.home / '.local').symlink_to(outside, target_is_directory=True)
        with mock.patch.object(keyring, '_create_default') as create:
            with self.assertRaisesRegex(RuntimeError, 'Unsafe keyring directory'):
                keyring.ensure_empty(self.config)
        create.assert_not_called()
        (self.home / '.local').unlink()
        self.store.mkdir(parents=True)
        (self.store / 'login.keyring').symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, 'Unsafe existing keyring entry'):
            keyring.ensure_empty(self.config)

    def test_missing_bus_or_custom_data_home_stops_before_creating_directories(self):
        for env in ({}, {'DBUS_SESSION_BUS_ADDRESS':'private', 'XDG_DATA_HOME':'/another/path'}):
            with self.subTest(env=env), mock.patch.dict(os.environ, env, clear=True), \
                 mock.patch.object(keyring, '_create_default') as create:
                with self.assertRaises(RuntimeError):
                    keyring.ensure_empty(self.config)
                self.assertFalse((self.home / '.local').exists())
                create.assert_not_called()

    def test_dbus_failure_does_not_report_initialization_success(self):
        with mock.patch.object(keyring, '_create_default', side_effect=RuntimeError('private bus timeout')):
            with self.assertRaisesRegex(RuntimeError, 'timeout'):
                keyring.ensure_empty(self.config)

    def test_binary_keyring_cannot_be_reported_as_new_empty_password_keyring(self):
        def create():
            collection = self.create()
            (self.store / 'Login.keyring').write_bytes(b'GnomeKeyring\n\r\0\n')
            return collection
        with mock.patch.object(keyring, '_create_default', side_effect=create):
            with self.assertRaisesRegex(RuntimeError, 'format was not confirmed'):
                keyring.ensure_empty(self.config)

    def test_identity_refuses_root_or_foreign_uid(self):
        for uid, effective, configured in [(0, 0, 0), (1000, 0, 1000), (1000, 1000, 1001)]:
            with self.subTest(uid=uid, effective=effective, configured=configured), \
                 mock.patch.object(keyring.os, 'getuid', return_value=uid), \
                 mock.patch.object(keyring.os, 'geteuid', return_value=effective):
                with self.assertRaises(RuntimeError):
                    IDENTITY(dict(uid=configured))

    def test_gio_uses_one_session_zero_byte_secret_and_verifies_alias_and_lock(self):
        class Variant:
            def __init__(self, signature, values): self.signature, self.values = signature, values
        session='/org/freedesktop/secrets/session/fixture'
        collection='/org/freedesktop/secrets/collection/Login'
        for fault in (None, 'existing', 'locked', 'alias'):
            calls=[]
            def invoke(destination, target, interface, method, params, *args):
                calls.append((target,interface,method,params))
                if method=='ReadAlias':
                    value=collection if fault=='existing' or len(calls)>1 else '/'
                    if fault=='alias' and len(calls)>1:value='/'
                    values=(value,)
                elif method=='OpenSession':values=('',session)
                elif method=='CreateWithMasterPassword':values=(collection,)
                elif method=='Get':values=(fault=='locked',)
                else:values=()
                return types.SimpleNamespace(unpack=lambda:values)
            connection=types.SimpleNamespace(call_sync=invoke)
            gio=types.SimpleNamespace(bus_get_sync=lambda *_:connection,BusType=types.SimpleNamespace(SESSION=0),DBusCallFlags=types.SimpleNamespace(NONE=0))
            modules={'gi':types.ModuleType('gi'), 'gi.repository':types.SimpleNamespace(Gio=gio,GLib=types.SimpleNamespace(Variant=Variant))}
            with self.subTest(fault=fault), mock.patch.dict(sys.modules, modules):
                if fault:
                    with self.assertRaises(RuntimeError): keyring._create_default()
                else:
                    self.assertEqual(keyring._create_default(),collection)
                    create=next(item for item in calls if item[2]=='CreateWithMasterPassword')
                    self.assertEqual(create[3].signature,'(a{sv}(oayays))')
                    self.assertEqual(create[3].values[1],(session,[],[],'text/plain'))
                    self.assertEqual(calls[-1][2],'Close')
                if fault=='existing':self.assertEqual(len(calls),1)
                else:self.assertEqual(calls[-1][2],'Close')


if __name__ == '__main__':
    unittest.main()