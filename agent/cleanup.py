"""Recorded inverse of Agent installation; user data and unknown files are retained."""
import base64
import contextlib
import hashlib
import json
import os
from pathlib import Path
import stat

BASE = Path('/')
LEDGER = 'cleanup-before.json'
LIMIT = 1024 * 1024
SHELL_PREFIX = b'# oneDebian Agent fnm\nexport FNM_DIR="$HOME/.local/share/fnm"\nexport PATH="$HOME/.local/bin:$FNM_DIR:$PATH"\n'
SHELL_SUFFIX = b'\nif [[ $- == *i* ]]; then eval "$("$FNM_DIR/fnm" env --use-on-cd --shell bash)"; fi\n'


def _home():
    return BASE / 'home/agent'


def _parents(path):
    for part in [*path.parents, path]:
        if part.is_symlink():
            raise RuntimeError('Symlink requires manual review: ' + str(part))


def _trusted(i):
    for directory in (i.ROOT, i.ETC, i.STATE):
        _parents(directory)
        s = directory.stat()
        marker = directory / '.owner'
        if s.st_uid != 0 or s.st_mode & 0o022 or not marker.is_file() or marker.is_symlink() or marker.stat().st_uid != 0 or marker.stat().st_mode & 0o022 or marker.read_text() != i.OWNER:
            raise RuntimeError('Unowned cleanup directory: ' + str(directory))


def _read(i):
    path = i.STATE / LEDGER
    if not path.exists():
        return None
    _parents(path)
    s = path.stat()
    if s.st_uid != 0 or s.st_mode & 0o077 or s.st_size > 64 * LIMIT:
        raise RuntimeError('Cleanup ledger is not a private root-owned file')
    data = json.loads(path.read_text())
    if data.get('owner') != i.OWNER or data.get('schema') != 1:
        raise RuntimeError('Unknown cleanup ledger')
    return data


def _fingerprint(path, content=False):
    _parents(path.parent)
    try:
        s = path.lstat()
    except FileNotFoundError:
        return None
    result = dict(mode=stat.S_IMODE(s.st_mode), uid=s.st_uid, gid=s.st_gid)
    if stat.S_ISLNK(s.st_mode):
        return dict(result, kind='link', target=os.readlink(path))
    if stat.S_ISDIR(s.st_mode):
        return dict(result, kind='directory')
    if not stat.S_ISREG(s.st_mode):
        return dict(result, kind='unsupported')
    digest = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    contents = []
    with os.fdopen(descriptor, 'rb') as source:
        opened = os.fstat(source.fileno())
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (s.st_dev, s.st_ino):
            raise RuntimeError('File changed during cleanup inspection: ' + str(path))
        if content and opened.st_size > LIMIT:
            raise RuntimeError('Configuration is too large to back up: ' + str(path))
        total = 0
        for chunk in iter(lambda: source.read(512 * 1024), b''):
            total += len(chunk)
            if content and total > LIMIT:
                raise RuntimeError('Configuration grew during cleanup inspection: ' + str(path))
            digest.update(chunk)
            if content:
                contents.append(chunk)
    result.update(kind='file', sha256=digest.hexdigest())
    if content:
        result['content'] = base64.b64encode(b''.join(contents)).decode('ascii')
    return result


@contextlib.contextmanager
def _user_scope(i, path):
    if not path.is_relative_to(_home()):
        yield
        return
    _parents(path.parent)
    try:
        account = i.pwd.getpwnam('agent')
    except KeyError:
        if _home().exists():
            raise RuntimeError('An existing Agent home without an account requires review')
        yield
        return
    if account.pw_uid == 0 or Path(account.pw_dir) != _home():
        raise RuntimeError('Unexpected Agent account')
    with i.user_files(account) if os.geteuid() != account.pw_uid else contextlib.nullcontext():
        yield


def _token(value):
    return {key: item for key, item in value.items() if key != 'content'} if value else None


