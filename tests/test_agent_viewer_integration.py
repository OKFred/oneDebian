"""Real websockify boundary test, using only a synthetic Unix-socket backend."""
import base64
from http.cookies import SimpleCookie
import importlib.util
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOKEN = 'a' * 43


def worker():
    directory, port, backend = sys.argv[2:]
    sys.path.insert(0, str(ROOT / 'agent'))
    import runtime
    runtime.ROOT = ROOT / 'agent'
    runtime.run_dir = lambda _: Path(backend).parent
    proxy = runtime.make_proxy(dict(viewer_port=int(port)), TOKEN)
    proxy.unix_target = backend
    proxy.web = directory
    proxy.start_server()


def free_port():
    with socket.socket() as stream:
        stream.bind(('127.0.0.1', 0))
        return stream.getsockname()[1]


@unittest.skipUnless(sys.platform == 'linux' and importlib.util.find_spec('websockify'), 'Debian websockify integration')
class ViewerBoundaryTests(unittest.TestCase):
    def test_authenticated_http_and_websocket_and_rejected_cross_site_access(self):
        accepted = []
        class Backend(socketserver.BaseRequestHandler):
            def handle(self):
                accepted.append(True)
                self.request.sendall(b'RFB 003.008\n')
                self.request.settimeout(1)
                try:
                    self.request.recv(128)
                except OSError:
                    pass
        with tempfile.TemporaryDirectory(prefix='od-viewer-') as temporary:
            directory = Path(temporary)
            (directory / 'vnc.html').write_text('synthetic noVNC')
            path = str(directory / 'vnc.sock')
            backend = socketserver.ThreadingUnixStreamServer(path, Backend)
            backend.daemon_threads = True
            thread = threading.Thread(target=backend.serve_forever, daemon=True)
            thread.start()
            port = free_port()
            proxy = subprocess.Popen([sys.executable, __file__, '--worker', temporary, str(port), path],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                deadline = time.monotonic() + 15
                while True:
                    if proxy.poll() is not None:
                        self.fail('Synthetic viewer proxy exited before listening')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.2):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            self.fail('Synthetic viewer proxy did not listen')
                        time.sleep(.1)

                host = f'127.0.0.1:{port}'
                origin = 'http://' + host
                def request(target='/vnc.html', hosts=None, origins=(), cookie=None, websocket=False,
                            method='GET', body=None):
                    with socket.create_connection(('127.0.0.1', port), timeout=3) as client:
                        values = [f'{method} {target} HTTP/1.1']
                        values += ['Host: ' + item for item in ([host] if hosts is None else hosts)]
                        values += ['Origin: ' + item for item in origins]
                        if cookie:
                            values.append('Cookie: ' + cookie)
                        if websocket:
                            values += ['Upgrade: websocket', 'Connection: Upgrade', 'Sec-WebSocket-Version: 13',
                                       'Sec-WebSocket-Key: ' + base64.b64encode(os.urandom(16)).decode(),
                                       'Sec-WebSocket-Protocol: binary']
                        else:
                            values.append('Connection: close')
                        encoded = b'' if body is None else json.dumps(body).encode()
                        if body is not None:
                            values += ['Content-Type: application/json', 'Content-Length: ' + str(len(encoded))]
                        client.sendall(('\r\n'.join(values) + '\r\n\r\n').encode() + encoded)
                        response = b''
                        while b'\r\n\r\n' not in response:
                            block = client.recv(4096)
                            if not block:
                                break
                            response += block
                        return response.split(b'\r\n\r\n', 1)[0]

                public = request('/')
                self.assertIn(b' 200 ', public)
                for target in ['/vnc.html', '/app/ui.js', '/websockify']:
                    header = request(target)
                    self.assertIn(b' 401 ', header)
                    self.assertIn(b'X-Frame-Options: DENY', header)
                    self.assertIn(b"frame-ancestors 'none'", header)
                for hosts in [[], ['evil.test'], [host, host]]:
                    self.assertIn(b' 403 ', request('/', hosts=hosts))
                for origins in [[], ['null'], ['https://evil.test'], [origin, origin]]:
                    self.assertIn(b' 403 ', request('/auth', origins=origins, method='POST', body={'token': TOKEN}))
                for token in ['wrong', '非ASCII']:
                    self.assertIn(b' 403 ', request('/auth', origins=[origin], method='POST', body={'token': token}))
                self.assertIn(b' 401 ', request('/websockify', origins=[origin], websocket=True))
                self.assertEqual(accepted, [], 'Rejected requests reached the VNC backend')
                header = request('/auth', origins=[origin], method='POST', body={'token': TOKEN})
                self.assertIn(b' 204 ', header)
                self.assertIn(b'HttpOnly', header)
                self.assertIn(b'SameSite=Strict', header)
                value = next(line.split(b': ', 1)[1].decode() for line in header.split(b'\r\n')
                             if line.lower().startswith(b'set-cookie:'))
                cookie = SimpleCookie(value)
                cookie_name = 'onedebian_viewer_' + str(port)
                self.assertNotEqual(cookie[cookie_name].value, TOKEN)
                auth = cookie_name + '=' + cookie[cookie_name].value
                self.assertIn(b' 200 ', request(cookie=auth))
                self.assertIn(b' 403 ', request('/websockify', cookie=auth, websocket=True, origins=['http://evil.test']))
                self.assertIn(b' 101 ', request('/websockify', cookie=auth, websocket=True, origins=[origin]))
                end = time.monotonic() + 2
                while not accepted and time.monotonic() < end:
                    time.sleep(.05)
                self.assertEqual(len(accepted), 1)
            finally:
                if proxy.poll() is None:
                    os.killpg(proxy.pid, 15)
                    try:
                        proxy.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(proxy.pid, 9)
                        proxy.wait(timeout=3)
                backend.shutdown()
                backend.server_close()
                thread.join(timeout=3)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--worker':
        worker()
    else:
        unittest.main()
