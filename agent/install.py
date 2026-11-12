#!/usr/bin/env python3
"""Owned, resumable Debian 13 workstation installation, independent of PVE."""
import argparse
import configparser
import contextlib
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import time
import traceback
import urllib.request
import zipfile

ROOT = Path('/opt/onedebian-agent')
ETC = Path('/etc/onedebian-agent')
STATE = Path('/var/lib/onedebian-agent')
JOB = 'onedebian-agent-install.service'
OWNER = 'oneDebian-agent-v1'
SOURCE = Path(__file__).resolve().parent
GPU_PROBE = Path('/run/onedebian-agent-gpu')
sys.path.insert(0, str(SOURCE))
import cleanup
import package_undo
import runtime
VERSIONS = dict(node='v26.13.0', fnm='v1.39.0', mcp='0.0.83', codex='0.166.0', pnpm='12.18.0')
FNM = {
    'amd64': ('fnm-linux.zip', '7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224'),
    'arm64': ('fnm-arm64.zip', '4eaff58b2c5bf30d0934027572dd0b5bbb60d2a1af309230b53662d4b1d45599'),
}
PACKAGES = '''ca-certificates curl unzip git openssh-client python3 python3-gi gir1.2-gtk-3.0 libglib2.0-bin
dbus-user-session dbus-x11 libpam-systemd iproute2 procps util-linux xauth x11-utils x11-xserver-utils
xfce4-session xfce4-panel xfdesktop4 xfwm4 xfce4-settings xfce4-terminal thunar
chromium chromium-sandbox gnome-keyring libpam-gnome-keyring libsecret-tools tigervnc-standalone-server
tigervnc-tools novnc websockify mesa-utils libegl1 libegl-mesa0 libgl1-mesa-dri libgles2 libgbm1
libatomic1 gcr fonts-noto-cjk ibus ibus-libpinyin ibus-gtk ibus-gtk3 ibus-gtk4 im-config zenity nano'''.split()


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def capture(args):
    return run(args, capture_output=True, text=True).stdout.strip()


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def atomic(path, text, mode=0o644):
    if path.is_symlink():
        raise RuntimeError(f'Refusing symlink: {path}')
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.new-' + secrets.token_hex(6))
    try:
        with temporary.open('x') as f:
            os.chmod(temporary, mode)
            f.write(text)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def write_json(path, data, mode=0o644):
    atomic(path, json.dumps(data, ensure_ascii=False, indent=2) + '\n', mode)


def require_root():
    if os.geteuid() != 0:
        raise RuntimeError('Run this operation as root/sudo.')


def require_debian():
    values = dict(line.split('=', 1) for line in Path('/etc/os-release').read_text().splitlines() if '=' in line)
    if values.get('ID', '').strip('"') != 'debian' or values.get('VERSION_ID', '').strip('"') != '13':
        raise RuntimeError('Only Debian 13 is supported.')


def active(unit=JOB):
    try:
        fields = dict(line.split('=', 1) for line in capture(['systemctl', 'show', unit, '-p', 'ActiveState', '-p', 'Job']).splitlines() if '=' in line)
        queued = re.match(r'([1-9][0-9]*)\b', fields.get('Job', ''))
        return fields.get('ActiveState') in ('active', 'activating', 'reloading') or bool(queued)
    except subprocess.CalledProcessError:
        return False


def boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def status():
    data = read_json(STATE / 'state.json', dict(state='NOT_INSTALLED', phase=''))
    data['job_active'] = active()
    if data['state'] in ('PRECHECK', 'PACKAGES', 'RUNTIME', 'SERVICES', 'VERIFY') and not data['job_active']:
        data['state'] = 'INTERRUPTED'
    logfile = STATE / 'install.log'
    if logfile.exists():
        # Bound memory even when APT has logged for hours.
        with logfile.open('rb') as f:
            f.seek(max(0, logfile.stat().st_size - 4096))
            data['tail'] = f.read().decode('utf-8', 'replace').splitlines()[-8:]
    data['log'] = str(logfile)
    data['config'] = read_json(ETC / 'config.json', {})
    data['versions'] = read_json(ETC / 'versions.json', {})
    if data['versions']:
        data['first_use'] = 'Windows Codex 可直接使用本机转发的 MCP，无需 Linux Codex 授权；已有加密 keyring 仍需自行解锁。'
    return data


def phase(name, error=None):
    data = read_json(STATE / 'state.json', {})
    data.update(state=name, phase=name, error=error, boot_id=boot_id(), updated_at=int(time.time()))
    write_json(STATE / 'state.json', data)
    print(f'【Agent】{name}' + (f': {error}' if error else ''), file=sys.stderr, flush=True)


def owned_directories():
    for path in (ROOT, ETC, STATE):
        if path.is_symlink():
            raise RuntimeError(f'Refusing symlink: {path}')
        if path.exists() and any(path.iterdir()) and not (path / '.owner').exists():
            raise RuntimeError(f'Existing unowned directory: {path}')
        path.mkdir(parents=True, exist_ok=True)
        marker = path / '.owner'
        if marker.exists() and marker.read_text() != OWNER:
            raise RuntimeError(f'Owner mismatch: {path}')
        atomic(marker, OWNER)


def prepare_changes():
    """Capture before the first change, retaining the original baseline across Resume."""
    owned_directories()
    installer = sys.modules[__name__]
    if (STATE / 'cleanup-completed.json').exists():
        cleanup.validate_reset(installer)
        package_undo.reset(installer)
        cleanup.reset(installer)
    package_undo.prepare(installer)
    cleanup.prepare(installer)
    return installer


def user_record(adopt=False):
    try:
        user = pwd.getpwnam('agent')
        if not (STATE / 'user-owned').exists() and not adopt:
            raise RuntimeError('Existing agent account is not owned by oneDebian. Explicit --adopt-user required; its password/profile will be retained.')
    except KeyError:
        run(['useradd', '--create-home', '--shell', '/bin/bash', 'agent'])
        user = pwd.getpwnam('agent')
        atomic(STATE / 'user-created', 'agent\n')
    if user.pw_uid == 0 or user.pw_dir != '/home/agent':
        raise RuntimeError('agent must be an ordinary user with home /home/agent.')
    atomic(STATE / 'user-owned', 'agent\n')
    return user


