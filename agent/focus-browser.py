#!/usr/bin/env python3
"""Open links or focus the verified Agent browser without another browser profile."""
import json
import sys
from urllib.parse import urlsplit

from runtime import VERSIONS, settings
from verify import Verifier


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
    control = Verifier(config, versions)
    # User-launched links/focus are permitted during handoff; automation remains paused.
    control.manual = lambda: False
    control.browser_ready()
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
