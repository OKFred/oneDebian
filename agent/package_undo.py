#!/usr/bin/env python3
"""Record owned APT additions and remove only an explicitly checked package plan."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import types

OWNER = 'oneDebian-agent-v1'
NAME = re.compile(r'[a-z0-9][a-z0-9+.-]*(?::[a-z0-9][a-z0-9-]*)?\Z')
FIELDS = '${Package}\t${Architecture}\t${Version}\t${db:Status-Status}\t${Essential}\t${Priority}\n'


def _read(path, limit=16 * 1024**2):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022 or metadata.st_size > limit:
        raise RuntimeError('Untrusted package undo file: ' + str(path))
    return path.read_text()


def _context(i, create=False):
    path = i.STATE
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise RuntimeError('Package undo state contains a symlink')
    if not path.exists():
        if not create:
            return False
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_uid != 0 or path.stat().st_mode & 0o022:
        raise RuntimeError('Package undo state must be root-owned and non-writable')
    marker = path / '.owner'
    if marker.exists():
        if _read(marker).strip() != i.OWNER:
            raise RuntimeError('Package undo ownership differs')
    elif any(path.iterdir()):
        raise RuntimeError('Existing unowned package undo directory')
    elif create:
        i.atomic(marker, i.OWNER, 0o600)
    else:
        raise RuntimeError('Package undo ownership marker is missing')
    return True


def _capture(i, args):
    return i.run(args, capture_output=True, text=True, env=dict(os.environ, LC_ALL='C', LANG='C')).stdout.strip()


def _packages(text):
    result = {}
    for line in text.splitlines():
        fields = line.split('\t')
        if len(fields) != 6:
            raise RuntimeError('Invalid dpkg package inventory')
        name, arch, version, status_name, essential, priority = fields
        key = name + ':' + arch
        if not NAME.fullmatch(key) or not version or any(x in version for x in '\r\n\t '):
            raise RuntimeError('Invalid package identity')
        result[key] = dict(version=version, status=status_name, essential=essential == 'yes', priority=priority)
    return result


def snapshot(i):
    return dict(packages=_packages(_capture(i, ['dpkg-query', '-W', '-f=' + FIELDS])),
                manual=sorted(_capture(i, ['apt-mark', 'showmanual']).splitlines()),
                held=sorted(_capture(i, ['apt-mark', 'showhold']).splitlines()),
                architecture=_capture(i, ['dpkg', '--print-architecture']))


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def _save(i, value):
    i.write_json(i.STATE / 'package-undo.json', value, 0o600)


def _load(i):
    value = json.loads(_read(i.STATE / 'package-undo.json'))
    if value.get('owner') != i.OWNER or value.get('schema') != 1:
        raise RuntimeError('Unrecognized package undo record')
    return value


def actions(text):
    """APT v3 includes architectures; v1/v2 are deliberately not guessed."""
    current = None
    for line in text.splitlines():
        if line.startswith('VERSION '):
            if line != 'VERSION 3':
                raise RuntimeError('Package undo requires APT hook protocol 3')
            current = 'configuration'
            continue
        if current == 'configuration':
            if not line:
                current = 'actions'
            continue
        if current != 'actions':
            if line:
                raise RuntimeError('APT hook protocol header is missing')
            continue
        if not line:
            continue
        fields = line.split(maxsplit=8)
        if len(fields) != 9:
            raise RuntimeError('Invalid APT package action')
        name, old, old_arch, _, direction, new, new_arch, _, action = fields
        arch = old_arch if action == '**REMOVE**' else new_arch
        key = name + ':' + arch
        if not NAME.fullmatch(key) or direction not in ('<', '>', '='):
            raise RuntimeError('Invalid APT package action identity')
        yield dict(name=key, old=old, new=new, action=action)
    if current is None:
        raise RuntimeError('APT hook protocol header is missing')


def _record_actions(record, text):
    for action in actions(text):
        key = action['name']
        if not action['action'].startswith('/'):
            continue
        if action['old'] == '-' and key not in record['before']['packages']:
            record['added'].setdefault(key, action['new'])
        elif key in record['added'] and record['added'][key] == action['old']:
            record['added'][key] = action['new']


def prepare(i):
    _context(i, create=True)
    target = i.STATE / 'package-undo.json'
    if target.exists() or target.is_symlink():
        record = _load(i)
    else:
        bootstrap = i.STATE / 'package-undo-baseline.tsv'
        fresh = i.STATE / 'package-undo-reset'
        legacy = not fresh.exists() and ((i.STATE / 'package-undo-legacy').exists() or any((i.STATE / name).exists() for name in ('state.json', 'installed.json', 'user-owned', 'files.json')))
        if fresh.exists():
            _read(fresh)
        if bootstrap.exists():
            before = dict(packages=_packages(_read(bootstrap)),
                          manual=sorted(_read(i.STATE / 'package-undo-manual.before').splitlines()),
                          held=sorted(_read(i.STATE / 'package-undo-held.before').splitlines()),
                          architecture=_read(i.STATE / 'package-undo-architecture.before').strip())
            legacy = False
        else:
            before = snapshot(i)
        record = dict(schema=1, owner=i.OWNER, generation=os.urandom(16).hex(), baseline_complete=not legacy, before=before,
                      added={}, requested=[], manual_after=None)
    raw = i.STATE / 'package-undo-bootstrap-actions.log'
    if raw.exists():
        _record_actions(record, _read(raw))
        record['requested'] = sorted(set(record['requested']) | {'python3', 'ca-certificates'})
    _save(i, record)
    # Keep the transaction guard available after the owned application scripts are removed.
    source = Path(__file__).resolve()
    for name, contents, mode in (
        ('package_undo.py', source.read_text(), 0o600),
        ('package-undo-hook.sh', (source.parent / 'package-undo-hook.sh').read_text(), 0o700),
    ):
        destination = i.STATE / name
        if destination.is_symlink():
            raise RuntimeError('Package undo helper is a symlink')
        if destination.resolve() != (source.parent / name).resolve():
            i.atomic(destination, contents, mode)
    return record


def reset(i):
    """Called only after the caller has verified its completed-cleanup receipt."""
    _context(i)
    pending = i.STATE / 'package-undo-reset-pending'
    ledger = i.STATE / 'package-undo.json'
    fresh = i.STATE / 'package-undo-reset'
    if pending.exists() or pending.is_symlink():
        generation = _read(pending).strip()
        if ledger.exists() and _load(i).get('generation') != generation:
            raise RuntimeError('Package undo reset generation changed')
    elif ledger.exists():
        generation = _load(i).get('generation', os.urandom(16).hex())
    elif fresh.exists():
        _read(fresh)
        return
    else:
        generation = os.urandom(16).hex()
    if not re.fullmatch(r'[a-f0-9]{32}', generation):
        raise RuntimeError('Invalid package undo generation')
    archive = i.STATE / 'package-undo-history'
    if archive.is_symlink():
        raise RuntimeError('Package undo archive is a symlink')
    archive.mkdir(mode=0o700, exist_ok=True)
    if not stat.S_ISDIR(archive.stat().st_mode) or archive.stat().st_uid != 0 or archive.stat().st_mode & 0o077:
        raise RuntimeError('Untrusted package undo archive')
    target = archive / generation
    if target.is_symlink():
        raise RuntimeError('Package undo generation archive is a symlink')
    target.mkdir(mode=0o700, exist_ok=True)
    if not stat.S_ISDIR(target.stat().st_mode) or target.stat().st_uid != 0 or target.stat().st_mode & 0o077:
        raise RuntimeError('Untrusted package undo generation archive')
    i.atomic(pending, generation + '\n', 0o600)
    for name in ('package-undo.json', 'package-undo-baseline.tsv', 'package-undo-manual.before',
                 'package-undo-held.before', 'package-undo-architecture.before', 'package-undo-legacy',
                 'package-undo-bootstrap-actions.log', 'package-undo-approved.json'):
        path = i.STATE / name
        if path.exists() or path.is_symlink():
            _read(path)
            if (target / name).exists() or (target / name).is_symlink():
                raise RuntimeError('Package undo archive entry already exists: ' + name)
            path.rename(target / name)
    i.atomic(fresh, generation + '\n', 0o600)
    pending.unlink()


def install_args(i, argv):
    record = prepare(i)
    record['requested'] = sorted(set(record['requested']) | {name for name in i.PACKAGES if name in argv})
    _save(i, record)
    hook = str(i.STATE / 'package-undo-hook.sh')
    return [argv[0], '-o', 'DPkg::Pre-Install-Pkgs::=' + shlex.quote(hook) + ' record',
            '-o', 'DPkg::Tools::Options::' + hook + '::Version=3',
            '-o', 'DPkg::Post-Invoke::=' + shlex.quote(hook) + ' finish', *argv[1:]]


def finish(i):
    record = prepare(i)
    record['manual_after'] = snapshot(i)['manual']
    _save(i, record)


def _canonical(name, current):
    if name in current['packages']:
        return name
    native = name + ':' + current['architecture']
    if native in current['packages']:
        return native
    found = [key for key in current['packages'] if key.split(':')[0] == name]
    if len(found) != 1:
        raise RuntimeError('Ambiguous APT package name: ' + name)
    return found[0]


def _removal_command(names, simulate=False):
    return ['apt-get', *(['--simulate'] if simulate else ['-y']),
            '-o', 'APT::Get::AutomaticRemove=false', '-o', 'APT::Get::Purge=false', 'remove', *names]


def plan(i):
    if not _context(i) or not (i.STATE / 'package-undo.json').exists():
        return dict(remove=[], restore_auto=[], retained=[], blocked=[], baseline_complete=False,
                    warning='No package baseline; existing APT packages are retained', snapshot_hash=None)
    record = _load(i)
    current = snapshot(i)
    remove = []
    retained = []
    for name, version in sorted(record['added'].items()):
        pkg = current['packages'].get(name)
        if pkg is None or pkg['status'] == 'not-installed':
            continue
        if pkg['status'] == 'config-files':
            retained.append(dict(name=name, reason='configuration files retained'))
            continue
        reason = ('present before installation' if name in record['before']['packages'] else
                  'version changed since installation' if pkg['version'] != version else
                  'essential or required system package' if pkg['essential'] or pkg['priority'] == 'required' else
                  'held package' if name in current['held'] or name.split(':')[0] in current['held'] else '')
        if reason:
            retained.append(dict(name=name, reason=reason))
        else:
            remove.append(name)
    blocked = []
    if remove:
        output = _capture(i, _removal_command(remove, simulate=True))
        seen = set()
        for line in output.splitlines():
            if line.startswith(('Inst ', 'Conf ')):
                blocked.append(line)
            elif line.startswith(('Remv ', 'Purg ')):
                name = _canonical(line.split()[1], current)
                seen.add(name)
                if name not in remove:
                    blocked.append('Removal of an unowned dependent: ' + name)
        if seen != set(remove):
            blocked.append('APT removal actions differ from the explicit package list')
    restore = []
    for name, pkg in record['before']['packages'].items():
        base = name.split(':')[0]
        if ((name in record['requested'] or base in record['requested'])
                and name not in record['before']['manual'] and base not in record['before']['manual']
                and (name in current['manual'] or base in current['manual'])
                and current['packages'].get(name, {}).get('version') == pkg['version']):
            if record['manual_after'] == current['manual']:
                restore.append(name)
            else:
                retained.append(dict(name=name, reason='Package install flags changed; automatic flag restoration requires review'))
    return dict(remove=remove, restore_auto=sorted(restore), retained=retained, blocked=blocked,
                generation=record.get('generation'),
                baseline_complete=record['baseline_complete'], snapshot_hash=_digest(current),
                versions={name:current['packages'][name]['version'] for name in remove},
                warning='' if record['baseline_complete'] else 'Legacy packages without recorded ownership are retained',
                configuration_files_retained=True)


def guard(i, approved, text):
    if _digest(snapshot(i)) != approved['snapshot_hash']:
        raise RuntimeError('Package inventory changed after the cleanup preview')
    seen = set()
    for action in actions(text):
        name = action['name']
        if (action['action'] != '**REMOVE**' or name not in approved['remove']
                or action['old'] != approved['versions'][name] or action['new'] != '-'):
            raise RuntimeError('APT attempted an unapproved package action: ' + name)
        seen.add(name)
    if seen != set(approved['remove']):
        raise RuntimeError('APT did not provide the complete approved removal plan')


def apply(i, approved_plan):
    current = plan(i)
    if current != approved_plan or current['blocked']:
        raise RuntimeError('Package cleanup plan changed or is blocked; preview it again')
    if not (i.STATE / 'package-undo.json').exists():
        return dict(removed=[], restored_auto=[], unrestored_auto=[], retained=[], warnings=[], baseline_complete=False, configuration_files_retained=True)
    if current['remove']:
        i.write_json(i.STATE / 'package-undo-approved.json', current, 0o600)
        hook = str(i.STATE / 'package-undo-hook.sh')
        argv = _removal_command(current['remove'])
        argv[1:1] = ['-o', 'DPkg::Pre-Install-Pkgs::=' + shlex.quote(hook) + ' guard',
                     '-o', 'DPkg::Tools::Options::' + hook + '::Version=3']
        i.run(argv, env=dict(os.environ, DEBIAN_FRONTEND='noninteractive', LC_ALL='C', LANG='C'))
    # Removal does not discard conffiles; data edited after installation remains available.
    after = snapshot(i)
    expected_manual = set(_load(i)['manual_after'] or []) - {name for key in current['remove'] for name in (key, key.split(':')[0])}
    restored = []
    if set(after['manual']) == expected_manual and current['restore_auto']:
        i.run(['apt-mark', 'auto', *current['restore_auto']])
        verified_manual = set(snapshot(i)['manual'])
        restored = [name for name in current['restore_auto'] if name not in verified_manual and name.split(':')[0] not in verified_manual]
    unrestored = [name for name in current['restore_auto'] if name not in restored]
    retained = current['retained'] + [dict(name=name, reason='Original automatic package flag was not restored') for name in unrestored]
    warnings = ['Some original automatic package flags were retained; review the listed packages'] if unrestored else []
    return dict(removed=current['remove'], restored_auto=restored, unrestored_auto=unrestored, retained=retained, warnings=warnings,
                baseline_complete=current['baseline_complete'], configuration_files_retained=True)


def _main():
    # The protected shell hook uses a fixed state path, never a user-supplied destination.
    if os.geteuid() != 0:
        raise RuntimeError('Package undo requires root')
    def atomic(path, text, mode=0o600):
        if path.is_symlink():
            raise RuntimeError('Package undo target is a symlink')
        temporary = path.with_name(path.name + '.new-' + os.urandom(6).hex())
        try:
            with temporary.open('x') as output:
                os.fchmod(output.fileno(), mode)
                output.write(text)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    i = types.SimpleNamespace(STATE=Path('/var/lib/onedebian-agent'), OWNER=OWNER, PACKAGES=[], atomic=atomic,
                              write_json=lambda path,value,mode=0o600: atomic(path,json.dumps(value)+'\n',mode),
                              run=lambda argv,**kwargs: subprocess.run([str(x) for x in argv],check=True,**kwargs))
    record = prepare(i)
    mode = sys.argv[1] if len(sys.argv) == 2 else ''
    if mode == 'record':
        _record_actions(record, sys.stdin.read(16 * 1024**2 + 1))
        _save(i, record)
    elif mode == 'finish':
        finish(i)
    elif mode == 'guard':
        approved = json.loads(_read(i.STATE / 'package-undo-approved.json'))
        guard(i, approved, sys.stdin.read(16 * 1024**2 + 1))
    else:
        raise RuntimeError('Unknown package undo hook mode')


if __name__ == '__main__':
    try:
        _main()
    except Exception as error:
        print('oneDebian package undo: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