def _files(i):
    home = _home()
    result = [BASE / 'etc/wsl.conf', BASE / 'etc/apt/sources.list',
              BASE / 'etc/apt/sources.list.d/debian.sources',
              BASE / 'etc/apt/sources.list.d/onedebian-security.list',
              home / '.bashrc', home / '.codex/config.toml']
    result += [home / '.local/bin' / name for name in ('node', 'npm', 'npx', 'pnpm', 'codex')]
    result += [i.ETC / name for name in ('config.json', 'versions.json', 'node-version')]
    result += [i.STATE / 'downloads' / asset for asset, digest in getattr(i, 'FNM', {}).values()]
    source_dir = BASE / 'etc/apt/sources.list.d'
    if source_dir.exists():
        _parents(source_dir)
        result += list(source_dir.glob('*.list')) + list(source_dir.glob('*.sources'))
    return sorted(set(result))


def _trees():
    return [_home() / '.local/share/fnm', _home() / '.local/share/onedebian-agent/tools']


def _account(i):
    try:
        account = i.pwd.getpwnam('agent')
    except KeyError:
        return dict(uid=None, groups=[], linger=False)
    if account.pw_uid == 0 or Path(account.pw_dir) != _home():
        raise RuntimeError('Unexpected Agent account')
    try:
        groups = i.capture(['id', '-nG', 'agent']).split()
    except Exception:
        groups = None
    linger = BASE / 'var/lib/systemd/linger/agent'
    _parents(linger)
    return dict(uid=account.pw_uid, groups=groups, linger=linger.exists())


def _inventory(path):
    value = _fingerprint(path)
    if not value:
        return {}
    if value['kind'] != 'directory':
        raise RuntimeError('Runtime tree is not a directory: ' + str(path))
    result = {str(path): value}
    for directory, names, files in os.walk(path, followlinks=False):
        for name in names + files:
            target = Path(directory) / name
            result[str(target)] = _fingerprint(target, content=target.is_relative_to(path / 'aliases'))
            if len(result) > 200000:
                raise RuntimeError('Runtime tree exceeds the cleanup inventory limit')
    return result


def observe(i, paths=None):
    """Capture before a writing stage, so later user edits cannot be adopted."""
    targets = list(paths) if paths is not None else _files(i) + _trees()
    result = {}
    for path in targets:
        path = Path(path)
        with _user_scope(i, path):
            result[str(path)] = (_inventory(path) if path in _trees() else
                                _fingerprint(path, content=not path.is_relative_to(i.STATE / 'downloads')))
    result['__account__'] = _account(i)
    return result


def prepare(i):
    i.require_root()
    if (i.STATE / LEDGER).exists():
        _trusted(i)
        existing = _read(i)
        if not existing.get('applied'):
            return existing
        raise RuntimeError('The completed cleanup baseline must be reset before a new installation')
    else:
        existing = None
    reset_marker = i.STATE / 'cleanup-reset'
    fresh = False
    if reset_marker.exists():
        _parents(reset_marker)
        s = reset_marker.stat()
        if s.st_uid != 0 or s.st_mode & 0o077 or reset_marker.read_text() != i.OWNER:
            raise RuntimeError('Untrusted fresh cleanup baseline marker')
        fresh = True
    legacy = (any((i.STATE / name).exists() for name in ('state.json', 'files.json', 'user-owned')) or (i.ETC / 'config.json').exists()) and existing is None and not fresh
    i.owned_directories()
    _trusted(i)
    before = observe(i) if not legacy else {}
    data = dict(owner=i.OWNER, schema=1, legacy=legacy, before=before, after={}, conflicts={}, applied=False,
                account_before=_account(i) if not legacy else None, account_after=None,
                owned_groups=[], owned_linger=False)
    if not legacy:
        _import_bootstrap(i, data)
    i.write_json(i.STATE / LEDGER, data, 0o600)
    if fresh:
        reset_marker.unlink()
    return data


