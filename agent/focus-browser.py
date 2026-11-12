#!/usr/bin/env python3
"""Open links or focus the verified Agent browser without another browser profile."""
import json
import subprocess
import sys
from urllib.parse import urlsplit

from runtime import VERSIONS, settings
from verify import Verifier

BROWSER_UNIT = 'onedebian-agent-chromium.service'
START_BROWSER = ['/usr/bin/sudo', '-n', '--', '/usr/bin/python3', '-I', '/opt/onedebian-agent/start-browser.py']
RECOVERY = ('以 root 启动：systemctl start ' + BROWSER_UNIT
            + '\n查看日志：journalctl -u ' + BROWSER_UNIT + ' -n 60 --no-pager')


def ensure_browser():
    try:
        result = subprocess.run(['/usr/bin/systemctl', 'show', BROWSER_UNIT,
                                 '-p', 'LoadState', '-p', 'ActiveState', '-p', 'MainPID'],
                                capture_output=True, text=True, check=True, timeout=5)
        state = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        if state.get('LoadState') != 'loaded' or not state.get('MainPID', '').isdecimal():
            raise RuntimeError('浏览器服务尚未安装或状态无法确认，请先执行“桌面更新”。')
        active, pid = state.get('ActiveState'), int(state['MainPID'])
        if active in ('inactive', 'failed') and pid == 0:
            subprocess.run(START_BROWSER, capture_output=True, text=True, check=True, timeout=45)
        elif active == 'activating' or (active in ('active', 'reloading') and pid > 0):
            return
        else:
            raise RuntimeError('浏览器正在退出或服务状态不一致，请稍后重试。')
    except (OSError, subprocess.SubprocessError) as error:
        detail = getattr(error, 'stderr', '') or str(error)
        raise RuntimeError('无法启动受管浏览器，请先执行“桌面更新”或检查服务。\n'
                           + str(detail)[-600:] + '\n' + RECOVERY) from error


def browser_url(value):
    allowed = isinstance(value, str) and value and not any(char.isspace() or ord(char) < 32 or ord(char) == 127 for char in value)
    if allowed and value in ('about:blank', 'chrome://gpu', 'chrome://gpu/', 'chrome://version', 'chrome://version/'):
        return value
    if allowed:
        try:
            parsed = urlsplit(value)
            allowed = parsed.scheme in ('http', 'https') and bool(parsed.hostname)
            _ = parsed.port  # Reject malformed/out-of-range ports before navigation.
        except ValueError:
            allowed = False
    if not allowed:
        raise RuntimeError('Only HTTP/HTTPS links and approved internal diagnostic pages can be opened')
    return value


def focus_browser(config, versions, urls=()):
    urls = [browser_url(value) for value in urls]
    if config.get('probe_profile') or config.get('probe_unit'):
        raise RuntimeError('GPU probe is active; retry when the working browser is ready')
    ensure_browser()
    control = Verifier(config, versions)
    # User-launched links/focus are permitted during handoff; automation remains paused.
    control.manual = lambda: False
    try:
        control.browser_ready()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        raise RuntimeError('受管浏览器启动后调试端口仍未就绪。\n' + str(error) + '\n' + RECOVERY) from error
    if urls:
        for url in urls:
            target = control.cdp('Target.createTarget', {'url': url})['targetId']
    else:
        pages = [item for item in control.cdp('Target.getTargets')['targetInfos'] if item['type'] == 'page']
        if not pages:
            raise RuntimeError('The managed browser has no page to focus; check its Chromium service')
        target = next((item for item in pages if item.get('url') not in ('', 'about:blank')), pages[0])['targetId']
    control.cdp('Target.activateTarget', {'targetId': target})
    return target


def show_error(error):
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk
    dialog = Gtk.MessageDialog(message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.OK,
                               text='Agent 工作浏览器操作未完成')
    dialog.format_secondary_text(str(error)[-1000:])
    dialog.run()
    dialog.destroy()


def main():
    try:
        focus_browser(settings(), json.loads(VERSIONS.read_text()), sys.argv[1:])
        return 0
    except Exception as error:
        try:
            show_error(error)
        except Exception:
            print('Agent 工作浏览器尚未就绪：' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
