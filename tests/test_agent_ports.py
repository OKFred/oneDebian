"""Linux loopback socket checks; no existing service or fixed port is touched."""
import contextlib
import errno
import importlib.util
from pathlib import Path
import socket
import sys
import unittest


install = None
if sys.platform.startswith('linux'):
    spec = importlib.util.spec_from_file_location(
        'agent_install_ports', Path(__file__).resolve().parents[1] / 'agent/install.py')
    install = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = install
    spec.loader.exec_module(install)


@unittest.skipUnless(sys.platform.startswith('linux'), 'Linux TCP bind semantics')
class PortAvailabilityTests(unittest.TestCase):
    def test_unused_loopback_port_is_available(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        self.assertTrue(install.port_free(port))

    def test_active_listener_with_reuseaddr_is_unavailable(self):
        for address in ('127.0.0.1', '0.0.0.0'):
            with self.subTest(address=address):
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    listener.bind((address, 0))
                    listener.listen(1)
                    self.assertFalse(install.port_free(listener.getsockname()[1]))

    def test_established_session_without_listener_allows_rebinding(self):
        with contextlib.ExitStack() as sockets:
            listener = sockets.enter_context(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.settimeout(2)
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            address = listener.getsockname()
            client = sockets.enter_context(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
            client.settimeout(2)
            client.connect(address)
            accepted, _ = listener.accept()
            sockets.enter_context(accepted)
            accepted.settimeout(2)
            listener.close()

            # The old accepted connection is still established, just like the SSH
            # session used to uninstall a service after its listener has stopped.
            client.sendall(b'a')
            self.assertEqual(accepted.recv(1), b'a')
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as bare_probe:
                with self.assertRaises(OSError) as blocked:
                    bare_probe.bind(address)
                self.assertEqual(blocked.exception.errno, errno.EADDRINUSE)

            self.assertTrue(install.port_free(address[1]))
            accepted.sendall(b'b')
            self.assertEqual(client.recv(1), b'b')


if __name__ == '__main__':
    unittest.main()
