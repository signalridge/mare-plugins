"""Configured VM limits must survive both public service execution modes."""
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[2]
BIN = os.environ['MARE_BIN']
spec = importlib.util.spec_from_file_location('mare_rpc_client', os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pty", "rpc_client.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for mode in ('per-call', 'persistent-in-memory'):
    with tempfile.TemporaryDirectory(prefix='mare-script-limits-') as tmp:
        base = pathlib.Path(tmp)
        (base / 'home/config').mkdir(parents=True)
        (base / 'home/config/init.lua').write_text(
            'mare.setup {model="faux/echo"}\n'
            f'mare.plugin("cells",{{execution_mode="{mode}",max_output_bytes=512,max_message_bytes=8192,max_pending_calls=1,stop_grace_ms=50,grace_ms=100}})\n', encoding="utf-8")
        env = os.environ.copy()
        env['MARE_HOME'] = str(base / 'home')
        client = module.Client([BIN, '--rpc', '--no-session', '--yolo'], env, base)
        try:
            sid = client.call('initialize', {'protocol_version':'3.0'})['session']['session_id']
            result = client.call('cells.start', {'session_id':sid, 'cell_id':'small', 'code':'text(string.rep("a",100))'})
            assert result['status'] == 'completed', result
            result = client.call('cells.start', {'session_id':sid, 'cell_id':'large-helper', 'code':'text(string.rep("a",600))'})
            assert result['status'] == 'failed' and 'byte limit' in result['error'], result
            result = client.call('cells.start', {'session_id':sid, 'cell_id':'large-print', 'code':'print(string.rep("b",600))'})
            assert result['status'] == 'failed' and 'byte limit' in result['error'], result
        finally:
            client.p.stdin.close()
            try:
                client.p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                client.p.kill()
                client.p.wait()
print('script configured output limits: fresh/retained helper and native print passed')
