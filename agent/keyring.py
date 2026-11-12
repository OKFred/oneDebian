#!/usr/bin/env python3
"""Initialize only a new user's empty-password login keyring; retain existing secrets."""
import os
from pathlib import Path
import re
import stat


def _identity(config):
    uid = os.getuid()
    if uid == 0 or os.geteuid() != uid or config.get('uid', uid) != uid:
        raise RuntimeError('Initialize the keyring as the ordinary Agent user')
    return uid


def _directory(path, uid, create=False):
    if path.is_symlink():
        raise RuntimeError('Unsafe keyring directory: ' + str(path))
    if not path.exists():
        if not create:
            return False
        path.mkdir(mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid or info.st_mode & 0o022:
        raise RuntimeError('Unsafe keyring directory: ' + str(path))
    return True


def _create_default():
    from gi.repository import Gio, GLib
    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    service = 'org.freedesktop.Secret.Service'
    path = '/org/freedesktop/secrets'
    def call(interface, method, signature, values, target=path):
        return connection.call_sync('org.freedesktop.secrets', target, interface, method,
            GLib.Variant(signature, values), None, Gio.DBusCallFlags.NONE, 15000, None).unpack()
    if call(service, 'ReadAlias', '(s)', ('default',))[0] != '/':
        raise RuntimeError('A default keyring appeared during initialization; it was retained')
    session = call(service, 'OpenSession', '(sv)', ('plain', GLib.Variant('s', '')))[1]
    try:
        # shortcut: GNOME's no-prompt creation API; revisit if the daemon drops it.
        collection = call('org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface',
            'CreateWithMasterPassword', '(a{sv}(oayays))',
            ({'org.freedesktop.Secret.Collection.Label': GLib.Variant('s', 'Login')},
             (session, [], [], 'text/plain')))[0]
        if not re.fullmatch(r'/org/freedesktop/secrets/collection/[A-Za-z0-9_]+', collection):
            raise RuntimeError('The new keyring collection path is invalid')
        call(service, 'SetAlias', '(so)', ('default', collection))
        if call(service, 'ReadAlias', '(s)', ('default',))[0] != collection:
            raise RuntimeError('The new keyring is not the default collection')
        locked = call('org.freedesktop.DBus.Properties', 'Get', '(ss)',
                      ('org.freedesktop.Secret.Collection', 'Locked'), collection)[0]
        if locked is not False:
            raise RuntimeError('New default keyring is still locked; initialization did not pass')
        return collection
    finally:
        call('org.freedesktop.Secret.Session', 'Close', '()', (), session)


def ensure_empty(config):
    """Return INITIALIZED or RETAINED; never replace or change an existing keyring."""
    uid = _identity(config)
    home = Path(config['home'])
    if not home.is_absolute() or '..' in home.parts:
        raise RuntimeError('Invalid Agent home for keyring initialization')
    if not _directory(home, uid):
        raise RuntimeError('The Agent home must already exist')
    folders = [home / '.local', home / '.local/share', home / '.local/share/keyrings']
    complete = True
    for directory in folders:
        if not _directory(directory, uid):
            complete = False
            break
    store = folders[-1]
    if complete:
        entries = list(store.iterdir())
        for path in entries:
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or info.st_uid != uid or not stat.S_ISREG(info.st_mode):
                raise RuntimeError('Unsafe existing keyring entry: ' + str(path))
        if entries:
            return dict(state='RETAINED', reason='Existing keyring data retained; its password was not changed')
    if not os.environ.get('DBUS_SESSION_BUS_ADDRESS'):
        raise RuntimeError('The normal user D-Bus session is required for keyring initialization')
    if os.environ.get('XDG_DATA_HOME', str(home / '.local/share')) != str(home / '.local/share'):
        raise RuntimeError('Custom XDG_DATA_HOME requires manual keyring initialization')
    for directory in folders:
        _directory(directory, uid, create=True)
    collection = _create_default()
    created = list(store.glob('*.keyring'))
    if len(created) != 1:
        raise RuntimeError('New keyring file could not be uniquely identified; existing data was retained')
    login = created[0]
    info = login.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_mode & 0o077:
        raise RuntimeError('Unsafe newly created login keyring')
    with login.open('rb') as stream:
        if not stream.read(32).startswith(b'[keyring]\n'):
            raise RuntimeError('Empty-password keyring format was not confirmed; no existing password was changed')
    return dict(state='INITIALIZED', reason='New login keyring initialized with an empty password',
                default_collection=collection, locked=False)


def main():
    import argparse
    import json
    import runtime
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', action='store_true')
    options = parser.parse_args()
    try:
        result = ensure_empty(runtime.settings())
    except Exception as error:
        result = dict(state='ERROR', error=str(error))
    print(json.dumps(result) if options.json else result.get('reason', result.get('error')))
    return 1 if result['state'] == 'ERROR' else 0


if __name__ == '__main__':
    raise SystemExit(main())
