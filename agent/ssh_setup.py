"""Key-only loopback SSH owned by oneDebian, without replacing system SSH."""
import contextlib
import hashlib
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import tempfile
import time

UNIT = 'onedebian-agent-ssh.service'
SYSTEM = Path('/etc/systemd/system')
POLICY = Path('/usr/sbin/policy-rc.d')
RUNTIME = Path('/run/sshd')
SSHD = '/usr/sbin/sshd'
POLICY_TEXT = '#!/bin/sh\ncase "$1" in ssh|sshd|ssh.service|ssh.socket) exit 101;; *) exit 0;; esac\n'


def _hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _parents(path, base):
    for parent in [path.parent, *path.parent.parents]:
        if parent.exists() or parent.is_symlink():
            info = parent.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                raise RuntimeError('Unsafe SSH configuration directory: ' + str(parent))
        if parent == base:
            return
    raise RuntimeError('SSH path is outside its owned root')


def _owned(i, path, base):
    _parents(path, base)
    if not path.exists() and not path.is_symlink():
        return None
    info = path.lstat()
    manifest = i.read_json(i.STATE / 'files.json', {})
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022 or manifest.get(str(path)) != _hash(path):
        raise RuntimeError('Unowned or modified SSH file requires review: ' + str(path))
    return path.read_text(), stat.S_IMODE(info.st_mode)


def _unit(i, name):
    raw = i.capture(['systemctl', 'show', name, '-p', 'LoadState,ActiveState,UnitFileState,MainPID'])
    return dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)


def _installed(i, package):
    try:
        return i.capture(['dpkg-query', '-W', '-f=${db:Status-Status}', package]) == 'installed'
    except subprocess.CalledProcessError:
        return False


def _listener_owned(i, port, pid):
    if not str(pid).isdecimal() or int(pid) < 1:
        return False
    rows = i.capture(['ss', '-H', '-ltnp', 'sport = :' + str(port)]).splitlines()
    return bool(rows) and all(('127.0.0.1:' + str(port)) in row.split()
                              and re.search(r'\bpid=' + str(pid) + r'[,)]', row) for row in rows)


def _public_key(i, text):
    if not isinstance(text, str) or len(text) > 16384 or not re.fullmatch(
        r'(?:ssh-ed25519|ecdsa-sha2-nistp(?:256|384|521)|ssh-rsa) [A-Za-z0-9+/]+={0,3}(?: [^\r\n\x00]+)?', text):
        raise RuntimeError('Supply one public key line, without authorized_keys options or private key material')
    with tempfile.NamedTemporaryFile(mode='w', dir=i.STATE, prefix='.ssh-key-check-', encoding='utf-8') as temporary:
        temporary.write(text + '\n'); temporary.flush()
        i.run(['ssh-keygen', '-l', '-f', temporary.name], capture_output=True, text=True)
    return ' '.join(text.split(' ', 2)[:2])


@contextlib.contextmanager
def _no_default_start():
    created = False
    if not POLICY.exists() and not POLICY.is_symlink():
        descriptor = os.open(POLICY, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o755)
        with os.fdopen(descriptor, 'w') as stream:
            os.fchmod(stream.fileno(), 0o755)
            stream.write(POLICY_TEXT)
        created = True
    try:
        yield
    finally:
        if created:
            info = POLICY.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o755 or POLICY.read_text() != POLICY_TEXT:
                raise RuntimeError('Temporary SSH service policy changed; it was retained for review')
            POLICY.unlink()


def _quote(path):
    return '"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"'


def _config(i, port):
    return (f'Port {port}\nAddressFamily inet\nListenAddress 127.0.0.1\n'
            f'HostKey {_quote(i.ETC / "ssh_host_ed25519_key")}\n'
            f'PidFile {_quote(i.STATE / "sshd.pid")}\n'
            f'AuthorizedKeysFile {_quote(i.ETC / "ssh_authorized_keys")}\n'
            'AllowUsers agent\nPermitRootLogin no\nPubkeyAuthentication yes\n'
            'AuthenticationMethods publickey\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n'
            'PermitEmptyPasswords no\nUsePAM yes\nStrictModes yes\n'
            'AllowAgentForwarding no\nX11Forwarding no\nPermitTunnel no\n'
            'AllowTcpForwarding local\nPermitOpen 127.0.0.1:*\nPermitListen none\n'
            'AllowStreamLocalForwarding no\nGatewayPorts no\nPrintMotd no\n'
            'Subsystem sftp internal-sftp\n')


