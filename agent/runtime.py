#!/usr/bin/env python3
"""Ordinary-user processes for the oneDebian private browser desktop."""
import argparse
import hmac
from http.cookies import CookieError, SimpleCookie
import json
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import stat
import subprocess
import sys
import time
from urllib.parse import urlsplit
from urllib.request import urlopen

ROOT = Path('/opt/onedebian-agent')
CONFIG = Path('/etc/onedebian-agent/config.json')
VERSIONS = Path('/etc/onedebian-agent/versions.json')
MCP_UNIT = 'onedebian-agent-mcp.service'
COOKIE = 'onedebian_viewer'


def settings():
    import pwd
    metadata = CONFIG.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise RuntimeError('Agent configuration must be a root-owned, non-writable regular file')
    result = json.loads(CONFIG.read_text())
    account = pwd.getpwnam(result['user'])
    if account.pw_uid == 0 or account.pw_dir != result['home'] or os.getuid() != account.pw_uid:
        raise RuntimeError('Run as the configured ordinary Agent user')
    if not re.fullmatch(r':[1-9][0-9]{0,3}', result['display']):
        raise RuntimeError('Invalid private X display')
    for name in ('viewer_port', 'mcp_port', 'cdp_port'):
        if type(result[name]) is not int or not 1024 <= result[name] <= 65535:
            raise RuntimeError('Invalid Agent port')
    if len({result[x] for x in ('viewer_port', 'mcp_port', 'cdp_port')}) != 3:
        raise RuntimeError('Agent ports must differ')
    result['uid'] = account.pw_uid
    return result


def data_dir(config):
    return Path(config['home']) / '.local/share/onedebian-agent'


def run_dir(config):
    return Path('/run/user') / str(config['uid']) / 'onedebian-agent'


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise RuntimeError('Unsafe Agent directory: ' + str(path))
    path.chmod(0o700)
    return path


def private_file(path, value):
    # O_EXCL prevents following pre-existing symlinks or replacing credentials.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(value)


def viewer_token(config):
    private_dir(data_dir(config))
    path = data_dir(config) / 'viewer-token'
    try:
        private_file(path, secrets.token_urlsafe(32) + '\n')
    except FileExistsError:
        pass
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise RuntimeError('Unsafe viewer token file')
    value = path.read_text().strip()
    if not re.fullmatch(r'[A-Za-z0-9_-]{43}', value):
        raise RuntimeError('Invalid viewer token file')
    return value


def environment(config):
    result = os.environ.copy()
    result.pop('WAYLAND_DISPLAY', None)
    result.update(HOME=config['home'], DISPLAY=config['display'],
                  XAUTHORITY=str(run_dir(config) / 'Xauthority'),
                  XDG_RUNTIME_DIR='/run/user/' + str(config['uid']),
                  DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/' + str(config['uid']) + '/bus',
                  XDG_SESSION_TYPE='x11', XDG_CURRENT_DESKTOP='XFCE',
                  DESKTOP_SESSION='xfce', GDK_BACKEND='x11', QT_QPA_PLATFORM='xcb',
                  GTK_IM_MODULE='ibus', QT_IM_MODULE='ibus', XMODIFIERS='@im=ibus')
    return result


def node_command(config, *arguments):
    versions = json.loads(VERSIONS.read_text())
    version = versions['node']
    if not re.fullmatch(r'v26\.\d+\.\d+', version):
        raise RuntimeError('Agent requires the recorded complete Node 26 version')
    fnm_dir = Path(config['home']) / '.local/share/fnm'
    return [str(fnm_dir / 'fnm'), '--fnm-dir', str(fnm_dir), 'exec', '--using=' + version,
            'node', *map(str, arguments)]


def wait_x(config, process=None):
    for _ in range(100):
        if process is not None and process.poll() is not None:
            raise RuntimeError('Private X server exited before becoming ready')
        result = subprocess.run(['xdpyinfo'], env=environment(config), stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=4)
        if result.returncode == 0:
            return
        time.sleep(.2)
    raise RuntimeError('Private X server did not become ready')


def desktop_command(config):
    directory = run_dir(config)
    render = config.get('render_node', '')
    if render and not re.fullmatch(r'/dev/dri/renderD[0-9]+', render):
        raise RuntimeError('Invalid DRM render node')
    return ['Xtigervnc', config['display'], '-geometry', '1600x900', '-depth', '24',
            '-auth', str(directory / 'Xauthority'), '-SecurityTypes', 'None',
            '-rfbport', '-1', '-rfbunixpath', str(directory / 'vnc.sock'),
            '-rfbunixmode', '0600', '-nolisten', 'tcp', '-localhost', 'yes', '-rendernode', render]


