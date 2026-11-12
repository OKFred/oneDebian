#!/usr/bin/env python3
"""Root-only, fixed-unit starter used by the ordinary Agent browser launcher."""
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import sys

ROOT = Path(__file__).absolute().parent
UNIT = 'onedebian-agent-chromium.service'
DESKTOP = 'onedebian-agent-desktop.service'
UNIT_PATH = Path('/etc/systemd/system') / UNIT


def trusted_path(path, directory=False):
    metadata = path.lstat()
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected_type(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise RuntimeError('Untrusted root-owned browser resource: ' + str(path))


def load_installer():
    # -I omits the script directory; check the fixed imports before adding it.
    trusted_path(ROOT, directory=True)
    cache = ROOT / '__pycache__'
    if cache.exists() or cache.is_symlink(): trusted_path(cache, directory=True)
    for name in ('install', 'runtime', 'cleanup', 'package_undo'):
        source = ROOT / (name + '.py')
        trusted_path(source)
        bytecode = Path(importlib.util.cache_from_source(str(source)))
        if bytecode.exists() or bytecode.is_symlink(): trusted_path(bytecode)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import install
    return install


def service_state(installer, unit):
    properties = ('LoadState', 'ActiveState', 'MainPID', 'FragmentPath', 'DropInPaths')
    command = ['systemctl', 'show', unit]
    for name in properties: command.extend(('-p', name))
    fields = dict(line.split('=', 1) for line in installer.capture(command, timeout=5).splitlines() if '=' in line)
    if fields.get('LoadState') != 'loaded' or not fields.get('MainPID', '').isdecimal():
        raise RuntimeError('Browser or desktop service state could not be verified')
    fields['MainPID'] = int(fields['MainPID'])
    return fields


def start_browser(installer):
    installer.require_root()
    installer.cleanup._trusted(installer)
    with installer.operation_lock():
        installer.cleanup._trusted(installer)
        for directory, filename in ((installer.ETC, 'config.json'), (installer.STATE, 'installed.json'),
                                    (installer.STATE, 'state.json'), (installer.STATE, 'files.json')):
            trusted_path(directory / filename)
        if installer.active(): raise RuntimeError('Agent installation is active; wait before opening the browser')
        if (installer.read_json(installer.STATE / 'installed.json', {}).get('owner') != installer.OWNER
                or installer.read_json(installer.STATE / 'state.json', {}).get('state') not in ('READY_GPU', 'READY_SOFTWARE')):
            raise RuntimeError('Agent installation is incomplete or uninstalled; use the installation menu')
        config = installer.read_json(installer.ETC / 'config.json', {})
        account = installer.pwd.getpwnam('agent')
        if (config.get('user') != 'agent' or config.get('home') != '/home/agent'
                or account.pw_name != 'agent' or account.pw_uid <= 0 or account.pw_dir != '/home/agent'):
            raise RuntimeError('Unexpected Agent account or browser configuration')
        trusted_path(UNIT_PATH)
        manifest = installer.read_json(installer.STATE / 'files.json', {})
        if manifest.get(str(UNIT_PATH)) != hashlib.sha256(UNIT_PATH.read_bytes()).hexdigest():
            raise RuntimeError('Chromium service is modified or unowned; ask root to review it')
        browser = service_state(installer, UNIT)
        if browser.get('FragmentPath') != str(UNIT_PATH) or browser.get('DropInPaths'):
            raise RuntimeError('Chromium service override detected; ask root to review its fragment and drop-ins')
        if browser['ActiveState'] in ('active', 'activating', 'reloading'):
            return False
        if browser['ActiveState'] not in ('inactive', 'failed') or browser['MainPID'] != 0:
            raise RuntimeError('Chromium service is stopping or inconsistent; no start was attempted')
        desktop = service_state(installer, DESKTOP)
        if desktop['ActiveState'] != 'active' or desktop['MainPID'] <= 0:
            raise RuntimeError('Agent desktop is not running; use the workstation menu to restore it')
        installer.run(['systemctl', 'start', UNIT], timeout=30)
        return True


def main():
    try:
        if len(sys.argv) != 1: raise RuntimeError('This fixed browser starter does not accept arguments')
        if os.geteuid() != 0: raise RuntimeError('This fixed browser starter requires root via the Agent launcher')
        start_browser(load_installer())
        return 0
    except Exception as error:
        print('无法启动 Agent 工作浏览器：' + str(error), file=sys.stderr)
        print('请由 root 排查：systemctl status ' + UNIT + '; journalctl -u ' + UNIT + ' -n 60 --no-pager', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