def environment(user):
    return dict(os.environ, HOME=user.pw_dir, USER=user.pw_name, LOGNAME=user.pw_name,
                XDG_RUNTIME_DIR=f'/run/user/{user.pw_uid}',
                DBUS_SESSION_BUS_ADDRESS=f'unix:path=/run/user/{user.pw_uid}/bus')


def as_user(user, args, **kwargs):
    return run(['runuser', '-u', user.pw_name, '--', *args], env=environment(user), **kwargs)


@contextlib.contextmanager
def user_files(user):
    # A compromised adopted account must never turn a home symlink into a root write.
    old_uid, old_gid, old_groups = os.geteuid(), os.getegid(), os.getgroups()
    try:
        os.setgroups(os.getgrouplist(user.pw_name, user.pw_gid))
        os.setegid(user.pw_gid)
        os.seteuid(user.pw_uid)
        yield
    finally:
        os.seteuid(old_uid)
        os.setegid(old_gid)
        os.setgroups(old_groups)


def user_ctl(user, *args, **kwargs):
    return as_user(user, ['systemctl', '--user', *args], **kwargs)


def port_free(port):
    with socket.socket() as s:
        try:
            s.bind(('127.0.0.1', port))
            return True
        except OSError:
            return False


def config_for(options):
    try:
        used = set(re.findall(r'@?/tmp/\.X11-unix/X([0-9]+)(?:\s|$)', Path('/proc/net/unix').read_text()))
    except FileNotFoundError:
        used = set()
    display = next((f':{n}' for n in range(10, 1000) if str(n) not in used), None)
    if display is None: raise RuntimeError('No unused private X display number is available')
    return dict(user='agent', home='/home/agent', display=display, viewer_port=options.viewer_port,
                mcp_port=options.mcp_port, cdp_port=options.cdp_port, render_node='', gpu_backend='software', keyring_mode='empty')


