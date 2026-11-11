#!/usr/bin/env python3
"""Explicit handoff controls inside the private XFCE desktop."""
import subprocess
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gdk, GLib, Gtk
from runtime import MCP_UNIT, data_dir, environment, manual, settings


class Controls(Gtk.Window):
    def __init__(self, config):
        super().__init__(title='Agent 浏览器控制')
        self.config = config
        self.worker = None
        self.set_wmclass('onedebian-agent-controls', 'onedebian-agent-controls')
        self.set_resizable(False)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_accept_focus(False)
        self.connect('delete-event', lambda *_: True)
        self.connect('map-event', lambda *_: GLib.idle_add(self.position))
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin=8)
        self.label = Gtk.Label()
        box.pack_start(self.label, False, False, 0)
        row = Gtk.Box(spacing=8)
        self.take = Gtk.Button(label='接管浏览器')
        self.give = Gtk.Button(label='交还 Codex')
        self.take.connect('clicked', lambda *_: self.change('takeover'))
        self.give.connect('clicked', lambda *_: self.change('resume'))
        row.pack_start(self.take, True, True, 0)
        row.pack_start(self.give, True, True, 0)
        box.pack_start(row, True, True, 0)
        self.add(box)
        self.show_all()
        GLib.timeout_add(500, self.refresh)

    def position(self, *_):
        display = Gdk.Display.get_default()
        monitor = display.get_monitor_at_window(self.get_window())
        area = monitor.get_workarea()
        width, height = self.get_size()
        self.move(area.x + max(0, area.width - width - 12), area.y + max(0, area.height - height - 12))
        return False

    def change(self, command):
        if self.worker:
            return
        self.set_accept_focus(True)
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.YES_NO,
                                   text=('暂停 MCP 并接管浏览器？页面和构建任务会保留。' if command == 'takeover'
                                         else '交还 Codex？请停止人工输入，并让 Codex 重新读取页面。'))
        accepted = dialog.run() == Gtk.ResponseType.YES
        dialog.destroy()
        self.set_accept_focus(False)
        if not accepted:
            return
        self.worker = subprocess.Popen(['/usr/bin/python3', '/opt/onedebian-agent/runtime.py', command],
                                       env=environment(self.config), stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
        self.take.set_sensitive(False)
        self.give.set_sensitive(False)
        self.label.set_text('正在切换，请稍候…')

    def refresh(self):
        if self.worker:
            if self.worker.poll() is None:
                return True
            output, error = self.worker.communicate()
            failed = self.worker.returncode != 0
            self.worker = None
            self.take.set_sensitive(True)
            self.give.set_sensitive(True)
            if failed:
                dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.ERROR,
                                           buttons=Gtk.ButtonsType.OK, text='切换未完成，请勿继续输入。')
                dialog.format_secondary_text((error or output)[-800:])
                dialog.run()
                dialog.destroy()
        self.label.set_text('人工接管中 · 页面保持打开' if manual(self.config) else 'Codex 浏览器通道已交还')
        return True


if __name__ == '__main__':
    GLib.set_prgname('onedebian-agent-controls')
    Controls(settings())
    Gtk.main()
