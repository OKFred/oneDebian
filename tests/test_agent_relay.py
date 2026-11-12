"""Linux pipe/PTY relay fixtures; never changes a real workstation service or configuration."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

if sys.platform != 'linux':
    raise unittest.SkipTest('The stdio relay requires Linux user identity and file descriptors')

if len(sys.argv) > 1 and sys.argv[1] == '--worker':
    import pwd
    directory = Path(sys.argv[2])
    if sys.argv[3] != '--root':
        account = pwd.getpwnam('nobody')
        os.setgroups([]); os.setgid(account.pw_gid); os.setuid(account.pw_uid)
    sys.path.insert(0,str(directory))
    import runtime
    import relay
    runtime.CONFIG = directory / 'config.json'
    relay.HEARTBEAT_SECONDS = .05
    raise SystemExit(relay.main(sys.argv[4:]))

ROOT = Path(__file__).resolve().parents[1]


class Backend:
    def __init__(self, handler):
        self.handler = handler; self.stop = threading.Event(); self.closed = threading.Event()
        self.connection = None; self.error = None
        self.listener = socket.socket(socket.AF_INET,socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1',0)); self.listener.listen(1); self.listener.settimeout(.1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self.serve,daemon=True); self.thread.start()

    def serve(self):
        try:
            while not self.stop.is_set():
                try:
                    connection,_ = self.listener.accept()
                    break
                except socket.timeout:
                    continue
            else:
                return
            self.connection = connection
            with connection:
                connection.settimeout(10)
                self.handler(connection)
        except OSError as error:
            if not self.stop.is_set(): self.error = error
        except Exception as error:
            self.error = error
        finally:
            self.closed.set()

    def close(self):
        self.stop.set()
        if self.connection:
            with contextlib.suppress(OSError): self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
        self.listener.close(); self.thread.join(timeout=2)


@unittest.skipUnless(os.geteuid() == 0,'Root-owned configuration and ordinary-user subprocess fixtures')
class RelayTests(unittest.TestCase):
    def setUp(self):
        import pwd
        self.account = pwd.getpwnam('nobody')
        self.temporary = tempfile.TemporaryDirectory(prefix='onedebian-relay-tests-')
        self.directory = Path(self.temporary.name); self.directory.chmod(0o755)
        for name in ('runtime.py','relay.py'):
            target = self.directory / name; target.write_bytes((ROOT/'agent'/name).read_bytes()); target.chmod(0o644)
        self.worker = self.directory/'worker.py'; self.worker.write_bytes(Path(__file__).read_bytes()); self.worker.chmod(0o644)
        self.backends = []; self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=3)
            for pipe in (child.stdin,child.stdout,child.stderr):
                if pipe: pipe.close()
        for backend in self.backends: backend.close()
        self.temporary.cleanup()

    def backend(self, handler):
        result = Backend(handler); self.backends.append(result); return result

    def config(self, port, **changes):
        other = next(p for p in (16080,18931,19222) if p != port)
        third = next(p for p in (16080,18931,19222) if p not in (port,other))
        document = dict(user=self.account.pw_name,home=self.account.pw_dir,display=':999',
                        viewer_port=port,mcp_port=other,cdp_port=third)
        document.update(changes)
        path = self.directory/'config.json'
        if path.is_symlink(): path.unlink()
        path.write_text(json.dumps(document)); path.chmod(0o644)
        return path

    def start(self, choice='viewer', root=False, stdin=subprocess.PIPE):
        child = subprocess.Popen([sys.executable,str(self.worker),'--worker',str(self.directory),
                                  '--root' if root else '--ordinary',choice],
                                 stdin=stdin,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        self.children.append(child); return child

    def ready(self, child):
        with selectors.DefaultSelector() as poller:
            poller.register(child.stderr,selectors.EVENT_READ)
            self.assertTrue(poller.select(10),'Relay did not produce a bounded startup result')
        self.assertEqual(child.stderr.readline(),b'ONEDEBIAN_RELAY_READY\n')

    def test_binary_echo_uses_configured_loopback_and_clean_stdout(self):
        def echo(connection):
            while data := connection.recv(16384): connection.sendall(data)
        server = self.backend(echo); self.config(server.port)
        child = self.start(); self.ready(child)
        payload = bytes(range(256))*4096
        output,error = child.communicate(payload,timeout=20)
        self.assertEqual(child.returncode,0); self.assertEqual(output,payload)
        self.assertEqual(error.strip(),b'')

    def test_mcp_choice_uses_only_the_configured_mcp_port(self):
        server = self.backend(lambda connection: connection.sendall(b'MCP\x00\n'))
        self.config(server.port,mcp_port=server.port,viewer_port=16080)
        child = self.start('mcp'); self.ready(child)
        output,error = child.communicate(timeout=10)
        self.assertEqual(output,b'MCP\x00\n'); self.assertEqual(child.returncode,0)
        self.assertEqual(error.strip(),b'')

    def test_stdin_halfclose_drains_the_complete_late_backend_response(self):
        request = b'owned request\x00'*8192; response = bytes(range(256))*1024
        def late_response(connection):
            received = bytearray()
            while data := connection.recv(16384): received.extend(data)
            if bytes(received) != request: raise AssertionError('Request was truncated before half-close')
            time.sleep(.1); connection.sendall(response)
        server = self.backend(late_response); self.config(server.port)
        child = self.start(); self.ready(child)
        output,error = child.communicate(request,timeout=20)
        self.assertEqual(output,response); self.assertEqual(child.returncode,0)
        self.assertEqual(error.strip(),b''); self.assertIsNone(server.error)

    def test_backend_eof_exits_even_when_client_stdin_remains_open(self):
        server = self.backend(lambda connection: connection.sendall(b'done\x00'))
        self.config(server.port); child = self.start(); self.ready(child)
        child.wait(timeout=5); self.assertEqual(child.returncode,0)
        self.assertEqual(child.stdout.read(),b'done\x00')

    def test_slow_stdout_consumer_does_not_accumulate_the_response_in_memory(self):
        chunk = b'x'*16384; count = 1280
        def large_response(connection):
            while connection.recv(16384): pass
            for _ in range(count): connection.sendall(chunk)
        server = self.backend(large_response); self.config(server.port)
        child = self.start(); self.ready(child)
        def resident_kib():
            status = Path('/proc',str(child.pid),'status').read_text()
            return int(next(line.split()[1] for line in status.splitlines() if line.startswith('VmRSS:')))
        baseline = resident_kib()
        child.stdin.close(); child.stdin = None
        time.sleep(.25)
        self.assertLess(resident_kib()-baseline,4096,'Relay accumulated a slow-consumer response')
        output,error = child.communicate(timeout=20)
        self.assertEqual(len(output),len(chunk)*count)
        self.assertEqual(output,chunk*count); self.assertEqual(child.returncode,0)
        self.assertEqual(error.strip(),b'')

    def test_live_idle_stream_is_not_timed_out_and_host_disappearance_closes_it(self):
        server = self.backend(lambda connection: connection.recv(1))
        self.config(server.port); child = self.start(); self.ready(child)
        time.sleep(.2)
        self.assertIsNone(child.poll(),'A live idle stream must not have an arbitrary deadline')
        child.stderr.close(); child.stderr = None
        child.wait(timeout=3)
        self.assertEqual(child.returncode,0)
        self.assertTrue(server.closed.wait(2),'Host disappearance left an idle backend connection open')

    def test_sigterm_closes_only_its_connection(self):
        server = self.backend(lambda connection: connection.recv(1))
        self.config(server.port); child = self.start(); self.ready(child)
        child.send_signal(signal.SIGTERM)
        output,error = child.communicate(timeout=5)
        self.assertEqual(child.returncode,128+signal.SIGTERM)
        self.assertEqual(output,b''); self.assertEqual(error.strip(),b'')
        self.assertTrue(server.closed.wait(2))

    def test_invalid_service_and_backend_errors_never_echo_user_input(self):
        self.config(65534)
        for value in ('cdp','--host','secret-'*500):
            with self.subTest(value_length=len(value)):
                child = self.start(value); output,error = child.communicate(timeout=10)
                self.assertEqual(child.returncode,2); self.assertEqual(output,b'')
                self.assertLess(len(error),128); self.assertNotIn(b'secret-',error)
                self.assertNotIn(b'ONEDEBIAN_RELAY_READY',error)
        with socket.socket() as unused:
            unused.bind(('127.0.0.1',0)); port = unused.getsockname()[1]
            self.config(port); child = self.start(); output,error = child.communicate(timeout=10)
        self.assertEqual(child.returncode,3); self.assertEqual(output,b'')
        self.assertEqual(error,b'ONEDEBIAN_RELAY_ERROR backend-unavailable\n')

    def test_root_and_unsafe_configuration_are_rejected_before_connecting(self):
        self.config(65534)
        child = self.start(root=True); output,error = child.communicate(timeout=10)
        self.assertEqual(child.returncode,2); self.assertEqual(output,b'')
        self.assertEqual(error,b'ONEDEBIAN_RELAY_ERROR configuration\n')
        for fault in ('symlink','writable','nonroot-owner','invalid-port'):
            with self.subTest(fault=fault):
                path = self.config(65534)
                os.chown(path,0,0)
                if fault == 'symlink':
                    other = self.directory/'real-config.json'; other.write_bytes(path.read_bytes()); other.chmod(0o644)
                    path.unlink(); path.symlink_to(other)
                elif fault == 'writable': path.chmod(0o666)
                elif fault == 'nonroot-owner': os.chown(path,self.account.pw_uid,self.account.pw_gid)
                else: self.config(0)
                child = self.start(); output,error = child.communicate(timeout=10)
                self.assertEqual(child.returncode,2); self.assertEqual(output,b'')
                self.assertEqual(error,b'ONEDEBIAN_RELAY_ERROR configuration\n')

    def test_pty_stdin_preserves_binary_bytes_and_restores_terminal_modes(self):
        import pty
        import termios
        payload = bytes(range(256))*4
        def exact_echo(connection):
            received = bytearray()
            while len(received) < len(payload):
                data = connection.recv(len(payload)-len(received))
                if not data: raise OSError('PTY request ended before all bytes arrived')
                received.extend(data)
            connection.sendall(received)
        server = self.backend(exact_echo); self.config(server.port)
        master,slave = pty.openpty(); original = termios.tcgetattr(slave)
        try:
            child = self.start(stdin=slave); self.ready(child)
            os.write(master,payload)
            output,error = child.communicate(timeout=10)
            self.assertEqual(output,payload); self.assertEqual(child.returncode,0)
            self.assertEqual(error.strip(),b'')
            self.assertEqual(termios.tcgetattr(slave),original)
        finally:
            os.close(master); os.close(slave)


if __name__ == '__main__':
    unittest.main()
