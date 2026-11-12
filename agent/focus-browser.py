#!/usr/bin/env python3
"""Focus the verified Agent browser, without launching another browser profile."""
import json
import sys

from runtime import VERSIONS, settings
from verify import Verifier


def focus_browser(config, versions):
    if config.get('probe_profile') or config.get('probe_unit'):
        raise RuntimeError('GPU probe is active; retry when the working browser is ready')
    control = Verifier(config, versions)
    # Explicitly focusing a window is permitted during handoff; page input remains paused.
    control.manual = lambda: False
    control.browser_ready()
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
                               text='Agent 工作浏览器尚未就绪')
    dialog.format_secondary_text('请检查工作机 Chromium 服务后重试。\n\n' + str(error)[-1000:])
    dialog.run()
    dialog.destroy()


def main():
    try:
        focus_browser(settings(), json.loads(VERSIONS.read_text()))
        return 0
    except Exception as error:
        try:
            show_error(error)
        except Exception:
            print('Agent 工作浏览器尚未就绪：' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