def configure_private_desktop(env):
    for channel, property_name, kind, value in (
        ('xfce4-screensaver', '/saver/enabled', 'bool', 'false'),
        ('xfce4-screensaver', '/lock/enabled', 'bool', 'false'),
        ('xfce4-power-manager', '/xfce4-power-manager/dpms-enabled', 'bool', 'false'),
        ('xfce4-power-manager', '/xfce4-power-manager/inactivity-on-ac', 'uint', '0'),
        ('xfce4-power-manager', '/xfce4-power-manager/inactivity-on-battery', 'uint', '0'),
        ('xfce4-session', '/general/LockCommand', 'string', ''),
        ('xfce4-session', '/general/SaveOnExit', 'bool', 'false'),
        ('xfce4-session', '/general/AutoSave', 'bool', 'false'),
        ('xsettings', '/Gdk/WindowScalingFactor', 'int', '1'),
    ):
        command = ['xfconf-query', '-c', channel, '-p', property_name, '-s', value]
        result = subprocess.run(command, env=env, capture_output=True, check=False)
        if result.returncode:
            subprocess.run([*command, '-n', '-t', kind], env=env, check=True)


def desktop(config):
    directory = private_dir(run_dir(config))
    auth = directory / 'Xauthority'
    if auth.exists() or auth.is_symlink():
        metadata = auth.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise RuntimeError('Unsafe Xauthority file')
        auth.unlink()
    private_file(auth, '')
    subprocess.run(['xauth', '-f', str(auth), 'add', config['display'], '.', secrets.token_hex(16)],
                   check=True, env=environment(config))
    socket = directory / 'vnc.sock'
    if socket.exists() or socket.is_symlink():
        metadata = socket.lstat()
        if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise RuntimeError('Unsafe VNC socket path')
        socket.unlink()
    env = environment(config)
    children = []
    def stop(*_):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    try:
        server = subprocess.Popen(desktop_command(config), env=env)
        children.append(server)
        wait_x(config, server)
        subprocess.run(['systemctl', '--user', 'unset-environment', 'WAYLAND_DISPLAY'], env=env, check=True)
        subprocess.run(['dbus-update-activation-environment', '--systemd', 'DISPLAY', 'XAUTHORITY',
                        'XDG_CURRENT_DESKTOP', 'XDG_SESSION_TYPE'], env=env, check=True)
        subprocess.run(['xset', 's', 'off'], env=env, check=False)
        subprocess.run(['xset', '-dpms'], env=env, check=False)
        prompter = Path('/usr/libexec/gcr-prompter')
        if prompter.is_file():
            # D-Bus activation outside PrivateTmp cannot see this X socket.
            children.append(subprocess.Popen([str(prompter)], env=env))
        # Keep the normal user bus/keyring. Unlock remains an explicit user action.
        subprocess.run(['gnome-keyring-daemon', '--start', '--components=secrets'], env=env,
                       check=True, stdout=subprocess.DEVNULL)
        children.append(subprocess.Popen(['ibus-daemon', '--replace', '--xim'], env=env))
        session = subprocess.Popen(['xfce4-session'], env=env)
        children.append(session)
        configure_private_desktop(env)
        while server.poll() is None and session.poll() is None:
            time.sleep(.5)
        raise RuntimeError('Private desktop session ended')
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
        for child in reversed(children):
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)


def profile_path(config):
    base = data_dir(config)
    requested = config.get('probe_profile')
    if not requested:
        return base / 'profile'
    path = Path(requested)
    if not path.is_absolute() or path.resolve() == (base / 'probes').resolve() or not path.resolve().is_relative_to((base / 'probes').resolve()):
        raise RuntimeError('Probe profile must be inside the owned probes directory')
    return path


def initialize_profile(profile):
    private_dir(profile)
    default = private_dir(profile / 'Default')
    prefs = default / 'Preferences'
    if prefs.exists() or prefs.is_symlink():
        if prefs.is_symlink() or not prefs.is_file():
            raise RuntimeError('Unsafe Chromium preferences path')
        return
    private_file(prefs, json.dumps({'session': {'restore_on_startup': 1}}))


def chromium_command(config):
    profile = profile_path(config)
    command = ['/usr/bin/chromium', '--user-data-dir=' + str(profile),
            '--ozone-platform=x11', '--remote-debugging-address=127.0.0.1',
            '--remote-debugging-port=' + str(config['cdp_port']), '--no-first-run',
            '--no-default-browser-check', '--restore-last-session',
            '--disable-background-timer-throttling', '--disable-backgrounding-occluded-windows',
            '--disable-renderer-backgrounding']
    # A new Chrome WebUI tab can have no committed frame and stall CDP attachment.
    return command + (['about:blank'] if not (profile / 'Local State').exists() else [])


