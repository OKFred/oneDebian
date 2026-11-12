#!/usr/bin/env python3
"""Verify the owned workstation; UI input requires --browser, GPU drawing --gpu."""
import argparse
import base64
import ctypes
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import pwd
import re
import selectors
import signal
import stat
import subprocess
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from runtime import gpu_backend, graphics_environment

CONFIG = Path('/etc/onedebian-agent/config.json')
PROBE_CONFIG = Path('/run/onedebian-agent-gpu/config.json')
VERSIONS = Path('/etc/onedebian-agent/versions.json')
HELPERS = Path(__file__).resolve().parent
SOFTWARE = re.compile(r'llvmpipe|softpipe|swiftshader|lavapipe|software|\bwarp\b|basic render|virgl|svga3d', re.I)
WEBGL_JS = r'''(() => {
  function draw(kind) {
    const canvas = document.createElement('canvas'); canvas.width=8; canvas.height=8;
    const gl=canvas.getContext(kind, {preserveDrawingBuffer:true, antialias:false});
    if (!gl) return {passed:false, reason:'Context unavailable'};
    const debug=gl.getExtension('WEBGL_debug_renderer_info');
    const renderer=debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
    const shader=(kind, source) => {
      const s=gl.createShader(kind); gl.shaderSource(s,source); gl.compileShader(s);
      if (!gl.getShaderParameter(s,gl.COMPILE_STATUS)) throw Error(gl.getShaderInfoLog(s)); return s;
    };
    const vs=shader(gl.VERTEX_SHADER,'attribute vec2 p;void main(){gl_Position=vec4(p,0.0,1.0);}');
    const fs=shader(gl.FRAGMENT_SHADER,'precision mediump float;void main(){gl_FragColor=vec4(0.0,1.0,0.0,1.0);}');
    const program=gl.createProgram(); gl.attachShader(program,vs); gl.attachShader(program,fs); gl.linkProgram(program);
    if (!gl.getProgramParameter(program,gl.LINK_STATUS)) throw Error(gl.getProgramInfoLog(program));
    gl.useProgram(program); const buffer=gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
    gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),gl.STATIC_DRAW);
    const loc=gl.getAttribLocation(program,'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc,2,gl.FLOAT,false,0,0);
    gl.viewport(0,0,8,8); gl.clearColor(1,0,1,1); gl.clear(gl.COLOR_BUFFER_BIT); gl.drawArrays(gl.TRIANGLES,0,3); gl.finish();
    const pixel=new Uint8Array(4); gl.readPixels(4,4,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);
    const passed=gl.getError()===gl.NO_ERROR && pixel.every((x,i)=>x===[0,255,0,255][i]);
    gl.deleteBuffer(buffer); gl.deleteProgram(program); gl.deleteShader(vs); gl.deleteShader(fs);
    return {passed,renderer,pixel:Array.from(pixel)};
  }
  return {webgl:draw('webgl'),webgl2:draw('webgl2')};
})()'''


def need(condition, message):
    if not condition:
        raise RuntimeError(message)


def hardware_renderer(value):
    return bool(value and value.strip() and not SOFTWARE.search(value))


def d3d12_renderer(value):
    return hardware_renderer(value) and bool(re.search(r'\bD3D12\s*\(\s*Intel\b', value, re.I))


def d3d12_evidence(process):
    fds = []
    for fd in (process / 'fd').iterdir():
        try:
            if os.path.realpath(fd) == '/dev/dxg':
                fds.append(fd.name)
        except OSError:
            continue
    libraries = sorted({line.split()[-1] for line in (process / 'maps').read_text().splitlines()
                        if line.split() and Path(line.split()[-1]).name in {'libd3d12.so','libdxcore.so'}})
    return dict(device='/dev/dxg',fds=fds,libraries=libraries,
                passed=bool(fds and {'libd3d12.so','libdxcore.so'} <= {Path(path).name for path in libraries}))


def probe_config():
    for path in (PROBE_CONFIG.parent, PROBE_CONFIG):
        info = path.lstat()
        need(info.st_uid == 0 and not info.st_mode & 0o022 and
             (stat.S_ISDIR(info.st_mode) if path == PROBE_CONFIG.parent else stat.S_ISREG(info.st_mode)),
             'Untrusted GPU probe configuration')
    need(PROBE_CONFIG.stat().st_size <= 65536, 'GPU probe configuration is too large')
    config = json.loads(PROBE_CONFIG.read_text())
    need(config.get('probe_unit') == 'onedebian-agent-gpu-probe.service', 'Invalid GPU probe service')
    base = Path(config['home']) / '.local/share/onedebian-agent/probes'
    profile = Path(config.get('probe_profile',''))
    need(profile.is_absolute() and profile != base and profile.resolve().is_relative_to(base.resolve()),
         'GPU probe must use a temporary profile')
    return config


class NoControlRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def local_client(*handlers):
    # Control traffic and the local viewer token must never use environment proxies.
    return urllib.request.build_opener(urllib.request.ProxyHandler({}),NoControlRedirects(),*handlers)