def _import_bootstrap(i, data):
    directory = i.STATE / 'cleanup-bootstrap-sources'
    if not (directory / 'sealed').exists():
        return
    _parents(directory)
    s = directory.stat()
    if s.st_uid != 0 or s.st_mode & 0o077:
        raise RuntimeError('Untrusted bootstrap source backup directory')
    for path in directory.iterdir():
        _parents(path)
        m = path.stat()
        if not stat.S_ISREG(m.st_mode) or m.st_uid != 0 or m.st_mode & 0o077 or m.st_size > LIMIT:
            raise RuntimeError('Untrusted bootstrap source backup')
    if (directory / '.owner').read_text() != i.OWNER:
        raise RuntimeError('Bootstrap source backup ownership differs')
    for record in directory.glob('*.path'):
        name = record.read_text().rstrip('\n')
        path = Path(name)
        source_dir = BASE / 'etc/apt/sources.list.d'
        allowed = path == BASE / 'etc/apt/sources.list' or (path.parent == source_dir and path.suffix in ('.list', '.sources'))
        key = hashlib.sha256(name.encode()).hexdigest()
        if not allowed or '\n' in name or record.name != key + '.path':
            raise RuntimeError('Out-of-scope bootstrap source backup')
        def metadata(part):
            text = (directory / (key + '.' + part + '.meta')).read_text().strip()
            if text == 'missing':
                return None
            fields = text.split()
            if len(fields) != (4 if part == 'after' else 3):
                raise RuntimeError('Malformed bootstrap source metadata')
            mode, uid, gid = fields[-3:]
            if not mode.isdigit() or not uid.isdigit() or not gid.isdigit():
                raise RuntimeError('Malformed bootstrap source permissions')
            value = dict(kind='file', mode=int(mode, 8), uid=int(uid), gid=int(gid))
            if part == 'before':
                content = (directory / (key + '.before')).read_bytes()
                value.update(content=base64.b64encode(content).decode('ascii'), sha256=hashlib.sha256(content).hexdigest())
            else:
                if len(fields[0]) != 64 or any(c not in '0123456789abcdef' for c in fields[0]):
                    raise RuntimeError('Malformed bootstrap source digest')
                value['sha256'] = fields[0]
            return value
        data['before'][name] = metadata('before')
        data['after'][name] = metadata('after')


def record(i, paths=None, observed=None):
    data = _read(i)
    if not data or data['legacy']:
        return
    targets = list(paths) if paths is not None else [Path(p) for p in data['before'] if p != '__account__']
    current = observe(i, targets)
    for name, value in current.items():
        if name == '__account__':
            continue
        before = (observed or data['before']).get(name)
        owned = data['after'].get(name)
        if Path(name) in _trees():
            original = data['before'].get(name, {})
            owned = owned or {}
            if observed is None and owned:
                continue
            old = before or {}
            for path, token in value.items():
                expected = owned.get(path, original.get(path))
                if _token(old.get(path)) == _token(expected) and _token(token) != _token(original.get(path)):
                    owned[path] = token
            data['after'][name] = owned
        elif (_token(before) == _token(owned) if owned is not None else _token(before) == _token(data['before'].get(name))):
            if _token(value) != _token(data['before'].get(name)):
                if Path(name) == _home() / '.codex/config.toml':
                    if data['before'].get(name) is not None or not value or value.get('kind') != 'file':
                        continue
                    port = i.read_json(i.ETC / 'config.json', {}).get('mcp_port', 18931)
                    expected = f'[mcp_servers.vm_browser]\nurl = "http://127.0.0.1:{port}/mcp"\nstartup_timeout_sec = 30\ntool_timeout_sec = 120\ndisabled_tools = ["browser_close"]\n'.encode()
                    if base64.b64decode(value['content']) != expected:
                        continue
                if Path(name) == _home() / '.bashrc' and _token(value) != _token(before):
                    new_account = observed is not None and observed['__account__']['uid'] is None and current['__account__']['uid'] is not None
                    original = base64.b64decode(before['content']) if before and before.get('kind') == 'file' else b''
                    if not new_account and (not value or value.get('kind') != 'file' or base64.b64decode(value['content']) != SHELL_PREFIX + original + SHELL_SUFFIX):
                        data.setdefault('conflicts', {})[name] = 'Concurrent shell changes were not adopted; review the Agent fnm block manually'
                        continue
                data['after'][name] = value
    if observed is not None:
        previous = observed['__account__']
        after = current['__account__']
        data['account_after'] = after
        if previous['groups'] is not None and after['groups'] is not None:
            added = (set(after['groups']) - set(previous['groups'])) & {'render', 'video'}
            data['owned_groups'] = sorted(set(data['owned_groups']) | added)
        data['owned_linger'] = data['owned_linger'] or (not previous['linger'] and after['linger'])
    i.write_json(i.STATE / LEDGER, data, 0o600)