def chromium(config):
    wait_x(config)
    initialize_profile(profile_path(config))
    os.execvpe('/usr/bin/chromium', chromium_command(config), environment(config))


def manual(config):
    return os.path.lexists(data_dir(config) / 'manual')


def mcp_command(config):
    tools = data_dir(config) / 'tools/node_modules/@playwright/mcp/cli.js'
    return node_command(config, tools, '--host', '127.0.0.1', '--port', config['mcp_port'],
                        '--allowed-hosts', f"127.0.0.1:{config['mcp_port']},localhost:{config['mcp_port']}",
                        '--cdp-endpoint', f"http://127.0.0.1:{config['cdp_port']}",
                        '--shared-browser-context', '--idle-timeout', '0',
                        '--output-dir', str(Path(config['home']) / 'Downloads/onedebian-agent'))


def mcp(config):
    if not os.environ.get('INVOCATION_ID'):
        raise RuntimeError('Start MCP through the managed user service')
    for _ in range(90):
        if manual(config):
            return
        try:
            with urlopen(f"http://127.0.0.1:{config['cdp_port']}/json/version", timeout=2) as response:
                ready = response.status == 200
            if ready:
                break
        except OSError:
            pass
        time.sleep(.5)
    else:
        raise RuntimeError('Chromium CDP did not become ready')
    if manual(config):
        return
    command = mcp_command(config)
    os.execvpe(command[0], list(map(str, command)), environment(config))


def handoff(config, take):
    directory = private_dir(data_dir(config))
    marker = directory / 'manual'
    if take:
        try:
            private_file(marker, 'Manual browser control; MCP paused.\n')
        except FileExistsError:
            pass
        subprocess.run(['systemctl', '--user', 'stop', MCP_UNIT], env=environment(config), check=True)
        result = subprocess.run(['systemctl', '--user', 'is-active', MCP_UNIT], env=environment(config),
                                capture_output=True, text=True, check=False)
        if result.stdout.strip() not in ('inactive', 'failed'):
            raise RuntimeError('MCP has not stopped; do not enter manual input')
        try:
            with socket.create_connection(('127.0.0.1', config['mcp_port']), timeout=.3):
                raise RuntimeError('MCP port still has a listener; do not enter manual input')
        except OSError:
            pass
        print('人工接管中；浏览器和页面保持打开。')
    else:
        if marker.is_symlink():
            raise RuntimeError('Unsafe manual marker')
        marker.unlink(missing_ok=True)
        try:
            subprocess.run(['systemctl', '--user', 'start', MCP_UNIT], env=environment(config), check=True)
        except Exception:
            private_file(marker, 'MCP resume failed; manual control retained.\n')
            raise
        print('已交还 Codex；请重新读取标签页和页面后继续。')


class ViewerPolicy:
    def __init__(self, port, token):
        self.hosts = {f'localhost:{port}', f'127.0.0.1:{port}'}
        self.origins = {'http://' + host for host in self.hosts}
        self.token = token
        self.session = secrets.token_urlsafe(32)
        self.cookie_name = COOKIE + '_' + str(port)

    def host_allowed(self, headers):
        values = headers.get_all('Host', [])
        return len(values) == 1 and values[0].lower() in self.hosts

    def origin_allowed(self, headers):
        values = headers.get_all('Origin', [])
        hosts = headers.get_all('Host', [])
        return len(values) == 1 and len(hosts) == 1 and values[0] == 'http://' + hosts[0].lower()

    def authenticated(self, headers):
        try:
            values = headers.get_all('Cookie', [])
            if len(values) != 1:
                return False
            cookie = SimpleCookie(values[0])
            return self.cookie_name in cookie and hmac.compare_digest(cookie[self.cookie_name].value, self.session)
        except (ValueError, TypeError, CookieError):
            return False


