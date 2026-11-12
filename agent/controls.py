#!/usr/bin/env python3
"""A movable, persistent browser handoff button inside the private desktop."""
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile
import time

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gdk, GLib, Gtk
from runtime import MCP_UNIT, data_dir, environment, manual, private_dir, settings

EDGES = ('left', 'right', 'top', 'bottom')


def clamp_position(x, y, area, size):
    ax, ay, width, height = area
    return (int(max(ax, min(x, ax + max(0, width - size[0])))),
            int(max(ay, min(y, ay + max(0, height - size[1])))))


def dock_edge(x, y, area, size, threshold=12):
    ax, ay, width, height = area
    distances = (abs(x - ax), abs(ax + width - x - size[0]),
                 abs(y - ay), abs(ay + height - y - size[1]))
    closest = min(range(4), key=lambda n: distances[n])
    return EDGES[closest] if distances[closest] <= threshold else None


def position_for(saved, area, size):
    x, y = saved['x'], saved['y']
    edge = saved.get('edge')
    ax, ay, width, height = area
    if edge == 'left': x = ax
    elif edge == 'right': x = ax + width - size[0]
    elif edge == 'top': y = ay
    elif edge == 'bottom': y = ay + height - size[1]
    return clamp_position(x, y, area, size)


def valid_position(value):
    return (isinstance(value, dict)
            and all(type(value.get(k)) is int and abs(value[k]) <= 1000000 for k in ('x', 'y'))
            and value.get('edge') in (None, *EDGES))