@contextlib.contextmanager
def tracking(i, paths=None):
    before = observe(i, paths)
    try:
        yield
    finally:
        record(i, paths, observed=before)


def validate_reset(i):
    """Validate the completion receipt before either cleanup journal is reset."""
    receipt = i.STATE / 'cleanup-completed.json'
    if not receipt.exists():
        return None
    _trusted(i)
    if i.active():
        raise RuntimeError('Cannot reset cleanup records during installation')
    _parents(receipt)
    metadata = receipt.stat()
    if metadata.st_uid != 0 or metadata.st_mode & 0o077 or metadata.st_size > 4096:
        raise RuntimeError('Untrusted cleanup completion receipt')
    complete = json.loads(receipt.read_text())
    ledger = _read(i)
    marker = i.STATE / 'cleanup-reset'
    resumable = False
    if marker.exists():
        _parents(marker)
        m = marker.stat()
        resumable = m.st_uid == 0 and not m.st_mode & 0o077 and marker.read_text() == i.OWNER
    if complete.get('owner') != i.OWNER or complete.get('state') not in ('CLEANED', 'CLEANED_PARTIAL') or not ((ledger and ledger.get('applied')) or (ledger is None and resumable)):
        raise RuntimeError('Cleanup was not recorded complete; baseline was retained')
    return complete


def reset(i):
    """Start a new baseline only after a recorded cleanup, never during Resume."""
    if not validate_reset(i):
        return
    evidence = [i.STATE / name for name in ('installed.json', 'gpu.json')]
    for path in evidence:
        _parents(path)
        if path.exists():
            info = path.stat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                raise RuntimeError('Untrusted installation evidence: ' + str(path))
    marker = i.STATE / 'cleanup-reset'
    if not marker.exists():
        with marker.open('x') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(i.OWNER)
    generation = os.urandom(8).hex()
    if (i.STATE / LEDGER).exists():
        archive = i.STATE / ('cleanup-history-' + generation + '.json')
        os.replace(i.STATE / LEDGER, archive)
    for path in evidence:
        if path.exists():
            os.replace(path, i.STATE / ('cleanup-history-' + generation + '-' + path.name))
    (i.STATE / 'cleanup-completed.json').unlink()


def _allowed(i, path):
    if not path.is_absolute() or '..' in path.parts or path != Path(os.path.normpath(path)):
        return False
    if path.is_relative_to(i.ROOT) or path.is_relative_to(i.ETC):
        return True
    home = _home()
    if path in _files(i) or any(path.is_relative_to(tree) for tree in _trees()):
        return True
    units = [BASE / 'etc/systemd/system' / ('onedebian-agent-' + part + '.service')
             for part in ('desktop', 'chromium', 'install', 'ssh')]
    units += [BASE / 'etc/systemd/user' / ('onedebian-agent-' + part + '.service') for part in ('mcp', 'novnc')]
    launchers = [home / base / ('agent-' + part + '.desktop')
                 for base, part in [('Desktop', 'takeover'), ('Desktop', 'resume'), ('Desktop', 'browser'), ('.config/autostart', 'controls')]]
    guards = [BASE / 'etc/systemd/system' / name / '90-onedebian-agent.conf' for name in ('ssh.service.d', 'ssh.socket.d')]
    return path in units + launchers + guards


def _bashrc_restore(before, after, current):
    if not before or not after or not current or any(x.get('kind') != 'file' for x in (before, after, current)):
        return None
    original = base64.b64decode(before['content'])
    generated = base64.b64decode(after['content'])
    value = base64.b64decode(current['content'])
    prefix, suffix = SHELL_PREFIX, SHELL_SUFFIX
    if prefix in original or suffix in original or generated != prefix + original + suffix:
        return None
    if value.count(prefix) != 1 or value.count(suffix) != 1:
        return None
    return value.replace(prefix, b'', 1).replace(suffix, b'', 1)


def _package_plan(i):
    import package_undo
    return package_undo.plan(i)


