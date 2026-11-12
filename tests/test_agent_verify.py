"""Offline verifier checks. Never touches a real desktop or registered WSL instance."""
import importlib.util
import io
import http.server
import json
import os
from pathlib import Path, PurePosixPath
import sys
import tempfile
import threading
import unittest
from unittest import mock

if sys.platform != 'linux':
    raise unittest.SkipTest('The workstation verifier requires Linux namespaces, users and graphics APIs')
spec = importlib.util.spec_from_file_location('agent_verify',Path(__file__).resolve().parents[1] / 'agent/verify.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class VerifierTests(unittest.TestCase):
    def test_d3d12_accepts_hardware_vendors_but_requires_dxg_and_both_libraries(self):
        for adapter in ['Intel(R) Iris(R) Xe Graphics', 'AMD Radeon RX 6600', 'NVIDIA GeForce RTX 4060']:
            with self.subTest(adapter=adapter):
                self.assertTrue(verify.d3d12_renderer('ANGLE (Microsoft, D3D12 (' + adapter + '), OpenGL 4.1)'))
        for name in ['', 'llvmpipe', 'D3D12 (llvmpipe)', 'D3D12 (Microsoft WARP)',
                     'D3D12 (Microsoft Basic Render Driver)', 'D3D12 (BasicRenderDriver)',
                     'D3D12 (Google SwiftShader)', 'Intel OpenGL', 'AMD Radeon RX 6600 (radeonsi)',
                     'NVIDIA GeForce OpenGL', 'D3D12 ()', 'D3D12 ( )', 'D3D12 NVIDIA Graphics']:
            with self.subTest(renderer=name):
                self.assertFalse(verify.d3d12_renderer(name))
        with tempfile.TemporaryDirectory() as temporary:
            process = Path(temporary); (process/'fd').mkdir()
            maps = process/'maps'; maps.write_text('/usr/lib/wsl/lib/libd3d12.so\n/usr/lib/wsl/lib/libdxcore.so\n')
            self.assertFalse(verify.d3d12_evidence(process)['passed'])
            (process/'fd/5').symlink_to('/dev/dxg')
            self.assertTrue(verify.d3d12_evidence(process)['passed'])
            maps.write_text('/usr/lib/wsl/lib/libd3d12.so\n')
            self.assertFalse(verify.d3d12_evidence(process)['passed'])

    def test_dxg_evidence_belongs_to_the_owned_gpu_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            proc = Path(temporary)
            for pid,parent,kind in [(100,1,'browser'),(101,100,'gpu-process'),(102,100,'renderer'),(200,1,'gpu-process')]:
                folder = proc/str(pid); folder.mkdir(); (folder/'status').write_text(f'PPid:\t{parent}\n')
                (folder/'cmdline').write_bytes(b'chromium\0--type='+kind.encode()+b'\0')
                (folder/'fd').mkdir(); (folder/'fd/8').symlink_to('/dev/dxg')
                (folder/'maps').write_text('/usr/lib/wsl/lib/libd3d12.so\n/usr/lib/wsl/lib/libdxcore.so\n')
            found = verify.gpu_process_fds(100,os.getuid(),'',proc,backend='d3d12')
            self.assertEqual([item['pid'] for item in found],[101])
            self.assertEqual(found[0]['device'],'/dev/dxg')

    def test_d3d12_shader_checks_accept_combined_webgl_status_but_reject_disabled_webgl2(self):
        for adapter, explicit in [(name, status) for name in
                ('Intel(R) Iris(R) Xe Graphics', 'AMD Radeon RX 6600', 'NVIDIA GeForce RTX 4060')
                for status in (None, 'disabled_software')]:
            renderer='ANGLE (Microsoft, D3D12 (' + adapter + '), OpenGL 4.1)'
            with self.subTest(adapter=adapter, webgl2_status=explicit):
                runner=verify.Verifier.__new__(verify.Verifier)
                runner.cfg={'gpu_backend':'d3d12','render_node':'','cdp_port':19222}
                runner.report={}; runner.uid=os.getuid(); runner.browser_pid=100
                runner.env={'GALLIUM_DRIVER':'d3d12'}
                features={'gpu_compositing':'enabled','webgl':'enabled'}
                if explicit: features['webgl2']=explicit
                draws={kind:dict(passed=True,renderer=renderer,pixel=[0,255,0,255]) for kind in ('webgl','webgl2')}
                def cdp(method,params=None,endpoint=None):
                    if method=='SystemInfo.getInfo': return {'gpu':{'auxAttributes':{'glRenderer':renderer},'featureStatus':features}}
                    if method=='Target.createTarget': return {'targetId':'trial'}
                    if method=='Runtime.evaluate':
                        self.assertIn('gl.readPixels',params['expression'])
                        return {'result':{'value':draws}}
                    if method=='Target.closeTarget': return {}
                    raise AssertionError(method)
                native=mock.Mock(returncode=0,stdout=json.dumps({'passed':True}),stderr='')
                response=io.BytesIO(json.dumps([{'id':'trial','webSocketDebuggerUrl':'ws://127.0.0.1:19222/devtools/page/trial'}]).encode())
                with mock.patch.object(runner,'manual',return_value=False),mock.patch.object(runner,'cdp',side_effect=cdp), \
                     mock.patch.object(runner,'user_command',side_effect=lambda argv:argv), \
                     mock.patch.object(verify.os,'geteuid',return_value=0),mock.patch.object(verify.Path,'exists',return_value=True), \
                     mock.patch.object(verify.subprocess,'run',side_effect=[mock.Mock(stdout='123\n'),native]) as command, \
                     mock.patch.object(verify,'local_open',return_value=response), \
                     mock.patch.object(verify,'gpu_process_fds',return_value=[{'pid':101,'device':'/dev/dxg'}]) as fds:
                    if explicit:
                        with self.assertRaisesRegex(RuntimeError,'webgl2'): runner.gpu_check()
                        fds.assert_not_called()
                    else:
                        self.assertTrue(runner.gpu_check()['passed'])
                        self.assertEqual(fds.call_args.kwargs['backend'],'d3d12')
                    args=command.call_args_list[1].args[0]
                    self.assertIn('--gpu-backend',args); self.assertIn('d3d12',args)
                    self.assertNotIn('--render-node',args)
                    self.assertEqual(command.call_args_list[1].kwargs['env']['GALLIUM_DRIVER'],'d3d12')

    @unittest.skipUnless(os.geteuid() == 0,'Root-owned probe fixture')
    def test_probe_configuration_is_fixed_private_and_cannot_use_the_working_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'config.json'
            config=dict(home='/home/agent',probe_unit='onedebian-agent-gpu-probe.service',
                        probe_profile='/home/agent/.local/share/onedebian-agent/probes/trial')
            path.write_text(json.dumps(config)); path.chmod(0o600)
            with mock.patch.object(verify,'PROBE_CONFIG',path):
                self.assertEqual(verify.probe_config(),config)
                for change in [dict(probe_unit='other.service'),dict(probe_profile='/home/agent/.local/share/onedebian-agent/profile')]:
                    path.write_text(json.dumps(dict(config,**change)))
                    with self.assertRaises(RuntimeError): verify.probe_config()
                path.write_text(json.dumps(config)); path.chmod(0o666)
                with self.assertRaisesRegex(RuntimeError,'Untrusted'): verify.probe_config()

    def test_verifier_passes_the_selected_backend_to_native_environment(self):
        account=mock.Mock(pw_uid=1000,pw_name='agent')
        config=dict(user='agent',home='/home/agent',viewer_port=16080,mcp_port=18931,cdp_port=19222,
                    gpu_backend='d3d12',render_node='')
        with mock.patch.object(verify.pwd,'getpwnam',return_value=account),mock.patch.object(verify.os,'geteuid',return_value=0):
            runner=verify.Verifier(config,{'node':'v26.13.0'})
        self.assertEqual(runner.env['GALLIUM_DRIVER'],'d3d12')
        self.assertNotIn('MESA_D3D12_DEFAULT_ADAPTER_NAME',runner.env)
        self.assertNotIn('LIBGL_ALWAYS_SOFTWARE',runner.env)

    def test_software_renderers_never_pass(self):
        for name in ['', 'llvmpipe (LLVM 20)', 'ANGLE (Google SwiftShader)', 'Microsoft WARP',
                     'Microsoft Basic Render Driver', 'BasicRenderDriver', 'Basic_Render_Driver',
                     'Mesa softpipe', 'lavapipe', 'Software Rasterizer','SVGA3D','virgl']:
            with self.subTest(name=name):
                self.assertFalse(verify.hardware_renderer(name))
        self.assertTrue(verify.hardware_renderer('ANGLE (Intel, Mesa Intel Graphics (ARL), OpenGL 4.6)'))
        self.assertTrue(verify.hardware_renderer('AMD Radeon RX 6600 (radeonsi)'))

    def test_sse_response_with_notification(self):
        response = 'event: message\r\ndata: {"method":"notifications/message"}\r\n\r\nevent: message\r\ndata: {"id":7,"result":{"tools":[]}}\r\n\r\n'
        self.assertEqual(verify.parse_mcp_response(response,'text/event-stream')['id'],7)
        self.assertEqual(verify.parse_mcp_response('{"id":2}', 'application/json'), {'id':2})
        with self.assertRaises(RuntimeError):
            verify.parse_mcp_response(': heartbeat\n\n','text/event-stream')

    def test_snapshot_uses_exact_owned_fixture_name(self):
        snapshot = '- textbox "Name" [ref=e3]\n- button "Submit" [ref=e4]'
        self.assertEqual(verify.snapshot_ref(snapshot,'textbox','Name'),'e3')
        self.assertEqual(verify.snapshot_ref(snapshot,'button','Submit'),'e4')
        with self.assertRaises(RuntimeError):
            verify.snapshot_ref(snapshot + '\n- textbox "Name" [ref=e8]','textbox','Name')
        with self.assertRaises(RuntimeError):
            verify.snapshot_ref('- textbox "Name hidden" [ref=e3]','textbox','Name')

    def test_node_runs_exact_fnm_version_without_shell(self):
        runner = verify.Verifier.__new__(verify.Verifier)
        runner.home = PurePosixPath('/home/agent'); runner.versions = {'node':'v26.13.0'}
        command = runner.node_command(['--version'])
        self.assertEqual(command, ['/home/agent/.local/share/fnm/fnm','--fnm-dir','/home/agent/.local/share/fnm',
                                   'exec','--using=v26.13.0','node','--version'])

    def test_failed_check_stays_failed_and_keeps_detail(self):
        runner = verify.Verifier.__new__(verify.Verifier); runner.report = {'checks':[]}
        runner.check('GPU', lambda: verify.need(False,'software fallback'))
        self.assertEqual(runner.report['checks'],[{'name':'GPU','passed':False,'error':'software fallback'}])
        runner.check('runtime', lambda: {'version':'v26.13.0'})
        self.assertTrue(runner.report['checks'][1]['passed'])

    def test_parent_inventory_is_bounded_to_descendants(self):
        with tempfile.TemporaryDirectory() as temporary:
            proc = Path(temporary)
            for pid,parent in [(1,0),(100,1),(101,100),(102,101),(200,1),(201,200)]:
                folder = proc / str(pid); folder.mkdir(); (folder / 'status').write_text(f'Name:\tnode\nPPid:\t{parent}\n')
            self.assertEqual(verify.descendants(100,proc),[101,102])

    @unittest.skipIf(sys.platform == 'win32','POSIX render-node symlink fixture')
    def test_exact_gpu_fd_and_owned_browser_ancestry(self):
        with tempfile.TemporaryDirectory() as temporary:
            proc = Path(temporary)
            for pid,parent,kind,node in [(100,1,'browser',None),(101,100,'gpu-process','/dev/dri/renderD130'),
                                      (102,100,'renderer','/dev/dri/renderD130'),(200,1,'gpu-process','/dev/dri/renderD130'),
                                      (103,100,'gpu-process','/dev/dri/renderD128')]:
                folder = proc / str(pid); folder.mkdir(); (folder / 'status').write_text(f'PPid:\t{parent}\n')
                (folder / 'cmdline').write_bytes(b'chromium\0--type=' + kind.encode() + b'\0')
                (folder / 'fd').mkdir()
                if node:
                    (folder / 'fd/5').symlink_to(node)
            found = verify.gpu_process_fds(100,os.getuid(),'/dev/dri/renderD130',proc)
            self.assertEqual(found,[{'pid':101,'fd':'5','render_node':'/dev/dri/renderD130'}])

    def test_mcp_identity_and_tool_error_rejected(self):
        client = verify.MCP(18931)
        result = {'content':[{'type':'text','text':'bad'}],'isError':True}
        with mock.patch.object(client,'request',return_value=result):
            with self.assertRaises(RuntimeError):
                client.call('browser_click',{})

    def test_dxg_only_gpu_has_explicit_software_fallback(self):
        runner = verify.Verifier.__new__(verify.Verifier)
        runner.cfg = {'render_node':''}; runner.report = {}
        with mock.patch.object(verify.Path,'exists',return_value=True), mock.patch.object(runner,'manual',return_value=False):
            with self.assertRaises(RuntimeError):
                runner.gpu_check()
        self.assertFalse(runner.report['gpu']['passed'])
        self.assertIn('/dev/dxg alone',runner.report['gpu']['reason'])

    def test_egl_worker_refuses_non_render_node(self):
        with mock.patch('builtins.print') as printed:
            code = verify.main(['--egl-worker','--render-node','/dev/dxg','--json'])
        self.assertEqual(code,2)
        result = json.loads(printed.call_args[0][0])
        self.assertFalse(result['passed'])

    def test_local_http_ignores_proxy_environment_and_does_not_follow_redirect(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            requests = []
            def do_GET(self):
                self.requests.append(self.path)
                if self.path == '/redirect':
                    self.send_response(302)
                    self.send_header('Location',f'http://127.0.0.1:{self.server.server_port}/must-not-follow')
                else:
                    self.send_response(200)
                self.send_header('Content-Length','0'); self.end_headers()
            def log_message(self,*args): pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        worker = threading.Thread(target=server.serve_forever,daemon=True); worker.start()
        try:
            base = f'http://127.0.0.1:{server.server_port}'
            with mock.patch.dict(os.environ,{'HTTP_PROXY':'http://127.0.0.1:1','http_proxy':'http://127.0.0.1:1',
                                             'NO_PROXY':'','no_proxy':''}):
                with verify.local_open(base + '/ok') as response:
                    self.assertEqual(response.status,200)
                with self.assertRaises(verify.urllib.error.HTTPError) as caught:
                    verify.local_open(base + '/redirect')
                self.assertEqual(caught.exception.code,302)
                caught.exception.close()
            self.assertEqual(Handler.requests,['/ok','/redirect'])
        finally:
            server.shutdown(); server.server_close(); worker.join(timeout=5)

    def test_external_control_url_is_rejected_before_opening_a_socket(self):
        with mock.patch.object(verify.urllib.request,'build_opener') as opener:
            for url in ['http://example.invalid:18931/mcp','https://127.0.0.1:18931/mcp',
                        'http://127.0.0.1:18931@example.invalid/mcp','http://127.0.0.1:18931/mcp#token']:
                with self.subTest(url=url), self.assertRaises(RuntimeError):
                    verify.local_open(url)
        opener.assert_not_called()

    def test_cdp_uses_a_tracked_helper_instead_of_inline_source(self):
        runner = verify.Verifier.__new__(verify.Verifier)
        runner.home = PurePosixPath('/home/agent'); runner.versions = {'node':'v26.13.0'}
        runner.cfg = {'cdp_port':19222}
        with mock.patch.object(runner,'user',return_value=mock.Mock(stdout='{}')) as command:
            self.assertEqual(runner.cdp('SystemInfo.getInfo'),{})
        arguments = command.call_args.args[0]
        self.assertIn(str(verify.HELPERS / 'cdp-probe.mjs'),arguments)
        self.assertNotIn('-e',arguments); self.assertNotIn('-c',arguments)

    def test_interactive_explicit_and_file_wrapper_versions_must_match(self):
        runner = verify.Verifier.__new__(verify.Verifier)
        runner.home = PurePosixPath('/home/agent'); runner.versions = {'node':'v26.13.0'}
        with mock.patch.object(runner,'user',side_effect=[mock.Mock(stdout='v26.13.0\n') for _ in range(3)]) as command:
            self.assertEqual(runner.version_check()['wrapper'],'v26.13.0')
        self.assertEqual(command.call_args.args[0],['/home/agent/.local/bin/node','--version'])
        with mock.patch.object(runner,'user',side_effect=[mock.Mock(stdout='v26.13.0\n'),mock.Mock(stdout='v26.13.0\n'),mock.Mock(stdout='v26.12.0\n')]):
            with self.assertRaisesRegex(RuntimeError,'wrapper fnm Node version mismatch'):
                runner.version_check()

    def test_browser_identity_is_anchored_to_service_and_cdp_pid(self):
        runner = verify.Verifier.__new__(verify.Verifier)
        runner.uid = os.getuid(); runner.cfg = {'cdp_port':19222}
        runner.data = PurePosixPath('/home/agent/.local/share/onedebian-agent')
        with tempfile.TemporaryDirectory() as temporary:
            proc = Path(temporary); process = proc / '123'; process.mkdir()
            (process / 'exe').symlink_to('/usr/lib/chromium/chromium')
            (process / 'cmdline').write_bytes(b'chromium --user-data-dir=/home/agent/.local/share/onedebian-agent/profile --remote-debugging-port=19222\0')
            replies = [{'gpu':{'auxAttributes':{'glRenderer':'fixture renderer'}}},{'processInfo':[{'type':'browser','id':123}]}]
            with mock.patch.object(runner,'manual',return_value=False), \
                 mock.patch.object(runner,'cdp',side_effect=replies), \
                 mock.patch.object(verify.subprocess,'run',return_value=mock.Mock(stdout='123\n')):
                self.assertEqual(runner.browser_check(proc)['pid'],123)
            replies[1] = {'processInfo':[{'type':'browser','id':999}]}
            with mock.patch.object(runner,'manual',return_value=False), \
                 mock.patch.object(runner,'cdp',side_effect=replies), \
                 mock.patch.object(verify.subprocess,'run',return_value=mock.Mock(stdout='123\n')):
                with self.assertRaisesRegex(RuntimeError,'CDP browser PID differs'):
                    runner.browser_check(proc)

    def test_recorded_pnpm_is_required_in_both_wrapper_and_interactive_shell(self):
        runner=verify.Verifier.__new__(verify.Verifier)
        runner.home=PurePosixPath('/home/agent'); runner.versions={'node':'v26.13.0','pnpm':'12.18.0'}
        for last in ('12.18.0','0.0.0'):
            replies=[mock.Mock(stdout=x+'\n') for x in ['v26.13.0']*3+['12.18.0',last]]
            with self.subTest(last=last), mock.patch.object(runner,'user',side_effect=replies):
                if last=='0.0.0':
                    with self.assertRaisesRegex(RuntimeError,'pnpm version mismatch'): runner.version_check()
                else: self.assertEqual(runner.version_check()['pnpm'],'12.18.0')

    def test_chromium_rewritten_title_and_nul_argv_are_both_supported(self):
        with tempfile.TemporaryDirectory() as temporary:
            process = Path(temporary)
            for raw in [b'chromium\0--type=gpu-process\0',b'chromium --type=gpu-process\0']:
                (process / 'cmdline').write_bytes(raw)
                self.assertEqual(verify.process_args(process),[b'chromium',b'--type=gpu-process'])

    def test_wsl_distro_restart_changes_session_id_without_kernel_reboot(self):
        with tempfile.TemporaryDirectory() as temporary:
            proc = Path(temporary)
            (proc / 'sys/kernel/random').mkdir(parents=True); (proc / '1').mkdir()
            (proc / 'sys/kernel/random/boot_id').write_text('12345678-abcd-abcd-abcd-0123456789ab')
            def pid1(start):
                (proc / '1/stat').write_text('1 (init (ai-dev)) S ' + '0 '*18 + str(start) + ' 0\n')
            pid1(100)
            before = verify.session_boot_id(proc)
            self.assertEqual(verify.uuid.UUID(before).version,5)
            self.assertEqual(verify.session_boot_id(proc),before)
            pid1(200)
            self.assertNotEqual(verify.session_boot_id(proc),before)


if __name__ == '__main__':
    unittest.main()
