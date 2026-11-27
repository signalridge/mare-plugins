#!/usr/bin/env python3
"""RPC parity, host callbacks and actual worker process termination (no model calls)."""
import json
import sys
import os
import pathlib
import queue
import subprocess
import tempfile
import threading
import time

ROOT=pathlib.Path(__file__).resolve().parents[2]
BIN=os.environ.get('MARE_BIN',str(ROOT.parent/'mare/target/debug/mare'))
with tempfile.TemporaryDirectory(prefix='mare-sandbox-rpc-') as tmp:
    base=pathlib.Path(tmp); (base/'home/config').mkdir(parents=True)
    (base/'home/config/init.lua').write_text('mare.setup {model="faux/echo"}\n', encoding="utf-8")
    env=os.environ.copy(); env['MARE_HOME']=str(base/'home')
    p=subprocess.Popen([BIN,'--rpc','--no-session','--yolo'],env=env,cwd=base,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1, encoding="utf-8")
    messages=queue.Queue()
    def reader():
        for line in p.stdout: messages.put(json.loads(line))
    threading.Thread(target=reader,daemon=True).start()
    def send(id,method,params):
        p.stdin.write(json.dumps({'jsonrpc':'2.0','id':id,'method':method,'params':params})+'\n');p.stdin.flush()
    def reply(message,result):
        p.stdin.write(json.dumps({'jsonrpc':'2.0','id':message['id'],'result':result})+'\n');p.stdin.flush()
    def text_of(res):
        return ''.join(b.get('text','') for b in res.get('content',[]) if b.get('type')=='text')
    def response(id, allow_error=False):
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            m=messages.get(timeout=20)
            if m.get('method') == 'callback.call':
                params = m.get('params', {})
                arguments = params.get('arguments', {})
                ctx = arguments.get('ctx', {}) if isinstance(arguments, dict) else {}
                call_id = params.get('tool_call_id') or ctx.get('tool_call_id')
                assert isinstance(call_id, str) and call_id, m
                assert isinstance(ctx.get('idempotency_key'), str) and ctx.get('idempotency_key'), m
                reply(m, {'content': 'HOST_VALUE'})
            elif m.get('id')==id and ('result' in m or 'error' in m):
                if allow_error:
                    return m
                assert 'error' not in m,m
                return m['result']
        raise AssertionError('RPC timed out')
    try:
        send(1,'initialize',{'protocol_version':'3.0','capabilities':{'tools':True,'callbacks':True}})
        init=response(1)
        sid=init['session']['session_id']
        assert 'cells.start' in init['capabilities']['methods']
        send(2,'tools.register',{'name':'host_echo','description':'host fixture','parameters':{'type':'object'},'side_effect':'read','callbacks':['execute']})
        reg=response(2)
        assert reg.get('registration_id'),reg
        send(3,'cells.start',{'session_id':sid,'cell_id':'echo','code':'return tools.host_echo({}).content','capabilities':['host_echo']})
        result=response(3)
        assert result['result']=='HOST_VALUE' and result['status']=='completed',result
        # Native Lua string matching stays in C; worker must be killed independently of hooks.
        code='return string.find(string.rep("a",1000000),"a*a*a*a*a*b")'
        send(4,'cells.start',{'session_id':sid,'cell_id':'cancel','code':code,'timeout_ms':60000})
        worker=None
        if pathlib.Path('/proc').exists():
            deadline=time.monotonic()+10
            probe_id=40
            while time.monotonic()<deadline and worker is None:
                children=pathlib.Path(f'/proc/{p.pid}/task/{p.pid}/children').read_text(encoding="utf-8").split()
                for pid in children:
                    try:
                        if '__lua-vm-worker' in pathlib.Path(f'/proc/{pid}/cmdline').read_text(encoding="utf-8"): worker=int(pid)
                    except FileNotFoundError: pass
                if worker is None:
                    send(probe_id,'cells.get',{'session_id':sid})
                    response(probe_id)
                    probe_id+=1
            assert worker is not None,'did not observe isolated worker'
        send(5,'cells.cancel',{'session_id':sid,'cell_id':'cancel'})
        # Responses may arrive in either order; retain the run response while waiting for cancel.
        seen={}
        deadline=time.monotonic()+15
        while not (4 in seen and 5 in seen):
            m=messages.get(timeout=max(.1,deadline-time.monotonic()))
            if m.get('id') in (4,5) and ('result' in m or 'error' in m): seen[m['id']]=m
        assert seen[5]['result']=={},seen
        assert seen[4]['result']['status']=='cancelled',seen
        if worker: assert not pathlib.Path(f'/proc/{worker}').exists(),'worker survived confirmed cancellation'
        # Hard deadline must also stop native C matching, without a client cancellation.
        send(6,'cells.start',{'session_id':sid,'cell_id':'timeout','code':code,'timeout_ms':100})
        result=response(6)
        assert result['status']=='failed' and 'time limit' in result['error'],result
        send(7,'cells.start',{'session_id':sid,'cell_id':'safe','code':'assert(not io and not os and not require);assert(load("return 1")==json.null); return json.decode("[null,[]]")'})
        result=response(7)
        assert result.get('result')==[None,[]],result
        send(8,'cells.start',{'session_id':sid,'cell_id':'partial','code':'print("before failure"); error("expected failure")'})
        result=response(8)
        assert result['status']=='failed' and text_of(result).startswith('before failure\n'),result
        send(9,'cells.start',{'session_id':sid,'cell_id':'unbound','code':'return tools.host_echo({})'})
        result=response(9)
        assert result['status']=='failed',result
        send(10,'cells.start',{'session_id':sid,'cell_id':'waiting-host','code':'return tools.host_echo({})','capabilities':['host_echo']})
        callback=None
        while callback is None:
            message=messages.get(timeout=10)
            if message.get('method')=='callback.call': callback=message['id']
        send(11,'cells.cancel',{'session_id':sid,'cell_id':'waiting-host'})
        seen={};cancel_notice=False
        deadline=time.monotonic()+15
        while not (10 in seen and 11 in seen):
            message=messages.get(timeout=max(.1,deadline-time.monotonic()))
            if message.get('method')=='$/cancel_request' and message.get('params',{}).get('id')==callback: cancel_notice=True
            if message.get('id') in (10,11) and ('result' in message or 'error' in message): seen[message['id']]=message
        assert seen[10]['result']['status']=='cancelled' and seen[11]['result']=={} and cancel_notice,seen
        send(12,'cells.start',{'session_id':sid,'cell_id':'store','code':'store("key",{n=7}); return load("key")'})
        assert response(12)['result']=={'n':7}
        # Hold a real nested host callback so a second cell commits while the first is live.
        send(130,'cells.start',{'session_id':sid,'cell_id':'snapshot','code':'tools.host_echo({}); assert(load("key").n==7); store("key",{n=9}); return load("key")','capabilities':['host_echo'],'yield_time_ms':0})
        held=None;started=False
        while not (held and started):
            message=messages.get(timeout=20)
            if message.get('method')=='callback.call':held=message
            elif message.get('id')==130:
                assert message['result']['status']=='running',message
                started=True
        send(131,'cells.start',{'session_id':sid,'cell_id':'concurrent-write','code':'store("key",{n=8}); return load("key")'})
        assert response(131)['result']=={'n':8}
        reply(held,{'content':'resume'})
        send(132,'cells.wait',{'session_id':sid,'cell_id':'snapshot','yield_time_ms':10000})
        snapshot=response(132)
        assert snapshot['status']=='completed' and snapshot['result']=={'n':9},snapshot
        send(133,'cells.start',{'session_id':sid,'cell_id':'snapshot-committed','code':'return load("key")'})
        assert response(133)['result']=={'n':9}
        send(14,'cells.reset',{'session_id':sid})
        assert response(14)=={}
        send(15,'cells.start',{'session_id':sid,'cell_id':'cleared','code':'return load("key")'})
        assert response(15).get('result') is None
        send(16,'cells.start',{'session_id':sid,'cell_id':'cell','code':'text("first"); yield_control(); sleep(200); text("second"); return 3','yield_time_ms':10})
        first=response(16)
        if not first['content']:
            send(160,'cells.wait',{'session_id':sid,'cell_id':'cell','yield_time_ms':500})
            first=response(160)
        assert first['status']=='running' and any(b.get('text')=='first' for b in first['content']),first
        send(17,'cells.wait',{'session_id':sid,'cell_id':'cell','yield_time_ms':500})
        final=response(17)
        assert final['status']=='completed' and final['result']==3 and not any(b.get('text')=='first' for b in final['content']),final
        send(18,'cells.wait',{'session_id':sid,'cell_id':'cell','yield_time_ms':0})
        missing=response(18, allow_error=True)
        assert missing.get('error',{}).get('data',{}).get('code')=='cells.unknown_cell',missing
        # A pending timer alone does not retain a cell or its host callback.
        send(19,'cells.start',{'session_id':sid,'cell_id':'orphan-timer','code':'setTimeout(function() tools.host_echo({}) end,0); sleep(30); return "finished"','capabilities':['host_echo']})
        cancelled_callback=False;callback_id=None
        while True:
            message=messages.get(timeout=15)
            if message.get('method')=='callback.call': callback_id=message['id']
            elif message.get('method')=='$/cancel_request' and message.get('params',{}).get('id')==callback_id: cancelled_callback=True
            elif message.get('id')==19:
                assert callback_id is not None and cancelled_callback,(callback_id,cancelled_callback,message)
                assert message['result'].get('result')=='finished',message
                break
        send(20,'shutdown',{});response(20)
        p.stdin.close();p.wait(timeout=10)
        assert p.returncode==0,p.stderr.read()
    finally:
        if p.poll() is None: p.kill();p.wait()
        if os.environ.get('CODEMODE_TRACE'): print(p.stderr.read())
print('sandbox RPC: typed results, declared host callback, native-C cancellation + actual PID reap, timeout, capability and JSON parity passed')