def _merge_package_result(plan, result):
    result = result or {}
    for key in ('warnings', 'warning'):
        warnings = result.get(key, [])
        for warning in [warnings] if isinstance(warnings, str) else warnings:
            if warning not in plan['warnings']:
                plan['warnings'].append(warning)
    for entry in result.get('retained', []):
        if entry.get('reason') == 'configuration files retained':
            target, value = 'preserve', 'package configuration: ' + entry['name']
        else:
            target, value = 'retained', dict(path='package:' + entry['name'], reason=entry['reason'])
        if value not in plan[target]:
            plan[target].append(value)


def cleanup_plan(i):
    i.require_root()
    _trusted(i)
    data = _read(i)
    plan = dict(state='CLEANUP_PLAN', active=i.active(), remove_files=[], restore_files=[],
                retained=[], warnings=[], blockers=[], user_units=[], system_units=[], account_changes={}, preserve=[str(i.ROOT)] + [str(_home() / p) for p in (
                    'workspaces', '.codex/auth.json', '.local/share/keyrings', '.local/share/onedebian-agent/profile')])
    if plan['active']:
        plan['blockers'].append('Installation is active; wait for it to finish before cleanup')
        plan['packages'] = dict(remove=[], restore_auto=[], retained=[], blocked=[])
        plan['plan_id'] = hashlib.sha256(json.dumps(plan, sort_keys=True).encode()).hexdigest()
        return plan
    try:
        account = i.pwd.getpwnam('agent')
    except KeyError:
        account = None
    if account is None and (_home().exists() or _home().is_symlink()):
        plan['blockers'].append('Agent account is missing while its home remains; review user resources before cleanup')
        plan['packages'] = dict(remove=[], restore_auto=[], retained=[], blocked=[])
        plan['plan_id'] = hashlib.sha256(json.dumps(plan, sort_keys=True).encode()).hexdigest()
        return plan
    if not data or data.get('legacy'):
        plan['warnings'].append('No original installation baseline; unknown runtime, packages and settings are retained')
    changes = {}
    if data and not data.get('legacy'):
        plan['retained'] += [dict(path=name, reason=reason) for name, reason in data.get('conflicts', {}).items()]
        for name, after in data['after'].items():
            if Path(name) in _trees():
                original = data['before'].get(name, {})
                changes.update({path: (original.get(path), token) for path, token in after.items()})
            else:
                changes[name] = (data['before'].get(name), after)
    manifest = i.read_json(i.STATE / 'files.json', {})
    for name, digest in manifest.items():
        path = Path(name)
        if not _allowed(i, path):
            plan['retained'].append(dict(path=name, reason='Outside the fixed Agent cleanup scope'))
            continue
        if path.is_relative_to(i.ROOT):
            continue
        with _user_scope(i, path):
            current = _fingerprint(path)
        if name not in changes and current and current.get('kind') == 'file' and current.get('sha256') == digest:
            changes[name] = (None, current)
        elif name not in changes and current:
            plan['retained'].append(dict(path=name, reason='Managed file changed after installation'))
    for name, (before, after) in sorted(changes.items()):
        path = Path(name)
        if not _allowed(i, path):
            raise RuntimeError('Cleanup ledger contains an out-of-scope path: ' + name)
        with _user_scope(i, path):
            current = _fingerprint(path, content=path == _home() / '.bashrc')
        if current is None:
            continue
        if before is not None and _token(current) == _token(before):
            continue
        if _token(current) != _token(after):
            restored = _bashrc_restore(before, after, current) if path == _home() / '.bashrc' else None
            if restored is not None:
                plan['restore_files'].append(dict(path=name, expected=_token(current), content=base64.b64encode(restored).decode('ascii'), mode=current['mode'], uid=current['uid'], gid=current['gid']))
            else:
                plan['retained'].append(dict(path=name, reason='Changed since installation'))
            continue
        if before is None:
            plan['remove_files'].append(dict(path=name, expected=_token(current)))
        elif before.get('kind') == 'file' and 'content' in before:
            if path.is_relative_to(_home()) and before['uid'] != current['uid']:
                plan['retained'].append(dict(path=name, reason='Original home file owner differs; privileged restoration refused'))
                continue
            plan['restore_files'].append(dict(path=name, expected=_token(current), content=before['content'], mode=before['mode'], uid=before['uid'], gid=before['gid']))
        elif before.get('kind') == 'link':
            plan['restore_files'].append(dict(path=name, expected=_token(current), target=before['target'], mode=before['mode']))
        else:
            plan['retained'].append(dict(path=name, reason='Original non-file requires manual restoration'))
    for part in ('desktop', 'chromium', 'install', 'ssh', 'mcp', 'novnc'):
        user = part in ('mcp', 'novnc')
        path = BASE / ('etc/systemd/user' if user else 'etc/systemd/system') / ('onedebian-agent-' + part + '.service')
        current = _fingerprint(path)
        if current:
            if current.get('kind') != 'file' or current.get('sha256') != manifest.get(str(path)) or current['uid'] != 0 or current['mode'] & 0o022:
                plan['blockers'].append('Modified or unowned service must be reviewed: ' + str(path))
            elif part != 'install':
                plan['user_units' if user else 'system_units'].append(path.name)
    if account is None and plan['user_units']:
        plan['blockers'].append('Agent account is missing while user services remain; review user resources before cleanup')
    if data and not data['legacy']:
        original = data.get('account_before')
        after = data.get('account_after')
        current = _account(i)
        if after and current['uid'] != after['uid']:
            plan['blockers'].append('Agent UID changed since installation')
        elif original and after:
            if original['groups'] is not None and after['groups'] is not None and current['groups'] is not None:
                plan['account_changes']['remove_groups'] = sorted(set(data.get('owned_groups', [])) & set(current['groups']))
            elif data.get('owned_groups'):
                plan['retained'].append(dict(path='groups:agent', reason='Group membership could not be verified'))
            if data.get('owned_linger') and not original['linger'] and after['linger'] and current['linger']:
                account = i.pwd.getpwnam('agent')
                enabled = i.user_ctl(account, 'list-unit-files', '--state=enabled', '--no-legend', '--no-pager', capture_output=True, text=True).stdout
                foreign = [line.split()[0] for line in enabled.splitlines() if line.split() and not line.split()[0].startswith('onedebian-agent-')]
                if foreign:
                    plan['retained'].append(dict(path='linger:agent', reason='Other enabled user units: ' + ', '.join(foreign)))
                else:
                    plan['account_changes']['disable_linger'] = True
    plan['packages'] = _package_plan(i)
    if not any(name.split(':')[0] == 'openssh-server' for name in plan['packages'].get('remove', [])):
        guards = {str(BASE / 'etc/systemd/system' / name / '90-onedebian-agent.conf') for name in ('ssh.service.d', 'ssh.socket.d')}
        kept = [entry for entry in plan['remove_files'] if entry['path'] in guards]
        plan['remove_files'] = [entry for entry in plan['remove_files'] if entry['path'] not in guards]
        plan['retained'] += [dict(path=entry['path'], reason='Global SSH guard retained because SSH package removal was not approved') for entry in kept]
    plan['blockers'] += plan['packages'].get('blockers', plan['packages'].get('blocked', []))
    _merge_package_result(plan, plan['packages'])
    canonical = json.dumps(plan, sort_keys=True, separators=(',', ':')).encode()
    plan['plan_id'] = hashlib.sha256(canonical).hexdigest()
    # Backups may contain local environment secrets; never expose them in a preview.
    for entry in plan['restore_files']:
        if 'content' in entry:
            entry['content_sha256'] = hashlib.sha256(base64.b64decode(entry.pop('content'))).hexdigest()
    return plan