def _verify_config(i, config, port):
    i.run([SSHD, '-t', '-f', str(config)])
    raw = i.capture([SSHD, '-T', '-f', str(config), '-C', 'user=agent,host=localhost,addr=127.0.0.1'])
    values = dict(line.split(' ', 1) for line in raw.splitlines() if ' ' in line)
    required = dict(port=str(port), addressfamily='inet', listenaddress=f'127.0.0.1:{port}',
                    permitrootlogin='no', pubkeyauthentication='yes', authenticationmethods='publickey',
                    passwordauthentication='no', kbdinteractiveauthentication='no', usepam='yes',
                    allowusers='agent', authorizedkeysfile=str(i.ETC / 'ssh_authorized_keys'),
                    hostkey=str(i.ETC / 'ssh_host_ed25519_key'), allowagentforwarding='no',
                    x11forwarding='no', allowtcpforwarding='local', permitopen='127.0.0.1:*',
                    permitlisten='none', allowstreamlocalforwarding='no', gatewayports='no')
    for key, value in required.items():
        if values.get(key) != value:
            raise RuntimeError('SSH effective configuration mismatch: ' + key)


def _restore(i, before, written):
    manifest = i.read_json(i.STATE / 'files.json', {})
    retained = []
    for path, original in reversed(list(before.items())):
        if path not in written:
            continue
        if path.is_symlink() or not path.is_file() or path.stat().st_uid != 0 or path.stat().st_mode & 0o022 or _hash(path) != written[path]:
            retained.append(str(path))
            continue
        if original is None:
            path.unlink(); manifest.pop(str(path), None)
        else:
            content, mode = original
            i.atomic(path, content, mode)
            manifest[str(path)] = _hash(path)
    i.write_json(i.STATE / 'files.json', manifest)
    return retained


