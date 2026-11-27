#!/usr/bin/env python3
"""Owner-scoped retained VM behaviour through the real public RPC transport."""
import importlib.util
import os
import pathlib
import sys
import tempfile

sys.dont_write_bytecode=True
ROOT=pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
from hooks_processes import is_pid_alive
BIN=os.environ.get('MARE_BIN',str(ROOT.parent/'mare/target/debug/mare'))
spec=importlib.util.spec_from_file_location('mare_rpc_client',os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pty", "rpc_client.py"))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='mare-retained-') as tmp:
    base=pathlib.Path(tmp);(base/'home/config').mkdir(parents=True)
    (base/'home/config/init.lua').write_text('mare.setup {model="faux/echo"}\nmare.plugin("cells",{execution_mode="persistent-in-memory"})\n', encoding="utf-8")
    env=os.environ.copy();env['MARE_HOME']=str(base/'home')
    client=module.Client([BIN,'--rpc','--no-session','--yolo'],env,base)
    sid=None
    def run(id,code,**options):
        mapped={'session_id':sid,'cell_id':id,'code':code}
        if 'timeoutMs' in options:mapped['timeout_ms']=options.pop('timeoutMs')
        if 'stateOwner' in options:mapped['state_owner']=options.pop('stateOwner')
        mapped.update(options)
        return client.call('cells.start',mapped)
    def text_of(res):return ''.join(b.get('text','') for b in res.get('content',[]) if b.get('type')=='text')
    def worker_pids():
        children=pathlib.Path(f'/proc/{client.p.pid}/task/{client.p.pid}/children')
        if not children.exists():return set()
        result=set()
        for pid in children.read_text(encoding="utf-8").split():
            try:
                if '__lua-vm-worker' in pathlib.Path(f'/proc/{pid}/cmdline').read_text(encoding="utf-8"):result.add(int(pid))
            except FileNotFoundError:pass
        return result
    try:
        sid=client.call('initialize',{'protocol_version':'3.0','capabilities':{'tools':True,'callbacks':True}})['session']['session_id']
        client.call('tools.register',{'name':'host_echo','description':'fixture','parameters':{'type':'object'},'side_effect':'read','callbacks':['execute']})
        assert run('set','counter=7; function inc() counter=counter+1; return counter end; old_tool=tools.host_echo; return counter',capabilities=['host_echo'])['result']==7
        initial=worker_pids()
        assert client.call('cells.get',{'session_id':sid})['retains_state']
        assert run('inc','return inc()')['result']==8
        if initial:assert worker_pids()==initial,'retained worker was replaced between successful chunks'
        result=run('stale','local ok,e=pcall(old_tool,{}); assert(not ok and tostring(e):find("expired",1,true)); return counter',capabilities=['host_echo'])
        assert result['result']==8,result
        before_exit=worker_pids()
        result=run('exit','counter=8; store("exit-value",{n=8}); text("before exit"); pcall(exit); counter=999; error("must not execute")')
        assert result['status']=='completed' and 'before exit' in text_of(result),result
        if before_exit:assert worker_pids()==before_exit,'successful exit replaced retained worker'
        assert run('after-exit','assert(load("exit-value").n==8); return counter')['result']==8
        result=run('error','counter=9;error("expected")');assert result['status']=='failed',result
        assert run('after-error','return inc()')['result']==10
        result=run('timeout','while true do end',timeoutMs=50);assert result['status']=='failed',result
        if initial:assert not any(is_pid_alive(pid) for pid in initial),'cancelled retained worker survived'
        result=run('after-timeout','assert(counter==nil);return "cleared"')
        assert result['result']=='cleared' and 'environment was lost' in text_of(result),result
        assert run('other','counter=50;return counter',stateOwner='other')['result']==50
        assert run('default','assert(counter==nil);return "isolated"')['result']=='isolated'
        assert run('other-again','counter=counter+1;return counter',stateOwner='other')['result']==51
        before_reset=worker_pids();assert client.call('cells.reset',{'session_id':sid})=={}
        assert not any(is_pid_alive(pid) for pid in before_reset),'reset did not reap workers'
        assert run('reset','assert(counter==nil);return "reset"')['result']=='reset'
        assert run('no-deadline','sleep(50);return "no deadline"',timeout_ms=False)['result']=='no deadline'
        sid=client.call('session.create')['session_id']
        assert run('new-session','assert(counter==nil);return "new session"')['result']=='new session'
        client.call('shutdown');client.p.stdin.close();assert client.p.wait(timeout=15)==0
    finally:
        if client.p.poll() is None:client.p.kill();client.p.wait()
print('retained RPC: globals/functions, same PID, expired capabilities, errors, hard timeout state loss, owner isolation, reset/reap, null deadline and session switch passed')
