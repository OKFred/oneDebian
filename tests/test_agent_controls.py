"""Floating-control decisions against temporary files; never launches a desktop."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'agent'))
SPEC = importlib.util.spec_from_file_location('onedebian_controls', ROOT / 'agent/controls.py')
controls = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(controls)


class PositionTests(unittest.TestCase):
    def test_position_stays_in_the_monitor_workarea_after_a_resolution_change(self):
        self.assertEqual(controls.clamp_position(3000, -900, (-1600, 28, 1600, 872), (148, 44)), (-148, 28))
        self.assertEqual(controls.clamp_position(-20, 500, (20, 30, 100, 50), (148, 70)), (20, 30))
        self.assertEqual(controls.clamp_position(50, 80, (20, 30, 800, 600), (148, 44)), (50, 80))

    def test_only_a_nearby_edge_docks_and_the_nearest_corner_edge_wins(self):
        area = (0, 28, 1600, 872)
        for point, edge in [((4, 300), 'left'), ((1448, 300), 'right'),
                            ((500, 32), 'top'), ((500, 852), 'bottom'),
                            ((3, 34), 'left'), ((13, 300), None), ((500, 400), None)]:
            with self.subTest(point=point):
                self.assertEqual(controls.dock_edge(*point, area, (148, 44)), edge)

    def test_restored_tags_stay_on_the_selected_edge_and_remain_visible(self):
        area = (0, 28, 1600, 872)
        for edge, size, expected in [('left', (28, 44), (0, 200)),
                                     ('right', (28, 44), (1572, 200)),
                                     ('top', (60, 28), (500, 28)),
                                     ('bottom', (60, 28), (500, 872))]:
            with self.subTest(edge=edge):
                self.assertEqual(controls.position_for(dict(x=500, y=200, edge=edge), area, size), expected)
        self.assertEqual(controls.position_for(dict(x=9000, y=2000, edge='right'), area, (28, 44)), (1572, 856))

    def test_position_roundtrips_privately_and_replacement_failure_preserves_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'controls-position.json'
            position = dict(x=1300, y=500, edge='right')
            controls.save_position(path, position)
            saved = controls.load_position(path)
            self.assertEqual({key:saved[key] for key in position}, position)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            before = path.read_bytes()
            with mock.patch.object(controls.os, 'replace', side_effect=OSError('fixture interrupted replace')):
                with self.assertRaises(OSError): controls.save_position(path, dict(x=1, y=2, edge=None))
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(list(Path(temporary).iterdir()), [path])

    def test_corrupt_missing_or_invalid_position_uses_the_default(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'controls-position.json'
            self.assertIsNone(controls.load_position(path))
            for value in ['broken JSON', '{}', json.dumps(dict(x=True, y=4, edge=None)),
                          json.dumps(dict(x=1, y='2', edge=None)),
                          json.dumps(dict(x=2**63, y=3, edge=None)),
                          json.dumps(dict(x=1, y=3, edge='invalid'))]:
                path.write_text(value); path.chmod(0o600)
                with self.subTest(value=value): self.assertIsNone(controls.load_position(path))

    def test_symlink_and_nonprivate_files_are_not_read_or_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            secret = base / 'outside.json'
            controls.save_position(secret, dict(x=111, y=222, edge=None))
            self.assertIsNotNone(controls.load_position(secret))
            before = secret.read_bytes()
            path = base / 'controls-position.json'; path.symlink_to(secret)
            self.assertIsNone(controls.load_position(path))
            with self.assertRaises((RuntimeError, OSError, ValueError)):
                controls.save_position(path, dict(x=1, y=2, edge=None))
            self.assertTrue(path.is_symlink()); self.assertEqual(secret.read_bytes(), before)
            path.unlink(); path.write_text(before.decode()); path.chmod(0o644)
            self.assertIsNone(controls.load_position(path))
            with self.assertRaises((RuntimeError, OSError, ValueError)):
                controls.save_position(path, dict(x=1, y=2, edge=None))
            self.assertEqual(path.read_bytes(), before)

    @unittest.skipUnless(os.geteuid() == 0, 'Root-only disposable ownership fixture')
    def test_another_users_position_is_never_adopted(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'controls-position.json'
            controls.save_position(path, dict(x=1, y=2, edge=None))
            self.assertIsNotNone(controls.load_position(path))
            os.chown(path, 1000, 1000)
            self.assertIsNone(controls.load_position(path))
            with self.assertRaises((RuntimeError, OSError, ValueError)):
                controls.save_position(path, dict(x=10, y=20, edge=None))


class PresentationTests(unittest.TestCase):
    def test_automatic_mode_offers_takeover_without_starting_a_stopped_channel(self):
        for state, listening in [('active', True), ('inactive', False), ('failed', False)]:
            with self.subTest(state=state):
                result = controls.presentation(False, state, listening)
                self.assertEqual(result['label'], '接管浏览器')
                self.assertEqual(result['command'], 'takeover')
                self.assertTrue(result['tooltip'])

    def test_manual_is_safe_only_after_the_service_and_its_listener_are_stopped(self):
        for state in ('inactive', 'failed'):
            result = controls.presentation(True, state, False)
            self.assertEqual((result['label'], result['command']), ('交还 Codex', 'resume'))
        for state, listening in [('active', True), ('activating', False), ('deactivating', False), ('inactive', True)]:
            with self.subTest(state=state, listening=listening):
                result = controls.presentation(True, state, listening)
                self.assertEqual(result['command'], 'takeover')
                self.assertNotEqual(result['label'], '交还 Codex')

    def test_unknown_service_or_listener_does_not_allow_a_mode_change(self):
        for paused, state, listening in [(False, 'unknown', None), (True, 'unknown', False), (True, 'inactive', None)]:
            with self.subTest(paused=paused, state=state, listening=listening):
                self.assertIsNone(controls.presentation(paused, state, listening)['command'])


class PointerTests(unittest.TestCase):
    def test_a_drag_release_never_activates_even_if_motion_was_not_delivered(self):
        for moved_before, release_x in [(False, 120), (True, 100)]:
            with self.subTest(moved_before=moved_before):
                device=mock.Mock(); coordinates=[200, 300]
                instance=types.SimpleNamespace(pointer=dict(x=100, y=100, window_x=200, window_y=300,
                    moved=moved_before, device=device), edge=None,
                    get_position=lambda:tuple(coordinates), area=lambda:(0, 28, 1600, 872),
                    size=lambda:(148, 44), render=mock.Mock(), activate=mock.Mock(), place_and_save=mock.Mock())
                instance.move=lambda x,y:coordinates.__setitem__(slice(None),[x,y])
                instance.motion=lambda widget,event:controls.Controls.motion(instance,widget,event)
                event=types.SimpleNamespace(button=1, x_root=release_x, y_root=100, time=123)
                with mock.patch.object(controls.GLib,'idle_add') as idle:
                    self.assertTrue(controls.Controls.released(instance,None,event))
                instance.activate.assert_not_called()
                instance.render.assert_called_once()
                idle.assert_called_once_with(instance.place_and_save)
                device.ungrab.assert_called_once_with(123)
                self.assertIsNone(instance.pointer)

    def test_edge_tag_only_expands_even_while_busy_or_status_is_unknown(self):
        for worker in (None, mock.Mock()):
            instance=types.SimpleNamespace(edge='right', worker=worker, snapshot=None,
                render=mock.Mock(), place_and_save=mock.Mock())
            with self.subTest(worker=worker), mock.patch.object(controls.GLib,'idle_add') as idle, \
                 mock.patch.object(controls.subprocess,'Popen') as process:
                controls.Controls.activate(instance)
            self.assertIsNone(instance.edge)
            instance.render.assert_called_once()
            idle.assert_called_once_with(instance.place_and_save)
            process.assert_not_called()

    def test_an_unmoved_release_is_a_click_not_a_dock(self):
        instance=types.SimpleNamespace(pointer=dict(moved=False,device=mock.Mock()),
            motion=mock.Mock(), activate=mock.Mock(), render=mock.Mock())
        with mock.patch.object(controls.GLib,'idle_add') as idle:
            self.assertTrue(controls.Controls.released(instance,None,types.SimpleNamespace(button=1,time=5)))
        instance.activate.assert_called_once()
        instance.render.assert_not_called()
        idle.assert_not_called()


class ActivationTests(unittest.TestCase):
    def test_confirmation_does_not_use_a_snapshot_invalidated_while_the_dialog_was_open(self):
        instance=types.SimpleNamespace(edge=None, worker=None, dialog_open=False, config={},
            snapshot={'state':'active','listening':True}, set_accept_focus=mock.Mock(),
            stop_probe=mock.Mock(), render=mock.Mock())
        dialog=mock.Mock()
        def confirm():
            instance.snapshot=None
            return controls.Gtk.ResponseType.YES
        dialog.run.side_effect=confirm
        with mock.patch.object(controls,'manual',return_value=False), \
             mock.patch.object(controls.Gtk,'MessageDialog',return_value=dialog), \
             mock.patch.object(controls.subprocess,'Popen') as process:
            controls.Controls.activate(instance)
        process.assert_not_called()
        instance.stop_probe.assert_not_called()
        dialog.destroy.assert_called_once()
        self.assertEqual(instance.set_accept_focus.call_args_list,[mock.call(True),mock.call(False)])
        self.assertFalse(instance.dialog_open)

    def test_native_pointer_clicked_signal_cannot_repeat_release_activation(self):
        instance=types.SimpleNamespace(pointer=None,activate=mock.Mock())
        for event_type in (controls.Gdk.EventType.BUTTON_PRESS,controls.Gdk.EventType.BUTTON_RELEASE):
            with mock.patch.object(controls.Gtk,'get_current_event',return_value=types.SimpleNamespace(type=event_type)):
                controls.Controls.clicked(instance)
        instance.activate.assert_not_called()
        for event in (None,types.SimpleNamespace(type=controls.Gdk.EventType.KEY_RELEASE)):
            with mock.patch.object(controls.Gtk,'get_current_event',return_value=event):
                controls.Controls.clicked(instance)
        self.assertEqual(instance.activate.call_count,2)


if __name__ == '__main__':
    unittest.main()