def make_proxy(config, token=None):
    from websockify.websocketproxy import ProxyRequestHandler, WebSocketProxy
    policy = ViewerPolicy(config['viewer_port'], token or viewer_token(config))

    class ViewerHandler(ProxyRequestHandler):
        def parse_request(self):
            if not super().parse_request():
                return False
            if not self.server.viewer_policy.host_allowed(self.headers):
                self.send_error(403, 'Invalid viewer Host')
                self.close_connection = True
                return False
            if self.headers.get('Sec-Fetch-Site') not in (None, 'same-origin', 'none'):
                self.send_error(403, 'Cross-site viewer request rejected')
                self.close_connection = True
                return False
            origins = self.headers.get_all('Origin', [])
            if origins and not self.server.viewer_policy.origin_allowed(self.headers):
                self.send_error(403, 'Invalid viewer Origin')
                self.close_connection = True
                return False
            return True

        def end_headers(self):
            self.send_header('X-Frame-Options', 'DENY')
            self.send_header('Content-Security-Policy', "frame-ancestors 'none'; object-src 'none'; base-uri 'self'")
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Cache-Control', 'no-store')
            return super().end_headers()

        def log_message(self, *_):
            # Auth URLs, cookies and request bodies must never enter access logs.
            return

        def reject_unauthorized(self):
            if self.server.viewer_policy.authenticated(self.headers):
                return False
            self.send_error(401, 'Open desktop from the oneDebian menu to authorize')
            self.close_connection = True
            return True

        def handle_upgrade(self):
            if not self.server.viewer_policy.origin_allowed(self.headers):
                self.send_error(403, 'Exactly one matching viewer Origin is required')
                self.close_connection = True
                return
            if self.reject_unauthorized():
                return
            if urlsplit(self.path).path != '/websockify':
                self.send_error(404)
                return
            return super().handle_upgrade()

        def public_file(self, head=False):
            name = {'/': 'login.html', '/login.js': 'login.js'}.get(urlsplit(self.path).path)
            if name is None:
                return False
            content = (ROOT / 'viewer' / name).read_bytes()
            self.send_response(200)
            self.send_header('Content-Type', 'application/javascript' if name.endswith('.js') else 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            if not head:
                self.wfile.write(content)
            return True

        def do_GET(self):
            if self.public_file() or self.reject_unauthorized():
                return
            return super().do_GET()

        def do_HEAD(self):
            if self.public_file(head=True) or self.reject_unauthorized():
                return
            return super().do_HEAD()

        def do_POST(self):
            if urlsplit(self.path).path != '/auth':
                self.send_error(404)
                return
            if not self.server.viewer_policy.origin_allowed(self.headers):
                self.send_error(403, 'Invalid authentication Origin')
                return
            lengths = self.headers.get_all('Content-Length', [])
            if self.headers.get_all('Transfer-Encoding', []) or len(lengths) != 1 or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= 256:
                self.send_error(400, 'Invalid authentication body length')
                self.close_connection = True
                return
            try:
                body = json.loads(self.rfile.read(int(lengths[0])))
                value = body.get('token') if isinstance(body, dict) else None
                allowed = (isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_-]{43}', value) is not None
                           and hmac.compare_digest(value, self.server.viewer_policy.token))
            except (ValueError, UnicodeError):
                allowed = False
            if not allowed:
                self.send_error(403, 'Invalid viewer token')
                return
            self.send_response(204)
            self.send_header('Set-Cookie', f'{self.server.viewer_policy.cookie_name}={self.server.viewer_policy.session}; Path=/; HttpOnly; SameSite=Strict')
            self.send_header('Content-Length', '0')
            self.end_headers()

    proxy = WebSocketProxy(RequestHandlerClass=ViewerHandler,
                           listen_host='127.0.0.1', listen_port=config['viewer_port'],
                           target_host=None, target_port=None, unix_target=str(run_dir(config) / 'vnc.sock'),
                           web='/usr/share/novnc', file_only=True, web_auth=False)
    proxy.viewer_policy = policy
    return proxy


def status(config):
    services = {}
    for unit in ('onedebian-agent-desktop.service', 'onedebian-agent-chromium.service'):
        result = subprocess.run(['systemctl', 'is-active', unit], capture_output=True, text=True, check=False)
        services[unit] = result.stdout.strip() or 'unknown'
    for unit in (MCP_UNIT, 'onedebian-agent-novnc.service'):
        result = subprocess.run(['systemctl', '--user', 'is-active', unit], env=environment(config),
                                capture_output=True, text=True, check=False)
        services[unit] = result.stdout.strip() or 'unknown'
    return {'user': config['user'], 'manual': manual(config), 'services': services,
            'viewer': f"http://127.0.0.1:{config['viewer_port']}/", 'mcp': f"http://127.0.0.1:{config['mcp_port']}/mcp",
            'profile': str(profile_path(config)), 'render_node': config.get('render_node') or 'software',
            'keyring': 'User setup/unlock may be required; existing credentials are retained'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('desktop', 'chromium', 'mcp', 'mcp-permitted', 'novnc',
                                           'takeover', 'resume', 'status', 'open-url'))
    args = parser.parse_args()
    config = settings()
    if args.command == 'mcp-permitted':
        return 1 if manual(config) else 0
    if args.command == 'takeover':
        handoff(config, True)
    elif args.command == 'resume':
        handoff(config, False)
    elif args.command == 'status':
        print(json.dumps(status(config), ensure_ascii=False))
    elif args.command == 'open-url':
        print(f"http://127.0.0.1:{config['viewer_port']}/#token={viewer_token(config)}")
    elif args.command == 'novnc':
        make_proxy(config).start_server()
    else:
        globals()[args.command](config)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print('oneDebian Agent: ' + str(error), file=sys.stderr)
        sys.exit(1)