def local_open(request, timeout=8):
    url = request.full_url if isinstance(request,urllib.request.Request) else request
    parsed = urllib.parse.urlsplit(url)
    need(parsed.scheme == 'http' and parsed.hostname == '127.0.0.1' and not parsed.username
         and not parsed.password and parsed.port and 1024 <= parsed.port <= 65535 and not parsed.fragment,
         'Only the configured loopback control endpoint is permitted')
    return local_client().open(request,timeout=timeout)


def parse_mcp_response(data, content_type):
    if 'text/event-stream' in content_type:
        messages = []
        for block in data.replace('\r\n', '\n').split('\n\n'):
            payload = '\n'.join(line[5:].lstrip() for line in block.splitlines() if line.startswith('data:'))
            if payload:
                messages.append(json.loads(payload))
        need(messages, 'MCP stream did not contain a response')
        return messages[-1]
    return json.loads(data)


class MCP:
    def __init__(self, port):
        self.url = f'http://127.0.0.1:{port}/mcp'
        self.session = None
        self.counter = 0
        self.protocol = '2025-03-26'

    def request(self, method, params=None, notification=False):
        self.counter += 1
        document = dict(jsonrpc='2.0', method=method)
        if not notification:
            document['id'] = self.counter
        if params is not None:
            document['params'] = params
        headers = {'Content-Type':'application/json', 'Accept':'application/json, text/event-stream',
                   'MCP-Protocol-Version':self.protocol}
        if self.session:
            headers['Mcp-Session-Id'] = self.session
        req = urllib.request.Request(self.url, json.dumps(document).encode(), headers, method='POST')
        with local_open(req, timeout=120) as response:
            self.session = response.headers.get('Mcp-Session-Id', self.session)
            body = response.read().decode()
            if notification or response.status == 202:
                return None
            decoded = parse_mcp_response(body, response.headers.get('Content-Type', ''))
        need(decoded.get('id') == self.counter, 'MCP response ID mismatch')
        need('error' not in decoded, 'MCP request failed: ' + str(decoded.get('error', '')))
        return decoded.get('result')

    def initialize(self):
        info = self.request('initialize', {'protocolVersion':self.protocol, 'capabilities':{},
            'clientInfo':{'name':'oneDebian-verification', 'version':'1'}})
        self.protocol = info['protocolVersion']
        self.request('notifications/initialized', notification=True)

    def call(self, name, arguments):
        result = self.request('tools/call', {'name':name, 'arguments':arguments})
        if result.get('isError'):
            raise RuntimeError('MCP tool failed: ' + name + ': ' + text_content(result)[:2000])
        return result


def snapshot_ref(snapshot, role, name):
    expression = r'\b' + re.escape(role) + r' "' + re.escape(name) + r'"[^\n]*\[ref=([^\]\s]+)\]'
    found = re.findall(expression, snapshot)
    need(len(found) == 1, f'Expected exactly one {role} named {name} in owned fixture')
    return found[0]


def text_content(result):
    return '\n'.join(item['text'] for item in result.get('content', []) if item.get('type') == 'text')


def process_args(process):
    arguments = (process / 'cmdline').read_bytes().rstrip(b'\0').split(b'\0')
    # Chromium can rewrite its process title into one space-separated argv entry.
    return arguments[0].split() if len(arguments) == 1 else arguments


def session_boot_id(proc=Path('/proc')):
    kernel = (proc / 'sys/kernel/random/boot_id').read_text().strip()
    # WSL distributions share the kernel boot UUID, but each has its own PID 1 lifetime.
    start = (proc / '1/stat').read_text().rsplit(')',1)[1].split()[19]
    need(start.isdecimal(),'Invalid PID 1 start time')
    return str(uuid.uuid5(uuid.NAMESPACE_OID,kernel + ':' + start))