def cleanup_apply(i, plan_id):
    import package_undo
    import fcntl
    i.require_root()
    _trusted(i)
    initial = cleanup_plan(i)
    if initial.get('plan_id') != plan_id:
        raise RuntimeError('Cleanup plan changed; preview and confirm it again')
    if initial['blockers']:
        raise RuntimeError('; '.join(initial['blockers']))
    with (i.STATE / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        plan = cleanup_plan(i)
        if plan.get('plan_id') != plan_id:
            raise RuntimeError('Cleanup plan changed; preview and confirm it again')
        if plan['blockers']:
            raise RuntimeError('; '.join(plan['blockers']))
        try:
            account = i.pwd.getpwnam('agent')
        except KeyError:
            account = None
        if account is not None and (account.pw_uid == 0 or Path(account.pw_dir) != _home()):
            raise RuntimeError('Unexpected Agent account')
        if account is None and (plan['user_units'] or _home().exists() or _home().is_symlink()
                                or any(Path(entry['path']).is_relative_to(_home())
                                       for entry in plan['restore_files'] + plan['remove_files'])):
            raise RuntimeError('Agent account is missing while user resources remain; preview cleanup again')
        i.phase('CLEANING')
        for unit in plan['user_units']:
            i.user_ctl(account, 'disable', '--now', unit)
        for unit in sorted(plan['system_units'], key=lambda name: 'chromium' not in name):
            i.run(['systemctl', 'disable', '--now', unit])
        data = _read(i)
        for entry in plan['restore_files']:
            path = Path(entry['path'])
            with i.user_files(account) if path.is_relative_to(_home()) else contextlib.nullcontext():
                current = _fingerprint(path, content=True)
                if _token(current) != entry['expected']:
                    raise RuntimeError('File changed during cleanup: ' + str(path))
                tree = next((name for name in data['after'] if Path(name) in _trees() and path.is_relative_to(Path(name))), None)
                before = data['before'][tree][str(path)] if tree else data['before'][str(path)]
                after = data['after'][tree][str(path)] if tree else data['after'][str(path)]
                if before.get('kind') == 'link':
                    _parents(path.parent)
                    path.unlink()
                    path.symlink_to(before['target'])
                    continue
                content = (_bashrc_restore(before, after, current) if _token(current) != _token(after)
                           else base64.b64decode(before['content']))
                if content is None or hashlib.sha256(content).hexdigest() != entry['content_sha256']:
                    raise RuntimeError('Restore content changed: ' + str(path))
                temporary = path.with_name(path.name + '.cleanup-' + os.urandom(6).hex())
                try:
                    with temporary.open('xb') as stream:
                        os.fchmod(stream.fileno(), entry['mode'])
                        stream.write(content)
                    _parents(path.parent)
                    os.replace(temporary, path)
                    if not path.is_relative_to(_home()):
                        os.chown(path, entry['uid'], entry['gid'], follow_symlinks=False)
                finally:
                    temporary.unlink(missing_ok=True)
        for entry in sorted(plan['remove_files'], key=lambda x: len(Path(x['path']).parts), reverse=True):
            path = Path(entry['path'])
            with i.user_files(account) if path.is_relative_to(_home()) else contextlib.nullcontext():
                current = _fingerprint(path)
                if current is None:
                    continue
                if _token(current) != entry['expected']:
                    raise RuntimeError('File changed during cleanup: ' + str(path))
                if current['kind'] == 'directory':
                    try:
                        path.rmdir()
                    except OSError:
                        plan['retained'].append(dict(path=str(path), reason='Runtime directory contains retained files'))
                else:
                    path.unlink()
        i.run(['systemctl', 'daemon-reload'])
        if account is not None:
            i.user_ctl(account, 'daemon-reload')
            for group in plan['account_changes'].get('remove_groups', []):
                i.run(['gpasswd', '-d', 'agent', group])
            if plan['account_changes'].get('disable_linger'):
                i.run(['loginctl', 'disable-linger', 'agent'])
        _merge_package_result(plan, package_undo.apply(i, plan['packages']))
        if not data:
            data = dict(owner=i.OWNER, schema=1, legacy=True, before={}, after={}, applied=False)
        data['applied'] = True
        i.write_json(i.STATE / LEDGER, data, 0o600)
        state = 'CLEANED_PARTIAL' if plan['retained'] or plan['warnings'] else 'CLEANED'
        i.write_json(i.STATE / 'cleanup-completed.json', dict(owner=i.OWNER, state=state,
                     receipt_id=os.urandom(16).hex()), 0o600)
        i.phase(state)
        return dict(state=state, retained=plan['retained'], warnings=plan['warnings'], data_retained=True,
                    note='WSL, account, projects, browser profile, keyring and Codex login remain; installer records retained for recovery')