def setup(i, public_key, port=2222):
    """The caller holds install.lock and records this operation with cleanup.tracking."""
    i.require_root()
    if type(port) is not int or not 1024 <= port <= 65535:
        raise RuntimeError('SSH port must be an unprivileged TCP port (1024-65535)')
    config = i.read_json(i.ETC / 'config.json', {})
    if port in {config.get(name) for name in ('viewer_port', 'mcp_port', 'cdp_port')}:
        raise RuntimeError('SSH port conflicts with a configured browser workstation port')
    account = i.pwd.getpwnam('agent')
    if account.pw_uid == 0 or account.pw_dir != '/home/agent':
        raise RuntimeError('Unexpected Agent account')
    key = _public_key(i, public_key)
    unit_path = SYSTEM / UNIT
    files = [i.ETC / name for name in ('sshd_config', 'ssh_authorized_keys', 'ssh_host_ed25519_key', 'ssh_host_ed25519_key.pub')] + [unit_path]
    before = {path: _owned(i, path, SYSTEM if path == unit_path else i.ETC) for path in files}
    host = i.ETC / 'ssh_host_ed25519_key'
    if before[host] is None and before[Path(str(host) + '.pub')] is not None:
        raise RuntimeError('An existing public host key has no private key; identity was retained')
    previous = _unit(i, UNIT)
    if previous.get('LoadState') != 'not-found' and before[unit_path] is None:
        raise RuntimeError('An unowned SSH service already uses the oneDebian unit name')
    if not i.port_free(port) and not (previous.get('ActiveState') == 'active'
                                      and _listener_owned(i, port, previous.get('MainPID'))):
        raise RuntimeError(f'TCP port {port} is occupied by another service; choose a different SSH port')
    missing = [name for name in ('openssh-server', 'netcat-openbsd') if not _installed(i, name)]
    guards = []
    if 'openssh-server' in missing:
        for name in ('ssh.service', 'ssh.socket'):
            if _unit(i, name).get('LoadState') == 'not-found':
                path = SYSTEM / (name + '.d') / '90-onedebian-agent.conf'
                _owned(i, path, SYSTEM)
                guards.append((name, path))
    written = {}; start_attempted = False
    try:
        # Keep guards if package installation fails: the newly installed global unit must not expose port 22.
        for name, path in guards:
            i.owned_file(path, '[Unit]\nConditionPathExists=' + str(i.STATE / 'allow-system-ssh') + '\n')
        if guards:
            i.run(['systemctl', 'daemon-reload'])
        if missing:
            with _no_default_start() if 'openssh-server' in missing else contextlib.nullcontext():
                argv = ['apt-get', 'install', '-y', '--no-install-recommends', *missing]
                try:
                    i.run(i.package_undo.install_args(i, argv), env=dict(os.environ, DEBIAN_FRONTEND='noninteractive'))
                finally:
                    i.package_undo.finish(i)
        if guards:
            i.run(['systemctl', 'daemon-reload'])
        for name, path in guards:
            if _unit(i, name).get('LoadState') != 'not-found':
                i.run(['systemctl', 'disable', name])
        if before[host] is None:
            with tempfile.TemporaryDirectory(prefix='.ssh-host-', dir=i.STATE) as temporary:
                generated = Path(temporary) / 'host'
                i.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(generated)])
                for path, source, mode in [(host, generated, 0o600), (Path(str(host) + '.pub'), Path(str(generated) + '.pub'), 0o644)]:
                    i.owned_file(path, source.read_text(), mode); written[path] = _hash(path)
        else:
            if stat.S_IMODE(host.stat().st_mode) != 0o600:
                raise RuntimeError('Private SSH host key permissions require review')
            derived = i.capture(['ssh-keygen', '-y', '-f', str(host)])
            pub = Path(str(host) + '.pub')
            if before[pub] is None:
                i.owned_file(pub, derived + '\n'); written[pub] = _hash(pub)
            elif _public_key(i, pub.read_text().strip()) != _public_key(i, derived):
                raise RuntimeError('SSH host keypair does not match')
        for path, content, mode in [(i.ETC / 'ssh_authorized_keys', key + '\n', 0o644),
                                   (i.ETC / 'sshd_config', _config(i, port), 0o600)]:
            i.owned_file(path, content, mode); written[path] = _hash(path)
        _parents(RUNTIME / 'placeholder', RUNTIME)
        RUNTIME.mkdir(mode=0o755, parents=True, exist_ok=True)
        _verify_config(i, i.ETC / 'sshd_config', port)
        command = SSHD + ' -D -e -f ' + _quote(i.ETC / 'sshd_config')
        content = ('[Unit]\nDescription=oneDebian loopback key-only SSH\nAfter=network.target\n\n'
                   '[Service]\nType=simple\nExecStart=' + command + '\nRestart=on-failure\nRestartSec=3\n'
                   '\n[Install]\nWantedBy=multi-user.target\n')
        i.owned_file(unit_path, content); written[unit_path] = _hash(unit_path)
        changed = any(before[path] is None or before[path] != (path.read_text(), stat.S_IMODE(path.stat().st_mode))
                      for path in written)
        if before[unit_path] != (content, stat.S_IMODE(unit_path.stat().st_mode)):
            i.run(['systemctl', 'daemon-reload'])
        if previous.get('UnitFileState') != 'enabled': i.run(['systemctl', 'enable', UNIT])
        if changed or previous.get('ActiveState') != 'active' or not _listener_owned(i, port, previous.get('MainPID')):
            start_attempted = True
            i.run(['systemctl', 'restart' if previous.get('ActiveState') == 'active' else 'start', UNIT])
        deadline = time.monotonic() + 8
        while True:
            status = _unit(i, UNIT)
            if status.get('ActiveState') == 'active' and _listener_owned(i, port, status.get('MainPID')):
                with socket.create_connection(('127.0.0.1', port), timeout=2) as connection:
                    connection.settimeout(2)
                    if not connection.recv(32).startswith(b'SSH-2.0-'):
                        raise RuntimeError('The owned SSH listener did not send an SSH banner')
                break
            if time.monotonic() >= deadline:
                raise RuntimeError('The owned SSH service did not start its loopback listener')
            time.sleep(.2)
        host_public = _public_key(i, Path(str(host) + '.pub').read_text().strip())
        record = dict(state='SSH_READY', owner=i.OWNER, port=port, host_public_key=host_public,
                      reason='Loopback key-only SSH is enabled; use the Windows WSL proxy alias, not a changing NAT address')
        i.write_json(i.STATE / 'ssh.json', record, 0o600)
        return record
    except Exception as error:
        retained = []; recovery_error = None
        try:
            if start_attempted:
                i.run(['systemctl', 'stop', UNIT])
                if previous.get('UnitFileState') != 'enabled':
                    i.run(['systemctl', 'disable', UNIT])
            retained = _restore(i, before, written)
            i.run(['systemctl', 'daemon-reload'])
            if start_attempted and previous.get('ActiveState') == 'active' and not retained:
                i.run(['systemctl', 'start', UNIT])
        except Exception as failed_recovery:
            recovery_error = str(failed_recovery)
        i.write_json(i.STATE / 'ssh.json', dict(state='ERROR', owner=i.OWNER, port=port, error=str(error),
                     retained=retained, recovery_error=recovery_error,
                     global_guards_retained=[str(path) for _, path in guards]), 0o600)
        if recovery_error:
            raise RuntimeError('SSH setup failed and recovery requires review: ' + recovery_error) from error
        raise