def native_egl(render_node='', backend='drm'):
    """Owned native ES2 shader draw with evidence for the selected backend."""
    gpu_backend(dict(gpu_backend=backend, render_node=render_node))
    need(backend != 'software', 'Native GPU proof requires a hardware backend')
    P, I, U, F = ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_float
    egl = ctypes.CDLL('libEGL.so.1'); gl = ctypes.CDLL('libGLESv2.so.2')
    def bind(lib, name, restype, argtypes):
        fn = getattr(lib, name); fn.restype = restype; fn.argtypes = argtypes
        return fn
    get_display = bind(egl, 'eglGetDisplay', P, [P])
    initialize = bind(egl, 'eglInitialize', U, [P, ctypes.POINTER(I), ctypes.POINTER(I)])
    choose = bind(egl, 'eglChooseConfig', U, [P, ctypes.POINTER(I), ctypes.POINTER(P), I, ctypes.POINTER(I)])
    context_fn = bind(egl, 'eglCreateContext', P, [P, P, P, ctypes.POINTER(I)])
    surface_fn = bind(egl, 'eglCreatePbufferSurface', P, [P, P, ctypes.POINTER(I)])
    current = bind(egl, 'eglMakeCurrent', U, [P, P, P, P])
    display = context = surface = None
    try:
        display = get_display(None); major = I(); minor = I()
        need(display and initialize(display, ctypes.byref(major), ctypes.byref(minor)), 'Native X11 EGL initialization failed')
        need(bind(egl, 'eglBindAPI', U, [U])(0x30A0), 'EGL ES API unavailable')
        config = P(); count = I()
        attrs = (I * 13)(0x3033,1,0x3040,4,0x3024,8,0x3023,8,0x3022,8,0x3021,8,0x3038)
        need(choose(display, attrs, ctypes.byref(config), 1, ctypes.byref(count)) and count.value, 'EGL ES2 pbuffer unavailable')
        context = context_fn(display, config, None, (I * 3)(0x3098,2,0x3038))
        surface = surface_fn(display, config, (I * 5)(0x3057,8,0x3056,8,0x3038))
        need(context and surface and current(display,surface,surface,context), 'EGL make-current failed')
        get_string = bind(gl,'glGetString',ctypes.c_char_p,[U])
        renderer = (get_string(0x1F01) or b'').decode(errors='replace')
        need(d3d12_renderer(renderer) if backend == 'd3d12' else hardware_renderer(renderer),
             'Native EGL is using software or the wrong GPU backend: ' + renderer)
        create = bind(gl,'glCreateShader',U,[U]); source = bind(gl,'glShaderSource',None,[U,I,ctypes.POINTER(ctypes.c_char_p),ctypes.POINTER(I)])
        compile_shader = bind(gl,'glCompileShader',None,[U]); shader_ok = bind(gl,'glGetShaderiv',None,[U,U,ctypes.POINTER(I)])
        shaders = []
        for kind, code in [(0x8B31,b'attribute vec2 p;void main(){gl_Position=vec4(p,0.0,1.0);}'),
                           (0x8B30,b'precision mediump float;void main(){gl_FragColor=vec4(0.0,1.0,0.0,1.0);}')]:
            handle = create(kind); shaders.append(handle); string = ctypes.c_char_p(code)
            source(handle,1,ctypes.byref(string),None); compile_shader(handle); okay = I(); shader_ok(handle,0x8B81,ctypes.byref(okay))
            need(okay.value, 'Native EGL shader compile failed')
        program = bind(gl,'glCreateProgram',U,[])()
        for handle in shaders:
            bind(gl,'glAttachShader',None,[U,U])(program,handle)
        bind(gl,'glBindAttribLocation',None,[U,U,ctypes.c_char_p])(program,0,b'p')
        bind(gl,'glLinkProgram',None,[U])(program); okay = I()
        bind(gl,'glGetProgramiv',None,[U,U,ctypes.POINTER(I)])(program,0x8B82,ctypes.byref(okay))
        need(okay.value, 'Native EGL shader link failed')
        bind(gl,'glUseProgram',None,[U])(program)
        vertices = (F * 6)(-1,-1,3,-1,-1,3)
        bind(gl,'glEnableVertexAttribArray',None,[U])(0)
        bind(gl,'glVertexAttribPointer',None,[U,I,U,U,I,P])(0,2,0x1406,0,0,ctypes.cast(vertices,P))
        bind(gl,'glViewport',None,[I,I,I,I])(0,0,8,8)
        bind(gl,'glClearColor',None,[F,F,F,F])(1,0,1,1); bind(gl,'glClear',None,[U])(0x4000)
        bind(gl,'glDrawArrays',None,[U,I,I])(4,0,3); bind(gl,'glFinish',None,[])()
        pixel = (ctypes.c_ubyte * 4)()
        bind(gl,'glReadPixels',None,[I,I,I,I,U,U,P])(4,4,1,1,0x1908,0x1401,pixel)
        need(bind(gl,'glGetError',U,[])() == 0 and list(pixel) == [0,255,0,255], 'Native EGL shader readback failed')
        if backend == 'd3d12':
            evidence = d3d12_evidence(Path('/proc/self'))
            need(evidence['passed'], 'Native EGL lacks DXG and D3D12/DXCore evidence')
        else:
            fds = [fd.name for fd in Path('/proc/self/fd').iterdir() if os.path.realpath(fd) == render_node]
            need(fds, 'Native EGL did not open the selected render node')
            evidence = dict(fds=fds)
        return dict(evidence, passed=True, backend=backend, renderer=renderer, render_node=render_node,
                    pixel=list(pixel), egl=f'{major.value}.{minor.value}')
    finally:
        if display:
            current(display,None,None,None)
            if surface:
                bind(egl,'eglDestroySurface',U,[P,P])(display,surface)
            if context:
                bind(egl,'eglDestroyContext',U,[P,P])(display,context)
            bind(egl,'eglTerminate',U,[P])(display)