def position_metadata(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('Unsafe floating-control position file')


def load_position(path):
    try:
        position_metadata(path)
        if path.stat().st_size > 4096: return None
        result = json.loads(path.read_text())
        return result if valid_position(result) else None
    except (OSError, ValueError, RuntimeError):
        return None


def save_position(path, position):
    if not valid_position(position): raise ValueError('Invalid floating-control position')
    private_dir(path.parent)
    if path.exists() or path.is_symlink(): position_metadata(path)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                         prefix='.controls-position-', delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(dict(version=1, x=position['x'], y=position['y'], edge=position.get('edge')), stream)
            stream.write('\n')
        os.replace(temporary, path)
    finally:
        if temporary is not None: temporary.unlink(missing_ok=True)


def presentation(paused, state, listening):
    if state not in {'active', 'inactive', 'failed', 'activating', 'deactivating', 'reloading'} or listening is None:
        return dict(label='检查连接…', command=None, style='unknown',
                    tooltip='正在核对 MCP 状态；尚不能确认浏览器已安全接管。')
    if paused and state in {'inactive', 'failed'} and not listening:
        return dict(label='交还 Codex', command='resume', style='manual',
                    tooltip='人工接管中；点击交还后，请让 Codex 重新读取页面。拖动可移动，靠边可收纳。')
    if paused:
        return dict(label='接管浏览器', command='takeover', style='warning',
                    tooltip='接管尚未完成，MCP 或其端口仍在运行。点击重试停止通道，再人工输入。')
    ready = state in {'active', 'reloading'} and listening
    return dict(label='接管浏览器', command='takeover', style='automatic' if ready else 'warning',
                tooltip=('Codex 通道运行中。' if ready else 'MCP 通道当前未就绪。')
                + '点击接管，保留页面和构建任务；拖动可移动，靠边可收纳。')


def probe_state(config):
    try:
        result = subprocess.run(['systemctl', '--user', 'is-active', MCP_UNIT],
                                env=environment(config), capture_output=True, text=True, timeout=2)
        state = result.stdout.strip() if result.returncode in (0, 3) else 'unknown'
        try:
            with socket.create_connection(('127.0.0.1', config['mcp_port']), timeout=.2):
                listening = True
        except ConnectionRefusedError:
            listening = False
        except OSError:
            listening = None
        return dict(manual=manual(config), state=state, listening=listening)
    except (OSError, subprocess.SubprocessError):
        return dict(manual=manual(config), state='unknown', listening=None)


class Controls(Gtk.Window):
    def __init__(self, config):
        super().__init__(title='Agent 浏览器控制')
        self.config = config
        self.worker = self.probe = self.pointer = None
        self.snapshot = None
        self.next_probe = 0
        self.file = data_dir(config) / 'controls-position.json'
        self.saved = load_position(self.file)
        self.edge = self.saved.get('edge') if self.saved else None
        self.placed = False
        self.dialog_open = False
        self.position_error = None
        self.set_wmclass('onedebian-agent-controls', 'onedebian-agent-controls')
        self.set_name('agent-control-window')
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_accept_focus(False)
        self.set_app_paintable(True)
        visual = self.get_screen().get_rgba_visual()
        if visual: self.set_visual(visual)
        self.connect('delete-event', lambda *_: True)
        self.connect('map-event', self.mapped)
        self.add_events(Gdk.EventMask.BUTTON_RELEASE_MASK | Gdk.EventMask.POINTER_MOTION_MASK)
        self.connect('motion-notify-event', self.motion)
        self.connect('button-release-event', self.released)
        self.get_screen().connect('monitors-changed', lambda *_: GLib.idle_add(self.place))
        self.button = Gtk.Button()
        self.button.set_name('agent-handoff')
        self.button.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK |
                               Gdk.EventMask.POINTER_MOTION_MASK)
        self.button.connect('button-press-event', self.pressed)
        self.button.connect('motion-notify-event', self.motion)
        self.button.connect('button-release-event', self.released)
        self.button.connect('clicked', self.clicked)
        self.add(self.button)
        css = Gtk.CssProvider()
        css.load_from_data(b"""
#agent-control-window {background:transparent;}
#agent-handoff {background-image:none;background-color:#6353cc;color:white;border:1px solid #493fa0;border-radius:12px;padding:7px 12px;font-weight:bold;}
#agent-handoff.manual {background-color:#ffce73;color:#3d2a0f;border-color:#e2ab45;}
#agent-handoff.warning {background-color:#b55b16;border-color:#8e4710;}
#agent-handoff.unknown {background-color:#626b7b;border-color:#4f5663;}
#agent-handoff.edge-tab {padding:2px;border-radius:8px;}
""")
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.render()
        self.show_all()
        GLib.timeout_add(150, self.refresh)

    def area(self):
        display = Gdk.Display.get_default()
        monitor = display.get_monitor_at_window(self.get_window()) if self.get_window() else display.get_primary_monitor()
        rect = (monitor or display.get_monitor(0)).get_workarea()
        return rect.x, rect.y, rect.width, rect.height

    def size(self):
        return (28, 44) if self.edge in ('left', 'right') else (60, 28) if self.edge else (152, 44)

    def mapped(self, *_):
        if not self.placed:
            self.placed = True
            GLib.idle_add(self.place)
        return False

    def place(self):
        area = self.area()
        if self.saved is None:
            self.saved = dict(x=area[0]+area[2]-164, y=area[1]+area[3]-56, edge=self.edge)
        position = dict(self.saved, edge=self.edge)
        x, y = position_for(position, area, self.size())
        self.saved.update(x=x, y=y, edge=self.edge)
        self.move(x, y)
        return False

    def persist(self):
        x, y = self.get_position()
        self.saved = dict(x=x, y=y, edge=self.edge)
        try:
            save_position(self.file, self.saved)
            self.position_error = None
        except (OSError, RuntimeError, ValueError) as error:
            self.position_error = str(error)

    def render(self):
        value = presentation(manual(self.config), (self.snapshot or {}).get('state'),
                             (self.snapshot or {}).get('listening'))
        context = self.button.get_style_context()
        for name in ('automatic', 'manual', 'warning', 'unknown', 'edge-tab'): context.remove_class(name)
        context.add_class(value['style'])
        if self.edge:
            context.add_class('edge-tab')
            text = {'left':'▶', 'right':'◀', 'top':'▼', 'bottom':'▲'}[self.edge]
            tooltip = '展开浏览器控制；此次点击不会接管或交还。' + value['tooltip']
        else:
            text = '正在切换…' if self.worker else value['label']
            tooltip = value['tooltip']
        if self.position_error: tooltip += ' 位置暂未保存：' + self.position_error
        self.button.set_label(text)
        self.button.set_tooltip_text(tooltip)
        self.button.get_accessible().set_name('展开浏览器控制' if self.edge else text)
        self.button.set_sensitive(bool(self.edge) or (not self.worker and value['command'] is not None))
        self.button.set_size_request(*self.size())
        self.resize(*self.size())

    def pressed(self, _widget, event):
        if event.button != 1: return False
        x, y = self.get_position()
        self.pointer = dict(x=event.x_root, y=event.y_root, window_x=x, window_y=y, moved=False, device=event.get_device())
        grabbed = self.pointer['device'].grab(self.get_window(), Gdk.GrabOwnership.APPLICATION, False,
            Gdk.EventMask.BUTTON_RELEASE_MASK | Gdk.EventMask.POINTER_MOTION_MASK, None, event.time)
        if grabbed != Gdk.GrabStatus.SUCCESS: self.pointer = None
        return True

    def clicked(self, *_):
        event = Gtk.get_current_event()
        # Pointer releases are handled once in released(); retain keyboard/AT-SPI activation.
        if event and event.type not in (Gdk.EventType.KEY_PRESS, Gdk.EventType.KEY_RELEASE): return
        if not self.pointer: self.activate()

    def motion(self, _widget, event):
        if not self.pointer: return False
        dx, dy = event.x_root-self.pointer['x'], event.y_root-self.pointer['y']
        if abs(dx) + abs(dy) > 6: self.pointer['moved'] = True
        if self.pointer['moved']:
            self.move(*clamp_position(self.pointer['window_x']+dx, self.pointer['window_y']+dy,
                                     self.area(), self.size()))
        return True

    def released(self, _widget, event):
        if event.button != 1 or not self.pointer: return False
        self.motion(_widget, event)
        pointer, self.pointer = self.pointer, None
        pointer['device'].ungrab(event.time)
        if pointer['moved']:
            x, y = self.get_position()
            self.edge = dock_edge(x, y, self.area(), self.size())
            self.saved = dict(x=x, y=y, edge=self.edge)
            self.render()
            GLib.idle_add(self.place_and_save)
            return True
        self.activate()
        return True

    def place_and_save(self):
        self.place()
        self.persist()
        return False

    def activate(self):
        if self.edge:
            self.edge = None
            self.render()
            GLib.idle_add(self.place_and_save)
            return
        if self.worker or self.dialog_open or not self.snapshot: return
        value = presentation(manual(self.config), self.snapshot.get('state'), self.snapshot.get('listening'))
        if not value['command']: return
        self.dialog_open = True
        self.set_accept_focus(True)
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.YES_NO,
            text=('暂停 MCP 并接管浏览器？页面和构建任务会保留。' if value['command']=='takeover'
                  else '交还 Codex？请停止人工输入，并让 Codex 重新读取页面。'))
        accepted = dialog.run() == Gtk.ResponseType.YES
        dialog.destroy()
        self.set_accept_focus(False)
        self.dialog_open = False
        if not accepted or not self.snapshot: return
        current = presentation(manual(self.config), self.snapshot.get('state'), self.snapshot.get('listening'))
        if current['command'] != value['command']: return
        self.stop_probe()
        self.worker = subprocess.Popen(['/usr/bin/python3', '/opt/onedebian-agent/runtime.py', value['command']],
                                       env=environment(self.config), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.render()

    def stop_probe(self):
        if self.probe:
            if self.probe.poll() is None: self.probe.kill()
            self.probe.communicate()
            self.probe = None
        self.snapshot = None
        self.next_probe = 0

    def refresh(self):
        if self.worker:
            if self.worker.poll() is None: return True
            output, error = self.worker.communicate()
            failed = self.worker.returncode != 0
            self.worker = None
            self.stop_probe()
            if failed:
                dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.ERROR,
                                           buttons=Gtk.ButtonsType.OK, text='切换未完成，请勿继续输入。')
                dialog.format_secondary_text((error or output)[-800:])
                dialog.run()
                dialog.destroy()
        now = time.monotonic()
        if self.probe and (self.probe.poll() is not None or now-self.probe_started > 4):
            timed_out = self.probe.poll() is None
            if timed_out: self.probe.kill()
            output, _ = self.probe.communicate()
            self.probe = None
            try:
                value = json.loads(output) if not timed_out else {}
                self.snapshot = value if value.get('manual') == manual(self.config) else None
            except (ValueError, TypeError): self.snapshot = None
            self.next_probe = now + 1
        if not self.probe and now >= self.next_probe:
            self.probe = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--probe'],
                env=environment(self.config), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.probe_started = now
        self.render()
        return True


if __name__ == '__main__':
    if sys.argv[1:] == ['--probe']:
        print(json.dumps(probe_state(settings())))
    else:
        GLib.set_prgname('onedebian-agent-controls')
        Controls(settings())
        Gtk.main()