def plan(options):
    require_debian()
    config = read_json(ETC / 'config.json', config_for(options))
    cpu = os.cpu_count() or 0
    memory = int(next(x.split()[1] for x in Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemTotal:'))) * 1024
    free = shutil.disk_usage('/home' if Path('/home').exists() else '/').free
    warnings = []
    if cpu < 4: warnings.append('CPU: fewer than 4 logical CPUs')
    if memory < 7.5 * 1024**3: warnings.append('Memory: less than recommended 8 GiB (WSL shared pool)')
    if free < 32 * 1024**3: warnings.append('Disk: less than 32 GiB free')
    return dict(state='PLAN', config=config, cpu=cpu, memory_gib=round(memory / 1024**3, 1),
                free_gib=round(free / 1024**3, 1), warnings=warnings,
                systemd=Path('/proc/1/comm').read_text().strip() == 'systemd',
                mirror=options.mirror, versions=VERSIONS,
                gpu_nodes=[str(p) for p in sorted(Path('/dev/dri').glob('renderD*'))],
                dxg_only=Path('/dev/dxg').exists() and not Path('/dev/dri').exists(),
                host_driver_changes=False, full_upgrade=False)


def set_wsl_config(options):
    require_root()
    require_debian()
    owned_directories()
    with operation_lock():
        installer = prepare_changes()
        with cleanup.tracking(installer):
            return configure_wsl(options)


def configure_wsl(options):
    user_record(options.adopt_user)
    save_payload()
    path = Path('/etc/wsl.conf')
    if path.is_symlink():
        raise RuntimeError('Refusing symlink /etc/wsl.conf')
    parser = configparser.ConfigParser(interpolation=None, strict=True)
    parser.optionxform = str
    original = path.read_text() if path.exists() else ''
    parser.read_string(original)
    changes = dict(boot=dict(systemd='true'))
    if options.new_instance or options.harden_wsl:
        changes.update(user=dict(default='agent'), automount=dict(enabled='false'),
                       interop=dict(enabled='false', appendWindowsPath='false'))
    for section, values in changes.items():
        if not parser.has_section(section): parser.add_section(section)
        for key, value in values.items(): parser.set(section, key, value)
    import io
    output = io.StringIO()
    parser.write(output)
    if not (STATE / 'wsl.conf.before').exists(): atomic(STATE / 'wsl.conf.before', original)
    atomic(path, output.getvalue())
    return dict(state='WAIT_RESTART', user='agent', restart_target_only=True)


def save_payload():
    manifest = read_json(STATE / 'files.json', {})
    sources = list(SOURCE.rglob('*'))
    for src in sources:
        if not src.is_file() or '__pycache__' in src.parts or src.suffix == '.pyc' or src.name == '.owner': continue
        relative = src.relative_to(SOURCE)
        dest = ROOT / relative
        content = src.read_text(encoding='utf-8').replace('\r\n', '\n')
        if dest.exists() and str(dest) in manifest and hashlib.sha256(dest.read_bytes()).hexdigest() != manifest[str(dest)]:
            raise RuntimeError(f'Modified owned payload requires review: {dest}')
        atomic(dest, content, 0o755 if src.suffix == '.sh' else 0o644)
        manifest[str(dest)] = hashlib.sha256(dest.read_bytes()).hexdigest()
    wrapper = SOURCE.parent / 'agent.sh'
    if not wrapper.exists(): wrapper = ROOT / 'agent.sh'
    if wrapper.exists():
        atomic(ROOT / 'agent.sh', wrapper.read_text().replace('\r\n', '\n'), 0o755)
        manifest[str(ROOT / 'agent.sh')] = hashlib.sha256((ROOT / 'agent.sh').read_bytes()).hexdigest()
    for name in ('the_repo_localization.sh', 'the_os_release.sh'):
        helper = SOURCE.parent / 'components' / name
        if helper.exists():
            dest = ROOT / 'components' / name
            atomic(dest, helper.read_text().replace('\r\n', '\n'))
            manifest[str(dest)] = hashlib.sha256(dest.read_bytes()).hexdigest()
    write_json(STATE / 'files.json', manifest)


def owned_file(path, content, mode=0o644, user=None):
    manifest = read_json(STATE / 'files.json', {})
    if path.exists():
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if str(path) not in manifest or manifest[str(path)] != digest:
            raise RuntimeError(f'Existing/modified unowned file: {path}')
    if user:
        with user_files(user): atomic(path, content, mode)
    else:
        atomic(path, content, mode)
    manifest[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    write_json(STATE / 'files.json', manifest)


def packages(options):
    if options.mirror != 'keep':
        helper = ROOT / 'components' / 'the_repo_localization.sh'
        if not helper.exists(): raise RuntimeError('Missing shared APT source helper')
        run(['bash', '-c', 'source "$1"; the_localize_apt_sources Debian trixie /etc/apt "$2"', '--', helper, options.mirror])
    env = dict(os.environ, DEBIAN_FRONTEND='noninteractive', APT_LISTCHANGES_FRONTEND='none')
    run(['apt-get', '-o', 'APT::Update::Error-Mode=any', 'update'], env=env)
    installer = sys.modules[__name__]
    package_undo.prepare(installer)
    command = ['apt-get', 'install', '-y', '--no-install-recommends', '-o', 'Dpkg::Options::=--force-confdef',
               '-o', 'Dpkg::Options::=--force-confold', *PACKAGES]
    try:
        run(package_undo.install_args(installer, command), env=env)
    finally:
        package_undo.finish(installer)


def install_runtime(user):
    home = Path(user.pw_dir)
    fnm_dir = home / '.local/share/fnm'
    data = home / '.local/share/onedebian-agent'
    with user_files(user):
        for directory in (fnm_dir, data, home / 'workspaces'):
            directory.mkdir(parents=True, exist_ok=True)
    arch = capture(['dpkg', '--print-architecture'])
    if arch not in FNM: raise RuntimeError(f'Unsupported fnm architecture: {arch}')
    asset, digest = FNM[arch]
    cache = STATE / 'downloads'
    cache.mkdir(exist_ok=True)
    archive = cache / asset
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        url = f'https://github.com/Schniz/fnm/releases/download/{VERSIONS["fnm"]}/{asset}'
        run(['curl', '--fail', '--location', '--retry', '3', '--connect-timeout', '20', '--max-time', '600', '-o', archive, url])
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError('fnm SHA256 mismatch; nothing extracted')
    with zipfile.ZipFile(archive) as z:
        binary = z.read('fnm')
    target = fnm_dir / 'fnm'
    with user_files(user):
        if target.is_symlink(): raise RuntimeError('Refusing fnm symlink')
        if target.exists() and target.read_bytes() != binary:
            raise RuntimeError('An existing fnm binary differs from the pinned release; review it before replacing it')
        if not target.exists():
            target.write_bytes(binary)
            target.chmod(0o755)
    fnm = [str(target), '--fnm-dir', str(fnm_dir)]
    as_user(user, [*fnm, 'install', VERSIONS['node']])
    as_user(user, [*fnm, 'default', VERSIONS['node']])
    version = as_user(user, [*fnm, 'exec', '--using=' + VERSIONS['node'], 'node', '--version'], capture_output=True, text=True).stdout.strip()
    if version != VERSIONS['node']: raise RuntimeError(f'Unexpected Node runtime: {version}')
    as_user(user, [*fnm, 'exec', '--using=' + version, 'npm', 'install', '--global', 'pnpm@' + VERSIONS['pnpm']])
    pnpm = as_user(user, [*fnm, 'exec', '--using=' + version, 'pnpm', '--version'], capture_output=True, text=True).stdout.strip()
    if pnpm != VERSIONS['pnpm']: raise RuntimeError('Unexpected global pnpm version: ' + pnpm)
    tools = data / 'tools'
    as_user(user, [*fnm, 'exec', '--using=' + version, 'npm', 'install', '--prefix', str(tools),
                   '--save-exact', '@playwright/mcp@' + VERSIONS['mcp'], '@openai/codex@' + VERSIONS['codex']])
    write_json(ETC / 'versions.json', dict(VERSIONS, node=version))
    atomic(ETC / 'node-version', version + '\n')
    shell = home / '.bashrc'
    with user_files(user): content = shell.read_text() if shell.exists() else ''
    marker = '# oneDebian Agent fnm'
    if marker not in content:
        with user_files(user):
            prefix = marker + '\nexport FNM_DIR="$HOME/.local/share/fnm"\nexport PATH="$HOME/.local/bin:$FNM_DIR:$PATH"\n'
            atomic(shell, prefix + content + '\nif [[ $- == *i* ]]; then eval "$("$FNM_DIR/fnm" env --use-on-cd --shell bash)"; fi\n')
    for name in ('node', 'npm', 'npx', 'pnpm', 'codex'):
        binary = name
        command = ['node', str(tools / 'node_modules/@openai/codex/bin/codex.js')] if name == 'codex' else [binary]
        import shlex
        body = '#!/bin/sh\nexec ' + ' '.join(shlex.quote(x) for x in [*fnm, 'exec', '--using=' + str(ETC / 'node-version'), *command]) + ' "$@"\n'
        dest = home / '.local/bin' / name
        with user_files(user):
            if dest.is_symlink() or (dest.exists() and dest.read_text() != body):
                raise RuntimeError(f'Existing runtime wrapper requires review: {dest}')
            if not dest.exists(): atomic(dest, body, 0o755)
    config_file = home / '.codex/config.toml'
    if not config_file.exists():
        port = read_json(ETC / 'config.json')['mcp_port']
        with user_files(user):
            atomic(config_file, f'[mcp_servers.vm_browser]\nurl = "http://127.0.0.1:{port}/mcp"\nstartup_timeout_sec = 30\ntool_timeout_sec = 120\ndisabled_tools = ["browser_close"]\n', 0o600)
    else:
        print('Existing Codex configuration retained; merge vm_browser settings from the guide if necessary.', flush=True)


def unit_environment(user):
    return f'User={user.pw_name}\nEnvironment=HOME={user.pw_dir}\nEnvironment=XDG_RUNTIME_DIR=/run/user/{user.pw_uid}\nEnvironment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{user.pw_uid}/bus\n'


def services(user):
    run(['loginctl', 'enable-linger', user.pw_name])
    run(['systemctl', 'start', f'user@{user.pw_uid}.service'])
    runtime = f'/usr/bin/python3 {ROOT}/runtime.py'
    for name, relationship in (
        ('desktop', ''),
        ('chromium', 'After=onedebian-agent-desktop.service\nRequires=onedebian-agent-desktop.service\nJoinsNamespaceOf=onedebian-agent-desktop.service\nPartOf=onedebian-agent-desktop.service\n'),
    ):
        content = '[Unit]\nDescription=oneDebian Agent ' + name + '\nAfter=systemd-logind.service user@' + str(user.pw_uid) + '.service\nRequires=user@' + str(user.pw_uid) + '.service\n' + relationship
        content += '\n[Service]\n' + unit_environment(user) + f'ExecStart={runtime} {name}\nPrivateTmp=yes\nRestart=on-failure\nRestartSec=3\nTimeoutStopSec=30\n\n[Install]\nWantedBy=multi-user.target\n'
        owned_file(Path('/etc/systemd/system') / f'onedebian-agent-{name}.service', content)
    for name in ('mcp', 'novnc'):
        condition = f'ExecCondition={runtime} mcp-permitted\n' if name == 'mcp' else ''
        content = f'[Unit]\nDescription=oneDebian Agent {name}\n\n[Service]\n{condition}ExecStart={runtime} {name}\nRestart=on-failure\nRestartSec=5\nTimeoutStopSec=10\n\n[Install]\nWantedBy=default.target\n'
        owned_file(Path('/etc/systemd/user') / f'onedebian-agent-{name}.service', content)
    desktop_dir = Path(user.pw_dir) / 'Desktop'
    autostart = Path(user.pw_dir) / '.config/autostart'
    for src in (ROOT / 'desktop').glob('*.desktop'):
        dest = (autostart if 'control' in src.name else desktop_dir) / src.name
        owned_file(dest, src.read_text(), 0o755, user=user)
    for folder in (desktop_dir, autostart, autostart.parent):
        with user_files(user): folder.mkdir(parents=True, exist_ok=True)
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', 'onedebian-agent-desktop.service', 'onedebian-agent-chromium.service'])
    user_ctl(user, 'daemon-reload')
    user_ctl(user, 'enable', 'onedebian-agent-mcp.service', 'onedebian-agent-novnc.service')


def start_desktop():
    run(['systemctl', 'restart', 'onedebian-agent-desktop.service'])
    run(['systemctl', 'start', 'onedebian-agent-chromium.service'])


def gpu_access(user, node):
    metadata = node.lstat()
    if not stat.S_ISCHR(metadata.st_mode) or os.major(metadata.st_rdev) != 226:
        raise RuntimeError('Not a DRM character device: ' + str(node))
    with user_files(user):
        if os.access(node, os.R_OK | os.W_OK, effective_ids=True): return
    import grp
    group = grp.getgrgid(metadata.st_gid).gr_name
    if metadata.st_gid == 0 or group not in ('render', 'video'):
        raise RuntimeError('Device access needs manual review; refusing privileged or unrelated group: ' + group)
    if metadata.st_gid in os.getgrouplist(user.pw_name, user.pw_gid):
        raise RuntimeError('Existing GPU group is insufficient; review the device ACL manually')
    run(['usermod', '-aG', group, user.pw_name])
    with user_files(user):
        accessible = os.access(node, os.R_OK | os.W_OK, effective_ids=True)
    if not accessible:
        run(['gpasswd', '-d', user.pw_name, group])
        raise RuntimeError('Selected DRM device is not accessible after the group grant')
    return group


def d3d12_available():
    return Path('/dev/dxg').is_char_device() and all(Path('/usr/lib/wsl/lib', name).is_file() for name in ('libd3d12.so', 'libdxcore.so'))


def verify_gpu(config, user):
    # First installation only: production profile has not been launched yet.
    candidates = sorted(Path('/dev/dri').glob('renderD*'))
    evidence = []
    for node in candidates:
        granted_group = None
        candidate = dict(config, gpu_backend='drm', render_node=str(node), probe_profile=str(Path(user.pw_dir) / '.local/share/onedebian-agent/probes/gpu'))
        try:
            granted_group = gpu_access(user, node)
            write_json(ETC / 'config.json', candidate)
            start_desktop()
            proof = subprocess.run(['python3', str(ROOT / 'verify.py'), '--gpu', '--json'], capture_output=True, text=True, timeout=180)
            try: data = json.loads(proof.stdout)
            except ValueError: data = dict(gpu=dict(passed=False, reason=proof.stderr[-2000:]))
        except (subprocess.SubprocessError, OSError, RuntimeError, KeyError) as exc:
            data = dict(gpu=dict(passed=False, reason=str(exc)))
            proof = None
        evidence.append(data)
        if proof is not None and proof.returncode == 0 and data.get('gpu', {}).get('passed'):
            config['render_node'] = str(node)
            config['gpu_backend'] = 'drm'
            break
        if granted_group:
            run(['systemctl', 'stop', 'onedebian-agent-chromium.service', 'onedebian-agent-desktop.service'])
            run(['gpasswd', '-d', user.pw_name, granted_group])
    if not config['render_node'] and d3d12_available():
        write_json(ETC / 'config.json', dict(config, gpu_backend='software'))
        run(['systemctl', 'restart', 'onedebian-agent-desktop.service'])
        trial = probe_graphics(config, user, 'd3d12')
        evidence.append(trial)
        if trial.get('passed') and trial.get('gpu', {}).get('passed'):
            config['gpu_backend'] = 'd3d12'
    backend = runtime.gpu_backend(config)
    write_json(STATE / 'gpu.json', dict(attempts=evidence, mode='software' if backend == 'software' else 'gpu', backend=backend,
               reason=None if backend != 'software' else 'No candidate passed native EGL and Chromium hardware shader drawing'))
    subprocess.run(['systemctl', 'stop', 'onedebian-agent-chromium.service', 'onedebian-agent-desktop.service'], check=False)
    write_json(ETC / 'config.json', config)


def probe_graphics(config, user, backend):
    """A separate browser/profile in the current desktop, never the production profile."""
    directory = GPU_PROBE
    if directory.is_symlink(): raise RuntimeError('Unsafe GPU probe directory')
    if directory.exists():
        info = directory.stat()
        if info.st_uid != 0 or info.st_mode & 0o022 or not (directory / '.owner').is_file() or (directory / '.owner').read_text() != OWNER:
            raise RuntimeError('Unowned GPU probe directory')
    directory.mkdir(mode=0o755, exist_ok=True)
    atomic(directory / '.owner', OWNER)
    unit = 'onedebian-agent-gpu-probe.service'
    state = capture(['systemctl', 'show', unit, '-p', 'LoadState', '--value'])
    if state != 'not-found': return dict(passed=False, gpu=dict(passed=False, backend=backend, reason='Existing GPU probe unit was retained; review it before retrying'))
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0)); port = listener.getsockname()[1]
    candidate = dict(config, gpu_backend=backend, cdp_port=port, probe_unit=unit,
        uid=user.pw_uid, probe_profile=str(Path(user.pw_dir) / '.local/share/onedebian-agent/probes' / ('gpu-' + secrets.token_hex(12))))
    runtime.gpu_backend(candidate)
    write_json(directory / 'config.json', candidate, 0o600)
    launcher = 'import sys\nsys.path.insert(0, ' + repr(str(ROOT)) + ')\nimport runtime\nruntime.chromium(' + repr(candidate) + ')\n'
    atomic(directory / 'launch.py', launcher)
    started = False
    try:
        run(['systemd-run', '--quiet', '--collect', '--unit=' + unit,
             '--property=User=' + user.pw_name, '--property=PrivateTmp=yes',
             '--property=JoinsNamespaceOf=onedebian-agent-desktop.service',
             '--property=Requires=onedebian-agent-desktop.service',
             '--property=After=onedebian-agent-desktop.service',
             '/usr/bin/python3', str(directory / 'launch.py')])
        started = True
        result = subprocess.run(['python3', str(ROOT / 'verify.py'), '--gpu', '--probe-config', '--json'],
                                capture_output=True, text=True, timeout=180)
        data = json.loads(result.stdout)
        if result.returncode: data['passed'] = False
        return data
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return dict(passed=False, gpu=dict(passed=False, backend=backend, reason=str(error)))
    finally:
        if started: run(['systemctl', 'stop', unit])


def change_graphics_browser(config, candidate, user, recover=False):
    if runtime.manual(config): raise RuntimeError('Manual takeover is active; the browser was retained')
    import verify
    # The repository bundle is root-private; ordinary users run the deployed helpers.
    verify.HELPERS = ROOT
    control = verify.Verifier(config, read_json(ETC / 'versions.json'))
    before = None
    try:
        control.browser_ready()
        before = sorted(hashlib.sha256(item['url'].encode()).hexdigest() for item in control.cdp('Target.getTargets')['targetInfos'] if item['type'] == 'page')
        if runtime.manual(config): raise RuntimeError('Manual takeover began; the browser was retained')
        try: control.cdp('Browser.close')
        except (OSError, RuntimeError, subprocess.SubprocessError): pass
        deadline = time.monotonic() + 10
        while Path('/proc', str(control.browser_pid)).exists() and time.monotonic() < deadline:
            time.sleep(.2)
    except (OSError, RuntimeError, subprocess.SubprocessError):
        if not recover or runtime.manual(config): raise
    if runtime.manual(config): raise RuntimeError('Manual takeover began; no further browser restart was performed')
    run(['systemctl', 'stop', 'onedebian-agent-chromium.service'])
    write_json(ETC / 'config.json', candidate)
    run(['systemctl', 'start', 'onedebian-agent-chromium.service'])
    control = verify.Verifier(candidate, read_json(ETC / 'versions.json'))
    control.browser_ready()
    deadline = time.monotonic() + 20
    while True:
        after = sorted(hashlib.sha256(item['url'].encode()).hexdigest() for item in control.cdp('Target.getTargets')['targetInfos'] if item['type'] == 'page')
        if before is None or before == after or time.monotonic() >= deadline: break
        time.sleep(.2)
    return dict(pages_before=len(before) if before is not None else None, pages_after=len(after), page_urls_preserved=before == after if before is not None else None)


def graphics_check(config, hardware):
    if hardware:
        result = subprocess.run(['python3', str(ROOT / 'verify.py'), '--gpu', '--json'], capture_output=True, text=True, timeout=180)
        data = json.loads(result.stdout)
        if result.returncode: data['passed'] = False
        return data
    import verify
    verify.HELPERS = ROOT
    control = verify.Verifier(config, read_json(ETC / 'versions.json'))
    control.browser_ready()
    renderer = control.cdp('SystemInfo.getInfo')['gpu'].get('auxAttributes', {}).get('glRenderer', '')
    if not renderer or verify.hardware_renderer(renderer): raise RuntimeError('Software fallback renderer was not confirmed')
    return dict(passed=True, gpu=dict(backend='software', renderer=renderer))


def configure_graphics(options):
    require_root(); require_debian()
    if not options.yes: raise RuntimeError('GPU adjustment requires confirmation with --yes; Chromium may restart')
    cleanup._trusted(sys.modules[__name__])
    config = read_json(ETC / 'config.json')
    if not config or config.get('user') != 'agent' or config.get('home') != '/home/agent': raise RuntimeError('An installed Agent workstation is required')
    user = pwd.getpwnam('agent')
    if user.pw_uid == 0 or user.pw_dir != config['home']: raise RuntimeError('Unexpected Agent account')
    if runtime.manual(config): raise RuntimeError('Manual takeover is active; hand the browser back before GPU adjustment')
    with operation_lock():
        current_state = status()['state']
        previous_gpu = read_json(STATE / 'gpu.json', {})
        retry = (current_state == 'ERROR' and read_json(STATE / 'installed.json', {}).get('owner') == OWNER
                 and previous_gpu.get('operation') == 'graphics' and previous_gpu.get('result_state') == 'ERROR')
        if active() or not (current_state.startswith('READY_') or retry): raise RuntimeError('Finish the current installation or cleanup before GPU adjustment')
        installer = prepare_changes()
        with cleanup_output('gpu.log') as logfile, cleanup.tracking(installer):
            save_payload()
            backend = 'd3d12' if d3d12_available() else runtime.gpu_backend(config)
            trial = probe_graphics(config, user, backend) if backend != 'software' else dict(passed=False, gpu=dict(reason='No DXG device or previously selected DRM backend'))
            proven = trial.get('passed') and trial.get('gpu', {}).get('passed')
            candidate = dict(config, gpu_backend=backend if proven else 'software', render_node=config.get('render_node', '') if proven and backend == 'drm' else '')
            reason = trial.get('gpu', {}).get('reason', 'Hardware verification failed')
            if runtime.manual(config): raise RuntimeError('Manual takeover began during the probe; production browser was retained')
            mcp = user_ctl(user, 'show', 'onedebian-agent-mcp.service', '-p', 'ActiveState', '--value', capture_output=True, text=True).stdout.strip() == 'active'
            preservation = {}; actual = None; fallback_proof = None; tabs_lost = False
            state = 'ERROR'
            if mcp: user_ctl(user, 'stop', 'onedebian-agent-mcp.service')
            try:
                preservation = change_graphics_browser(config, candidate, user)
                if preservation.get('page_urls_preserved') is False:
                    tabs_lost = True
                    raise RuntimeError('Browser tabs did not restore; see GPU log before continuing')
                actual = graphics_check(candidate, proven)
                if not actual.get('passed'):
                    raise RuntimeError('Production verification failed: ' + actual.get('gpu', {}).get('reason', actual.get('error', 'see gpu.json')))
                if runtime.manual(config): raise RuntimeError('Manual takeover began during production verification; the browser was retained')
                state = 'READY_GPU' if proven else 'READY_SOFTWARE'
            except Exception as error:
                reason = str(error)
                print('GPU adjustment failed: ' + reason, file=sys.stderr, flush=True)
                if runtime.manual(config):
                    reason = 'Manual takeover interrupted GPU adjustment; the browser was retained: ' + reason
                else:
                    try:
                        candidate = dict(config, gpu_backend='software', render_node='')
                        preservation = change_graphics_browser(read_json(ETC / 'config.json'), candidate, user, recover=True)
                        tabs_lost = tabs_lost or preservation.get('page_urls_preserved') is False
                        fallback_proof = graphics_check(candidate, False)
                        if not fallback_proof.get('passed'): raise RuntimeError('Software fallback verification did not pass')
                        if runtime.manual(config): raise RuntimeError('Manual takeover began during software recovery; the browser was retained')
                        if tabs_lost: raise RuntimeError('Browser tabs did not restore; software recovery needs review')
                        proven = False
                        state = 'READY_SOFTWARE'
                        reason += '; verified software fallback'
                    except Exception as fallback_error:
                        reason += '; recovery incomplete: ' + str(fallback_error)
                        print(reason, file=sys.stderr, flush=True)
            finally:
                if mcp and not runtime.manual(config):
                    try: user_ctl(user, 'start', 'onedebian-agent-mcp.service')
                    except (OSError, RuntimeError, subprocess.SubprocessError) as mcp_error:
                        state = 'ERROR'
                        reason += '; MCP reconnection failed: ' + str(mcp_error)
            backend = runtime.gpu_backend(read_json(ETC / 'config.json')) if state == 'ERROR' else candidate['gpu_backend']
            record = dict(operation='graphics', result_state=state, backend=backend,
                          mode='gpu' if state == 'READY_GPU' else 'software' if state == 'READY_SOFTWARE' else 'unverified',
                          attempts=[trial], production=actual, fallback=fallback_proof, reason=reason, preservation=preservation)
            write_json(STATE / 'gpu.json', record)
            phase(state, reason if state == 'ERROR' else None)
            return dict(state=state, backend=backend, reason=reason, preservation=preservation, log=str(logfile))


def configure_keyring(options):
    require_root(); require_debian()
    if not options.yes: raise RuntimeError('Confirm --yes to initialize only a new keyring with an empty password')
    cleanup._trusted(sys.modules[__name__])
    config = read_json(ETC / 'config.json')
    if not config or config.get('user') != 'agent' or config.get('home') != '/home/agent': raise RuntimeError('An installed Agent workstation is required')
    user = pwd.getpwnam('agent')
    if user.pw_uid == 0 or user.pw_dir != config['home']: raise RuntimeError('Unexpected Agent account')
    with operation_lock():
        if active(): raise RuntimeError('Installation is still active; wait before keyring repair')
        installer = prepare_changes()
        with cleanup.tracking(installer):
            save_payload()
            try:
                result = as_user(user, ['python3', str(ROOT / 'keyring.py'), '--json'], capture_output=True, text=True, timeout=45)
            except subprocess.CalledProcessError as error:
                try: detail = json.loads(error.stdout).get('error')
                except (ValueError, TypeError): detail = error.stderr
                raise RuntimeError('Keyring initialization failed: ' + str(detail or error)) from error
            data = json.loads(result.stdout)
            if data.get('state') not in ('INITIALIZED', 'RETAINED'): raise RuntimeError(data.get('error', 'Keyring initialization did not report a verified result'))
            if data.get('state') == 'INITIALIZED':
                write_json(ETC / 'config.json', dict(config, keyring_mode='empty'))
            return data


def configure_ssh(options):
    require_root(); require_debian()
    if not options.yes: raise RuntimeError('SSH setup requires --yes and an explicit public key')
    cleanup._trusted(sys.modules[__name__])
    with operation_lock():
        if active(): raise RuntimeError('Installation is still active; wait before configuring SSH')
        installer = prepare_changes()
        with cleanup_output('ssh.log') as logfile, cleanup.tracking(installer):
            save_payload()
            import ssh_setup
            data = ssh_setup.setup(installer, options.ssh_public_key, options.ssh_port)
            data['log'] = str(logfile)
            return data


def worker(options):
    require_root()
    import fcntl
    with (STATE / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            user = user_record(options.adopt_user)
            phase('PACKAGES')
            installer = sys.modules[__name__]
            with cleanup.tracking(installer):
                packages(options)
            phase('RUNTIME')
            with cleanup.tracking(installer):
                install_runtime(user)
            phase('SERVICES')
            with cleanup.tracking(installer):
                services(user)
                config = read_json(ETC / 'config.json')
                if not read_json(STATE / 'installed.json') and not read_json(STATE / 'gpu.json'):
                    verify_gpu(config, user)
                start_desktop()
                user_ctl(user, 'start', 'onedebian-agent-novnc.service')
                if not (Path(user.pw_dir) / '.local/share/onedebian-agent/manual').exists():
                    user_ctl(user, 'start', 'onedebian-agent-mcp.service')
            phase('VERIFY')
            result = subprocess.run(['python3', str(ROOT / 'verify.py'), '--json'], capture_output=True, text=True, check=False)
            try:
                verification = json.loads(result.stdout)
            except ValueError:
                verification = dict(passed=False, error=result.stderr[-2000:])
            write_json(STATE / 'verification.json', verification)
            if result.returncode != 0 or not verification.get('passed'):
                failures = [item['name'] + ': ' + item.get('error', '') for item in verification.get('checks', []) if not item.get('passed')]
                raise RuntimeError('Verification failed: ' + '; '.join(failures or [verification.get('error', 'see verification.json')]))
            write_json(STATE / 'installed.json', dict(owner=OWNER, installed_at=int(time.time())))
            phase('READY_GPU' if runtime.gpu_backend(config) != 'software' else 'READY_SOFTWARE')
        except Exception as exc:
            phase('ERROR', str(exc))
            raise


@contextlib.contextmanager
def operation_lock(create=True):
    import fcntl
    path = STATE / 'install.lock'
    if path.is_symlink(): raise RuntimeError('Untrusted Agent operation lock')
    if not create and not path.exists():
        yield
        return
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW | (os.O_CREAT if create else 0), 0o600)
    with os.fdopen(descriptor, 'r+') as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise RuntimeError('Untrusted Agent operation lock')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another Agent installation or cleanup is running; wait before retrying') from None
        yield


def start_install(options):
    require_root()
    if active(): return status()
    if read_json(STATE / 'installed.json') and status()['state'].startswith('READY_'):
        with operation_lock(create=False):
            return status()
    report = plan(options)
    if not report['systemd']:
        raise RuntimeError('PID 1 is not systemd. Enable it and restart only this WSL instance before installation.')
    if report['warnings'] and not options.allow_low_resources:
        raise RuntimeError('; '.join(report['warnings']) + '; explicit --allow-low-resources to continue')
    current = read_json(ETC / 'config.json')
    if not current:
        ports = (options.viewer_port, options.mcp_port, options.cdp_port)
        if len(set(ports)) != 3: raise RuntimeError('Viewer, MCP and CDP ports must differ')
        for port in ports:
            if not port_free(port): raise RuntimeError(f'Port {port} is occupied; choose another port explicitly')
    owned_directories()
    with operation_lock():
        if active(): return status()
        installer = prepare_changes()
        with cleanup.tracking(installer):
            user_record(options.adopt_user)
            save_payload()
            if not current: write_json(ETC / 'config.json', config_for(options))
        phase('PRECHECK')
        state = read_json(STATE / 'state.json')
        state.update(mirror=options.mirror, allow_low_resources=options.allow_low_resources)
        write_json(STATE / 'state.json', state)
        args = [sys.executable, str(ROOT / 'install.py'), '_run', '--mirror', options.mirror]
        if options.adopt_user: args.append('--adopt-user')
        import shlex
        content = f'[Unit]\nDescription=oneDebian Agent installation\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\nType=exec\nExecStart={" ".join(shlex.quote(x) for x in args)}\nStandardOutput=append:{STATE}/install.log\nStandardError=append:{STATE}/install.log\nTimeoutStartSec=infinity\n'
        owned_file(Path('/etc/systemd/system') / JOB, content)
        run(['systemctl', 'daemon-reload'])
        if subprocess.run(['systemctl', 'is-failed', '--quiet', JOB], check=False).returncode == 0:
            run(['systemctl', 'reset-failed', JOB], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(['systemctl', 'start', '--no-block', JOB])
    return wait_install() if options.wait else status()


def wait_install():
    last = None
    while True:
        current = status()
        if current['state'] != last:
            print(f'【Agent】{current["state"]} | 日志 {current["log"]}', file=sys.stderr)
            last = current['state']
        if current['state'].startswith('READY_') or current['state'] in ('ERROR', 'INTERRUPTED'):
            return current
        time.sleep(3)


def uninstall(options):
    require_root()
    if not options.yes: raise RuntimeError('Use --yes to remove owned services; browser data/workspaces/credentials remain.')
    if active(): raise RuntimeError('Installation is active; wait for it to finish before uninstalling')
    if not (STATE / '.owner').exists() or (STATE / '.owner').read_text() != OWNER:
        raise RuntimeError('No owned installation to uninstall')
    manifest = read_json(STATE / 'files.json', {})
    def unchanged(path):
        target = Path(path)
        return not target.is_symlink() and target.is_file() and manifest.get(str(target)) == hashlib.sha256(target.read_bytes()).hexdigest()
    units = [Path('/etc/systemd/system') / f'onedebian-agent-{name}.service' for name in ('desktop', 'chromium', 'ssh')]
    units.append(Path('/etc/systemd/system') / JOB)
    units += [Path('/etc/systemd/user') / f'onedebian-agent-{name}.service' for name in ('mcp', 'novnc')]
    if any(path.exists() and not unchanged(path) for path in units):
        raise RuntimeError('A service unit is modified or unowned; review it before uninstalling. No services were stopped.')
    user = pwd.getpwnam('agent')
    for name in ('mcp', 'novnc'):
        subprocess.run(['runuser', '-u', user.pw_name, '--', 'systemctl', '--user', 'disable', '--now', f'onedebian-agent-{name}.service'], env=environment(user), check=False)
    subprocess.run(['systemctl', 'disable', '--now', 'onedebian-agent-chromium.service', 'onedebian-agent-desktop.service'], check=False)
    if units[2].exists(): subprocess.run(['systemctl', 'disable', '--now', 'onedebian-agent-ssh.service'], check=False)
    kept = []
    for path, digest in read_json(STATE / 'files.json', {}).items():
        target = Path(path)
        if path in ('/etc/systemd/system/ssh.service.d/90-onedebian-agent.conf', '/etc/systemd/system/ssh.socket.d/90-onedebian-agent.conf'):
            kept.append(path)
            continue
        if target.is_symlink() or not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            kept.append(path)
        else:
            if target.is_relative_to(Path(user.pw_dir)):
                with user_files(user): target.unlink()
            else:
                target.unlink()
    run(['systemctl', 'daemon-reload'])
    phase('UNINSTALLED')
    return dict(state='UNINSTALLED', retained_modified_files=kept, data_retained=True,
                note='User, packages, APT sources, WSL config and residency are retained; review them separately.')


def show_cleanup(data):
    print('撤销预览 / Undo' if data['state'] == 'CLEANUP_PLAN' else '撤销结果 / Result')
    for key, label in [('system_units', '系统服务 / Services'), ('user_units', '用户服务 / Services'),
                       ('remove_files', '删除文件 / Remove'), ('restore_files', '恢复设置 / Restore')]:
        values = data.get(key, [])
        print(f'{label}: {len(values)}')
        for item in values[:20]:
            print('  ' + (str(item.get('path', '')) if isinstance(item, dict) else str(item)))
        if len(values) > 20: print(f'  … {len(values)} 项，完整清单使用 --json / Details')
    packages = data.get('packages', {})
    print('删除软件包 / Packages: ' + (', '.join(packages.get('remove', [])) or '无 / None'))
    print('恢复自动安装标记 / Marks: ' + (', '.join(packages.get('restore_auto', [])) or '无 / None'))
    for key, label in [('preserve', '保留资料 / Keep'), ('retained', '保留项目 / Retained'),
                       ('warnings', '注意 / Notice'), ('blockers', '阻止清理 / Blocked')]:
        for item in data.get(key, []):
            if isinstance(item, dict): item = str(item.get('path', item.get('name', ''))) + ': ' + str(item.get('reason', ''))
            print(label + ': ' + str(item))
    for key, value in data.get('account_changes', {}).items(): print('账号设置 / Account: ' + key + ': ' + str(value))
    if 'plan_id' in data: print('plan_id: ' + data['plan_id'])
    if 'log' in data: print('日志 / Log: ' + data['log'])


@contextlib.contextmanager
def cleanup_output(name='cleanup.log'):
    """Keep subprocess output out of the JSON protocol and retain failure details."""
    path = STATE / name
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o077:
        os.close(descriptor)
        raise RuntimeError('Untrusted cleanup log')
    sys.stdout.flush(); sys.stderr.flush()
    saved = [os.dup(1), os.dup(2)]
    try:
        os.dup2(descriptor, 1); os.dup2(descriptor, 2)
        print(f'Agent {name.removesuffix(".log")} started at {int(time.time())}', file=sys.stderr, flush=True)
        yield path
    except Exception:
        traceback.print_exc()
        raise
    finally:
        sys.stdout.flush(); sys.stderr.flush()
        os.dup2(saved[0], 1); os.dup2(saved[1], 2)
        for number in [descriptor, *saved]: os.close(number)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['plan', 'prepare-undo', 'prepare-wsl', 'install', 'resume', 'status', 'verify', 'uninstall', 'cleanup-plan', 'cleanup', 'gpu', 'keyring', 'ssh', '_run'])
    parser.add_argument('--plan-id')
    parser.add_argument('--ssh-public-key', default='')
    parser.add_argument('--ssh-port', type=int, default=2222)
    parser.add_argument('--mirror', choices=['keep', 'tuna', 'ustc', 'official'], default='keep')
    for option, default in [('viewer', 16080), ('mcp', 18931), ('cdp', 19222)]:
        parser.add_argument('--' + option + '-port', type=int, default=default)
    for flag in ('json', 'wait', 'yes', 'new-instance', 'harden-wsl', 'adopt-user', 'allow-low-resources'):
        parser.add_argument('--' + flag, action='store_true')
    options, extra = parser.parse_known_args()
    if options.action == 'resume':
        previous = read_json(STATE / 'state.json', {})
        if '--mirror' not in sys.argv: options.mirror = previous.get('mirror', options.mirror)
        options.allow_low_resources = options.allow_low_resources or previous.get('allow_low_resources', False)
    if options.action != 'verify' and extra: parser.error('Unknown arguments: ' + ' '.join(extra))
    for port in (options.viewer_port, options.mcp_port, options.cdp_port, options.ssh_port):
        if not 1024 <= port <= 65535: parser.error('Ports must be between 1024 and 65535')
    try:
        if options.action == 'plan': data = plan(options)
        elif options.action == 'prepare-undo':
            require_root(); require_debian()
            if active(): raise RuntimeError('Installation is active; use Resume to observe its existing job')
            owned_directories()
            with operation_lock(): prepare_changes()
            data = dict(state='UNDO_RECORDED')
        elif options.action == 'prepare-wsl': data = set_wsl_config(options)
        elif options.action in ('install', 'resume'): data = start_install(options)
        elif options.action == 'status': data = status()
        elif options.action == 'gpu': data = configure_graphics(options)
        elif options.action == 'keyring': data = configure_keyring(options)
        elif options.action == 'ssh': data = configure_ssh(options)
        elif options.action == '_run': worker(options); return 0
        elif options.action == 'verify':
            return subprocess.call([sys.executable, str(ROOT / 'verify.py'), *( ['--json'] if options.json else []), *extra])
        elif options.action == 'cleanup-plan': data = cleanup.cleanup_plan(sys.modules[__name__])
        elif options.action == 'cleanup':
            require_root()
            if not options.yes: raise RuntimeError('Cleanup requires --yes and the exact preview --plan-id; WSL and user data remain')
            if not options.plan_id or not re.fullmatch(r'[a-f0-9]{64}', options.plan_id): raise RuntimeError('Preview cleanup-plan and supply its exact --plan-id')
            preview = cleanup.cleanup_plan(sys.modules[__name__])
            if preview.get('plan_id') != options.plan_id or preview.get('blockers'):
                raise RuntimeError('Cleanup plan changed or is blocked; preview and confirm it again')
            with cleanup_output() as logfile:
                data = cleanup.cleanup_apply(sys.modules[__name__], options.plan_id)
            data['log'] = str(logfile)
        else: data = uninstall(options)
        if options.json: print(json.dumps(data, ensure_ascii=False))
        elif options.action in ('cleanup-plan', 'cleanup'): show_cleanup(data)
        else:
            def show(values, prefix=''):
                for key, value in values.items():
                    if key == 'tail': continue
                    if isinstance(value, dict): show(value, prefix + key + '.')
                    elif isinstance(value, list):
                        for item in value: print(f'{prefix}{key}: {item}')
                    else: print(f'{prefix}{key}: {value}')
            show(data)
        return 1 if data.get('state') in ('ERROR', 'INTERRUPTED') else 0
    except Exception as exc:
        if options.json:
            error = dict(state='ERROR', error=str(exc))
            if options.action == 'cleanup': error['log'] = str(STATE / 'cleanup.log')
            if options.action == 'gpu': error['log'] = str(STATE / 'gpu.log')
            if options.action == 'ssh': error['log'] = str(STATE / 'ssh.log')
            print(json.dumps(error, ensure_ascii=False))
        else: print(f'oneDebian Agent: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