class Verifier:
    def __init__(self, config, versions):
        self.cfg = config; self.versions = versions
        for key in ('viewer_port','mcp_port','cdp_port'):
            need(type(config[key]) is int and 1024 <= config[key] <= 65535,'Invalid loopback control port')
        account = pwd.getpwnam(config['user']); self.uid = account.pw_uid
        need(self.uid != 0,'The browser workstation must use an ordinary account')
        self.home = Path(config['home']); self.data = self.home / '.local/share/onedebian-agent'
        self.run = Path('/run/user') / str(self.uid)
        need(os.geteuid() in {0,self.uid}, 'Run as root or the configured agent user')
        self.env = dict(PATH='/usr/local/bin:/usr/bin:/bin', HOME=str(self.home), USER=account.pw_name,
            LOGNAME=account.pw_name, XDG_RUNTIME_DIR=str(self.run), DBUS_SESSION_BUS_ADDRESS=f'unix:path={self.run}/bus',
            DISPLAY=config.get('display',':10'), XAUTHORITY=str(self.run / 'onedebian-agent/Xauthority'))
        self.env.update(graphics_environment(config))
        self.report = dict(passed=False, checks=[], browser_input_issued=False,
                           hardware_required=False, warnings=[],
                           manual_checks={'noVNC_picture_and_keyboard':'not_yet_verified',
                                          'manual_handoff_and_resume':'not_yet_verified',
                                          'cold_boot_profile_and_keyring':'not_yet_verified'})

    def user_command(self, command):
        return (['/usr/sbin/runuser','-u',self.cfg['user'],'--'] if os.geteuid() == 0 else []) + command

    def manual(self):
        return os.path.lexists(self.data / 'manual')

    def user(self, command, timeout=45, **kwargs):
        text = kwargs.pop('text',True)
        return subprocess.run(self.user_command(command), env=self.env, text=text, capture_output=True,
                              check=True, timeout=timeout, **kwargs)

    def node_command(self, arguments):
        fnm_dir = str(self.home / '.local/share/fnm')
        return [fnm_dir + '/fnm','--fnm-dir',fnm_dir,'exec','--using=' + self.versions['node'],'node'] + arguments

    def cdp(self, method, params=None, endpoint=None):
        request = dict(port=self.cfg['cdp_port'], method=method, params=params or {}, endpoint=endpoint)
        return json.loads(self.user(self.node_command([str(HELPERS / 'cdp-probe.mjs'),json.dumps(request)]), timeout=30).stdout)

    def check(self, name, action):
        try:
            detail = action(); self.report['checks'].append(dict(name=name,passed=True,detail=detail))
            return detail
        except (Exception, SystemExit) as error:
            self.report['checks'].append(dict(name=name,passed=False,error=str(error)))
            return None

    def wait_check(self, action, timeout=40):
        deadline = time.monotonic() + timeout
        while True:
            try:
                return action()
            except (OSError,RuntimeError,subprocess.SubprocessError) as error:
                if time.monotonic() >= deadline:
                    raise RuntimeError('Service readiness timed out: ' + str(error)) from error
                time.sleep(0.5)

    def version_check(self):
        expected = self.versions['node']
        need(re.fullmatch(r'v26\.\d+\.\d+', expected), 'Expected pinned Node 26 version')
        noninteractive = self.user(self.node_command(['--version'])).stdout.strip()
        interactive = self.user(['/bin/bash','-ic','node --version']).stdout.strip().splitlines()[-1]
        wrapper = self.user([str(self.home / '.local/bin/node'),'--version']).stdout.strip()
        need(noninteractive == interactive == wrapper == expected, 'Interactive/noninteractive/wrapper fnm Node version mismatch')
        result = dict(expected=expected,interactive=interactive,noninteractive=noninteractive,wrapper=wrapper)
        if self.versions.get('pnpm'):
            pnpm = self.user([str(self.home / '.local/bin/pnpm'), '--version']).stdout.strip()
            shell = self.user(['/bin/bash', '-ic', 'pnpm --version']).stdout.strip().splitlines()[-1]
            need(pnpm == shell == self.versions['pnpm'], 'Recorded global pnpm version mismatch')
            result['pnpm'] = pnpm
        return result

    def service_check(self):
        result = {}
        for part in ['desktop','chromium','novnc','mcp']:
            unit = f'onedebian-agent-{part}.service'
            command = ['systemctl'] + ([] if part in {'desktop','chromium'} else ['--user']) + ['show',unit,'-p','ActiveState,MainPID']
            raw = (subprocess.run(command, capture_output=True, text=True, check=True, timeout=15).stdout
                   if part in {'desktop','chromium'} else self.user(command,timeout=15).stdout)
            status = dict(line.split('=',1) for line in raw.splitlines() if '=' in line)
            manual = part == 'mcp' and self.manual()
            need((status.get('ActiveState') != 'active' and status.get('MainPID') == '0') if manual else
                 (status.get('ActiveState') == 'active' and int(status.get('MainPID','0')) > 0), 'Unexpected service state: ' + unit)
            if not manual:
                pid = int(status['MainPID'])
                need(Path('/proc',str(pid)).stat().st_uid == self.uid, 'Service did not run as agent: ' + unit)
                if part == 'mcp':
                    candidates = [pid] + descendants(pid)
                    nodes = [p for p in candidates if Path('/proc',str(p),'exe').resolve().name == 'node']
                    need(nodes, 'MCP has no Node runtime process')
                    for node in nodes:
                        executable = Path('/proc',str(node),'exe').resolve()
                        need(self.versions['node'].removeprefix('v') in str(executable) and str(executable).startswith(str(self.home / '.local/share/fnm') + '/'),
                             'MCP is not using the pinned fnm Node runtime')
                    status['node_pids'] = nodes
            result[part] = status
        need((self.run / 'bus').exists(), 'Normal user D-Bus is absent')
        return result

    def listener_check(self):
        raw = subprocess.run(['ss','-H','-ltn'],text=True,capture_output=True,check=True,timeout=10).stdout
        expected = {str(self.cfg[key]) for key in ['viewer_port','cdp_port','mcp_port']}
        manual = self.manual()
        active = {}
        for line in raw.splitlines():
            address = line.split()[3]; host,_,port = address.rpartition(':')
            if port in expected:
                need(host in {'127.0.0.1','[::1]','::1'}, 'Managed port listens outside loopback: ' + address)
                active.setdefault(port,[]).append(host)
        required = expected - ({str(self.cfg['mcp_port'])} if manual else set())
        need(required <= active.keys(), 'Expected loopback ports are missing')
        need(not manual or str(self.cfg['mcp_port']) not in active, 'MCP port remains open in manual mode')
        return active

    def viewer_check(self):
        base = f'http://127.0.0.1:{self.cfg["viewer_port"]}'
        def request(path, headers=None, data=None):
            try:
                response = local_open(urllib.request.Request(base + path,data,headers or {}),timeout=8)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                code = response.status; response.read(4096)
                need(response.headers.get('X-Frame-Options') == 'DENY', 'Missing anti-framing header')
                need("frame-ancestors 'none'" in response.headers.get('Content-Security-Policy',''), 'Missing frame-ancestors policy')
                return code
        need(request('/') == 200, 'Viewer bootstrap is unavailable')
        need(request('/vnc.html') in {401,403}, 'Viewer assets lack authentication')
        need(request('/',{'Host':'attacker.invalid'}) == 403, 'Viewer accepted an invalid Host')
        need(request('/auth',{'Origin':'http://attacker.invalid','Content-Type':'application/json'},b'{"token":"invalid"}') == 403,
             'Viewer accepted a cross-origin authentication request')
        need(request('/auth',{'Origin':base,'Content-Type':'application/json'},b'{"token":"invalid"}') in {401,403}, 'Viewer accepted an invalid token')
        need(request('/websockify',{'Origin':'http://attacker.invalid'}) in {401,403}, 'Viewer websocket accepted a hostile Origin')
        token = self.user(['/usr/bin/python3',str(HELPERS / 'save-evidence.py'),'read-token']).stdout.strip()
        cookie_jar = http.cookiejar.CookieJar(); opener = local_client(urllib.request.HTTPCookieProcessor(cookie_jar))
        req = urllib.request.Request(base + '/auth',json.dumps(dict(token=token)).encode(),{'Origin':base,'Content-Type':'application/json'})
        with opener.open(req,timeout=8) as response:
            need(response.status in {200,204}, 'Viewer authentication failed')
            cookie = response.headers.get('Set-Cookie','')
            need('HttpOnly' in cookie and 'SameSite=Strict' in cookie, 'Viewer cookie protections missing')
        with opener.open(base + '/vnc.html',timeout=8) as response:
            need(response.status == 200 and b'noVNC' in response.read(), 'Authenticated noVNC page unavailable')
        return dict(authenticated=True,invalid_token_rejected=True,invalid_host_rejected=True,
                    cross_origin_rejected=True,frame_embedding_denied=True)

    def browser_check(self, proc=Path('/proc')):
        need(not self.manual(), 'Browser automation paused by manual takeover')
        result = self.cdp('SystemInfo.getInfo')['gpu']
        renderer = result.get('auxAttributes',{}).get('glRenderer','')
        profile = self.cfg.get('probe_profile') or str(self.data / 'profile')
        unit = self.cfg.get('probe_unit','onedebian-agent-chromium.service')
        need(unit in {'onedebian-agent-chromium.service','onedebian-agent-gpu-probe.service'}, 'Invalid Chromium service')
        need(unit != 'onedebian-agent-gpu-probe.service' or self.cfg.get('probe_profile'), 'GPU probe profile is missing')
        main = subprocess.run(['systemctl','show',unit,'-p','MainPID','--value'],
                              capture_output=True,text=True,check=True,timeout=10)
        pid = int(main.stdout.strip()); need(pid > 0,'Chromium service has no main process')
        process = proc / str(pid)
        args = process_args(process)
        need(process.stat().st_uid == self.uid,'Chromium is not owned by the agent user')
        need(os.readlink(process / 'exe') == '/usr/lib/chromium/chromium','Chromium service did not exec the Debian browser binary')
        need(('--user-data-dir=' + profile).encode() in args and not any(arg.startswith(b'--type=') for arg in args),
             'Chromium service is not the main browser for the owned profile')
        need(('--remote-debugging-port=' + str(self.cfg['cdp_port'])).encode() in args,'Chromium CDP port differs from configuration')
        need(b'--no-sandbox' not in args and b'--disable-setuid-sandbox' not in args and b'--password-store=basic' not in args,
             'Chromium disables sandbox or default credential storage')
        browser_pids = [int(item['id']) for item in self.cdp('SystemInfo.getProcessInfo')['processInfo'] if item['type'] == 'browser']
        need(browser_pids == [pid],'CDP browser PID differs from the managed Chromium service')
        self.browser_pid = pid
        return dict(pid=pid,renderer=renderer,feature_status=result.get('featureStatus',{}),
                    sandbox_flags_preserved=True,profile=profile)

    def browser_ready(self):
        deadline = time.monotonic() + 30
        while True:
            try:
                with local_open(f'http://127.0.0.1:{self.cfg["cdp_port"]}/json/version',timeout=2) as response:
                    need('webSocketDebuggerUrl' in json.load(response),'CDP is not ready')
                return self.browser_check()
            except (OSError,RuntimeError,ValueError,subprocess.SubprocessError) as error:
                if time.monotonic() >= deadline:
                    raise RuntimeError('Chromium readiness timed out: ' + str(error)) from error
                time.sleep(0.5)

    def gpu_check(self):
        node = self.cfg.get('render_node','')
        backend = gpu_backend(self.cfg)
        gpu = dict(passed=False,reason='',backend=backend,renderer='',render_node=node,evidence={})
        self.report['gpu'] = gpu
        try:
            need(not self.manual(), 'Browser automation paused by manual takeover')
            need(backend != 'software',
                 '/dev/dxg alone does not prove acceleration; software fallback' if Path('/dev/dxg').exists() else 'No selected GPU backend; software fallback')
            need(Path('/dev/dxg' if backend == 'd3d12' else node).exists(), 'Selected GPU device is absent')
            need(hasattr(self,'browser_pid'), 'Owned Chromium process has not been verified')
            # The native probe must enter the desktop mount namespace; never replace WSLg sockets.
            services = subprocess.run(['systemctl','show','onedebian-agent-desktop.service','-p','MainPID','--value'],capture_output=True,text=True,check=True,timeout=10)
            pid = int(services.stdout.strip()); need(pid > 0,'Desktop service is not running')
            worker = ['/usr/bin/python3',str(Path(__file__).resolve()),'--egl-worker','--gpu-backend',backend]
            if backend == 'drm': worker += ['--render-node',node]
            if os.geteuid() == 0:
                command = ['nsenter','--target',str(pid),'--mount','--'] + self.user_command(worker)
            else:
                raise RuntimeError('GPU verification requires root to enter the private desktop namespace')
            native = subprocess.run(command,env=self.env,capture_output=True,text=True,check=False,timeout=40)
            proof = json.loads(native.stdout) if native.stdout.strip() else {'passed':False,'error':native.stderr.strip()[:1000]}
            gpu['evidence']['native_egl'] = proof
            need(native.returncode == 0 and proof.get('passed'), 'Native EGL proof failed: ' + proof.get('error','unknown failure'))
            info = self.cdp('SystemInfo.getInfo')['gpu']; gpu['renderer'] = info.get('auxAttributes',{}).get('glRenderer','')
            gpu['evidence']['feature_status'] = info.get('featureStatus',{})
            renderer_check = d3d12_renderer if backend == 'd3d12' else hardware_renderer
            need(renderer_check(gpu['renderer']), 'Chromium GPU renderer is software or the wrong backend')
            features = info.get('featureStatus',{})
            # New Chromium combines the WebGL feature status; WebGL2 still needs its own shader draw below.
            for feature in ['gpu_compositing','webgl'] + (['webgl2'] if 'webgl2' in features else []):
                need(str(info.get('featureStatus',{}).get(feature,'')).startswith('enabled'), 'Chromium hardware feature not enabled: ' + feature)
            need(not self.manual(), 'Browser automation paused by manual takeover')
            target = self.cdp('Target.createTarget',{'url':'about:blank'})['targetId']
            try:
                with local_open(f'http://127.0.0.1:{self.cfg["cdp_port"]}/json/list',timeout=5) as response:
                    tabs = json.load(response)
                page = next(item for item in tabs if item['id'] == target)
                evaluation = self.cdp('Runtime.evaluate',{'expression':WEBGL_JS,'returnByValue':True},page['webSocketDebuggerUrl'])
                need('exceptionDetails' not in evaluation,'WebGL draw raised an exception')
                draws = evaluation['result']['value']; gpu['evidence']['webgl_draws'] = draws
                for version in ['webgl','webgl2']:
                    need(draws[version].get('passed') and renderer_check(draws[version].get('renderer','')),
                         version + ' hardware shader draw/readback failed')
                gpu['evidence']['chromium_gpu_fds'] = gpu_process_fds(self.browser_pid,self.uid,node,backend=backend)
                need(gpu['evidence']['chromium_gpu_fds'], 'Chromium GPU process lacks ' +
                     ('DXG and D3D12/DXCore evidence' if backend == 'd3d12' else 'an FD for the exact selected render node'))
            finally:
                self.cdp('Target.closeTarget',{'targetId':target})
            gpu.update(passed=True,reason='Native EGL, Chromium ' + ('DXG/D3D12 evidence' if backend == 'd3d12' else 'exact-node FD') +
                       ', WebGL1 and WebGL2 hardware shader drawing passed')
            return gpu
        except Exception as error:
            gpu['reason'] = str(error)
            raise

    def browser_e2e(self):
        need(not self.manual(), 'Browser automation paused by manual takeover')
        fixture = subprocess.Popen(self.user_command(self.node_command([str(HELPERS / 'acceptance-frontend.mjs')])),env=self.env,
                                   stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,start_new_session=True)
        try:
            selector = selectors.DefaultSelector(); selector.register(fixture.stdout,selectors.EVENT_READ)
            try:
                need(selector.select(20),'Node frontend startup timed out')
                port = fixture.stdout.readline().strip()
            finally:
                selector.close()
            need(port.isdecimal() and 0 < int(port) < 65536,'Node frontend did not report a valid port')
            url = f'http://127.0.0.1:{port}/onedebian-acceptance'
            with local_open(url,timeout=5) as response:
                need(response.status == 200 and b'oneDebian acceptance' in response.read(16384),'Owned Node frontend HTTP health check failed')
            self.report['frontend_http_healthy'] = True
            mcp = MCP(self.cfg['mcp_port']); mcp.initialize()
            tools = {item['name'] for item in mcp.request('tools/list')['tools']}
            required = {'browser_tabs','browser_navigate','browser_snapshot','browser_type','browser_click','browser_take_screenshot'}
            need(required <= tools,'MCP lacks the required browser tools')
            mcp.call('browser_tabs',{'action':'new'})
            self.report['browser_input_issued'] = True
            mcp.call('browser_navigate',{'url':url})
            snapshot = text_content(mcp.call('browser_snapshot',{}))
            mcp.call('browser_type',{'element':'Name','target':snapshot_ref(snapshot,'textbox','Name'),'text':'oneDebian'})
            snapshot = text_content(mcp.call('browser_snapshot',{}))
            mcp.call('browser_click',{'element':'Submit','target':snapshot_ref(snapshot,'button','Submit')})
            snapshot = text_content(mcp.call('browser_snapshot',{})); need('Hello oneDebian' in snapshot,'MCP input/click result missing')
            screenshot = mcp.call('browser_take_screenshot',{'type':'png','scale':'css'})
            images = [item for item in screenshot.get('content',[]) if item.get('type') == 'image' and item.get('data')]
            need(images, 'MCP screenshot returned no image')
            image = base64.b64decode(images[0]['data'],validate=True)
            need(image.startswith(b'\x89PNG\r\n\x1a\n') and len(image) >= 24, 'MCP screenshot is not a PNG image')
            width,height = struct.unpack('>II',image[16:24])
            need(width > 0 and height > 0, 'MCP screenshot is empty')
            screenshot_path = self.data / 'verification.png'
            self.user(['/usr/bin/python3',str(HELPERS / 'save-evidence.py'),'screenshot'],input=image,text=False)
            with local_open(f'http://127.0.0.1:{self.cfg["cdp_port"]}/json/list',timeout=5) as response:
                tabs = json.load(response)
            page = next(item for item in tabs if item.get('url') == url)
            dom = self.cdp('Runtime.evaluate',{'expression':'document.querySelector("#result").textContent','returnByValue':True},page['webSocketDebuggerUrl'])
            need(dom['result'].get('value') == 'Hello oneDebian','Independent CDP DOM result did not match MCP')
            prior = json.loads(self.user(['/usr/bin/python3',str(HELPERS / 'save-evidence.py'),'read-cookie']).stdout)
            owned = self.cdp('Runtime.evaluate',{'expression':
                'document.cookie.split(";").map(x=>x.trim()).find(x=>x.startsWith("__onedebian_acceptance="))?.slice("__onedebian_acceptance=".length) ?? null',
                'returnByValue':True},page['webSocketDebuggerUrl'])['result'].get('value')
            boot_id = session_boot_id()
            survived = bool(prior and uuid.UUID(prior['boot_id']).version == 5
                            and prior['boot_id'] != boot_id and owned == prior.get('value'))
            value = prior['value'] if prior else hashlib.sha256(os.urandom(32)).hexdigest()
            cookie_result = self.cdp('Network.setCookie',{'name':'__onedebian_acceptance','value':value,'url':url,
                     'path':'/onedebian-acceptance','expires':time.time()+365*86400,'sameSite':'Strict'},page['webSocketDebuggerUrl'])
            need(cookie_result.get('success'), 'Browser did not accept the owned synthetic cookie')
            # User-controlled data paths must never be written with the installer's root privilege.
            self.user(['/usr/bin/python3',str(HELPERS / 'save-evidence.py'),'cookie'],
                      input=json.dumps(dict(boot_id=boot_id,value=value)).encode(),text=False)
            return dict(mcp_input_click=True,screenshot={'path':str(screenshot_path),'width':width,'height':height,
                        'sha256':hashlib.sha256(image).hexdigest()},independent_dom=True,verification_tab_retained=True,
                        synthetic_cookie_cross_boot='passed' if survived else 'not_yet_verified')
        finally:
            # Only the owned acceptance frontend is stopped, never a user's build or browser.
            try:
                os.killpg(fixture.pid,signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                fixture.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(fixture.pid,signal.SIGKILL); fixture.wait(timeout=5)


def descendants(root_pid, proc=Path('/proc')):
    parents = {}
    for process in proc.iterdir():
        if not process.name.isdecimal():
            continue
        try:
            parent = re.search(r'^PPid:\s+(\d+)',(process / 'status').read_text(),re.M)
            if parent:
                parents[int(process.name)] = int(parent[1])
        except OSError:
            continue
    found = set(); frontier = {root_pid}
    while frontier:
        frontier = {pid for pid,parent in parents.items() if parent in frontier and pid not in found and pid != root_pid}
        found.update(frontier)
    return sorted(found)


def gpu_process_fds(browser_pid, uid, render_node, proc=Path('/proc'), backend='drm'):
    result = []
    for pid in descendants(browser_pid,proc):
        process = proc / str(pid)
        try:
            if process.stat().st_uid != uid or b'--type=gpu-process' not in process_args(process):
                continue
            if backend == 'd3d12':
                evidence = d3d12_evidence(process)
                if evidence['passed']: result.append(dict(pid=pid,**evidence))
                continue
            for fd in (process / 'fd').iterdir():
                try:
                    if os.path.realpath(fd) == render_node:
                        result.append(dict(pid=pid,fd=fd.name,render_node=render_node))
                except OSError:
                    continue
        except OSError:
            continue
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gpu',action='store_true',help='Require proven native and browser GPU shader drawing')
    parser.add_argument('--browser',action='store_true',help='Open owned frontend and issue MCP input/click/screenshot')
    parser.add_argument('--json',action='store_true')
    parser.add_argument('--egl-worker',action='store_true',help=argparse.SUPPRESS)
    parser.add_argument('--render-node',help=argparse.SUPPRESS)
    parser.add_argument('--gpu-backend',choices=['drm','d3d12'],default='drm',help=argparse.SUPPRESS)
    parser.add_argument('--probe-config',action='store_true',help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        if args.egl_worker:
            gpu_backend(dict(gpu_backend=args.gpu_backend,render_node=args.render_node or ''))
            account = pwd.getpwnam(json.loads(CONFIG.read_text())['user'])
            need(os.geteuid() != 0 and os.geteuid() == account.pw_uid,'Run the native EGL worker as the ordinary agent user')
            print(json.dumps(native_egl(args.render_node or '',args.gpu_backend))); return 0
        need(not args.probe_config or (args.gpu and not args.browser), 'Temporary GPU probes only support --gpu')
        config = probe_config() if args.probe_config else json.loads(CONFIG.read_text())
        need(args.probe_config or not config.get('probe_unit'), 'A probe service is not a production browser')
        verifier = Verifier(config,json.loads(VERSIONS.read_text()))
        # Initial GPU trials deliberately run no MCP/viewer against the temporary profile.
        if not args.gpu or args.browser:
            for name,action in [('fnm Node runtime',verifier.version_check),
                                ('owned services and manual gate',lambda: verifier.wait_check(verifier.service_check)),
                                ('loopback listeners',lambda: verifier.wait_check(verifier.listener_check)),
                                ('viewer access controls',lambda: verifier.wait_check(verifier.viewer_check))]:
                verifier.check(name,action)
        if verifier.manual():
            verifier.report['warnings'].append('Manual takeover is active; browser automation checks skipped')
            if args.gpu or args.browser:
                verifier.check('automation permitted',lambda: need(False,'Manual takeover is active'))
        else:
            verifier.check('Chromium owner and sandbox',verifier.browser_ready)
            if args.gpu:
                verifier.report['hardware_required'] = True
                verifier.check('native and browser hardware acceleration',verifier.gpu_check)
            if args.browser:
                verifier.check('Node frontend via browser MCP',verifier.browser_e2e)
        verifier.report['passed'] = all(check['passed'] for check in verifier.report['checks'])
        report = verifier.report
    except Exception as error:
        report = dict(passed=False,error=str(error),checks=[])
    if args.json or args.egl_worker:
        print(json.dumps(report,ensure_ascii=False))
    else:
        print('oneDebian verification: ' + ('PASS' if report['passed'] else 'FAILED'))
        for check in report.get('checks',[]):
            print(('  PASS ' if check['passed'] else '  FAIL ') + check['name'] + (': ' + check['error'] if 'error' in check else ''))
        for warning in report.get('warnings',[]):
            print('  Pending: ' + warning)
        if report.get('error'):
            print('  ' + report['error'])
    return 0 if report['passed'] else 2


if __name__ == '__main__':
    raise SystemExit(main())
