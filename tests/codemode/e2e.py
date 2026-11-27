#!/usr/bin/env python3
"""Independent file:// package + deterministic faux model integration (no paid API)."""
import json
import re
import sys
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
BIN = os.environ.get('MARE_BIN', str(ROOT.parent / 'mare/target/debug/mare'))

def command(args, env, cwd):
    result = subprocess.run(args, check=False, cwd=cwd, env=env, text=True, capture_output=True, timeout=60, encoding="utf-8")
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result.stdout

with tempfile.TemporaryDirectory(prefix='mare-codemode-e2e-') as tmp:
    base=pathlib.Path(tmp)
    package=base/'package'; (package/'plugins').mkdir(parents=True)
    shutil.copy(ROOT/'mare-plugin.toml',package)
    shutil.copytree(ROOT/'plugins/codemode',package/'plugins/codemode')
    probe=package/'plugins/probe'; probe.mkdir()
    (probe/'init.lua').write_text('''return {name="probe",inject={"tools","policy"},apply=function(ctx)
      local gates = {}
      local seq_log = {}
      local active_writes, max_writes = 0, 0
      local dynamic_deny = false
      local function gate_for(id)
        if not gates[id] then gates[id] = mare.task.token() end
        return gates[id]
      end
      ctx.tools:register("probe_echo",{description="echo JSON",parameters={type="object"},
        side_effect="read",execute=function(a) return {content="large intermediate sentinel",details=a} end})
      ctx.tools:register("probe_denied",{description="must not run",parameters={type="object"},
        execute=function() error("DENIED TOOL RAN") end})
      ctx.tools:register("probe_gate",{description="wait on named gate",parameters={type="object"},
        side_effect="read",execute=function(a)
          local id = a.id or "default"
          seq_log[#seq_log+1] = id .. ":enter"
          gate_for(id):wait()
          gates[id] = nil
          seq_log[#seq_log+1] = id .. ":exit"
          return {details={id=id,log=seq_log}}
        end})
      ctx.tools:register("probe_release",{description="release named gate",parameters={type="object"},
        side_effect="read",execute=function(a)
          local id = a.id or "default"
          seq_log[#seq_log+1] = id .. ":release_enter"
          gate_for(id):cancel()
          seq_log[#seq_log+1] = id .. ":release_exit"
          return {details={id=a.result_id or "second",released=id,log=seq_log}}
        end})
      ctx.tools:register("probe_write_track",{description="track concurrent writes",parameters={type="object"},
        side_effect="write",execute=function(a)
          active_writes = active_writes + 1
          if active_writes > max_writes then max_writes = active_writes end
          seq_log[#seq_log+1] = (a.id or "w") .. ":enter"
          mare.fs.write(a.path, a.id or "w")
          seq_log[#seq_log+1] = (a.id or "w") .. ":exit"
          local max_seen = max_writes
          active_writes = active_writes - 1
          return {details={id=a.id,max_writes=max_seen,log=seq_log}}
        end})
      ctx.tools:register("probe_dynamic_policy",{description="allow once then deny",parameters={type="object"},
        side_effect="read",execute=function(a)
          if a.flip then dynamic_deny = true end
          return {content="dynamic:"..(a.phase or "ok")}
        end})
      ctx.policy:voter("tool/before",function(call)
        if call.name=="probe_denied" then return "deny" end
        if call.name=="probe_dynamic_policy" and dynamic_deny then return "deny" end
        if call.name=="codemode_wait" then
          gate_for("auto_on_wait"):cancel()
        end
      end)
      ctx.tools:register("probe_value",{description="typed false",parameters={type="object"},output_schema={type="boolean"},side_effect="read",execute=function()return {value=false}end})
      ctx.tools:register("probe_large",{description="large JSON",parameters={type="object"},side_effect="read",execute=function()return {content={{type="text",text=mare.json.encode_strict({answer=42,payload=string.rep("x",70000)})}}}end})
      local chain_seen={}
      ctx:on("tool/result",function(data,ev) local result,call,budget=data.result,data.call,data.operation; chain_seen[call.id or call]={call=call,budget=budget}; if call.name=="probe_large" then result.content[1].text="display retained" end;return ev.next(data) end)
      -- downstream of the listener above (registered after it, so reached through ev.next()):
      -- core passes { result = display, call = call, operation = retention } and ev.next() must keep all three
      ctx:on("tool/result",function(data,ev)
        local result,call,budget=data.result,data.call,data.operation
        local report=mare.env("CODEMODE_CHAIN_REPORT")
        local seen=call and chain_seen[call.id or call]
        if report then
          assert(mare.fs.write(report,mare.json.encode_strict({tool=call and call.name or "",result=type(result)=="table",same_call=seen~=nil and call==seen.call,same_budget=seen~=nil and budget==seen.budget,budget=type(budget)=="table" and type(budget.max_bytes)=="number"}).."\\n",{append=true}))
        end
        if call then chain_seen[call.id or call]=nil end
        return ev.next()
      end)
      local visible_cell
      ctx.policy:rewriter("tool/rewrite",function(call)
        if call.name=="codemode_wait" and call.arguments.cell_id=="LAST_VISIBLE_CELL" then assert(visible_cell,"model did not receive a cell ID");call.arguments.cell_id=visible_cell end
        return call.arguments
      end)
      ctx:on("request/build",function(request, ev)
        for _,message in ipairs(request.messages or {})do if message.role=="tool_result" and message.tool_name=="codemode" then
          for _,block in ipairs(message.content or {})do if block.type=="text" then visible_cell=block.text:match("Script running with cell ID ([%w%-]+)") or visible_cell end end
        end end
        local report=mare.env("CODEMODE_ERROR_REPORT")
        if report then
          local seen = {}
          for _,message in ipairs(request.messages or {}) do
            if message.role=="tool_result" and (message.tool_name=="codemode" or message.tool_name=="codemode_wait") and message.is_error then
              local content=mare.json.encode_strict(message.content)
              seen[#seen+1] = {
                tool = message.tool_name,
                content = content,
                output = content:find("MODEL_PARTIAL_OUTPUT",1,true)~=nil,
                error = content:find("EXPECTED_SCRIPT_ERROR",1,true)~=nil,
              }
            end
          end
          if #seen > 0 then
            mare.fs.write(report,mare.json.encode_strict(seen))
          end
        end
        local notify_report=mare.env("CODEMODE_NOTIFY_REPORT")
        if notify_report then
          local encoded=mare.json.encode_strict(request.messages or {})
          if encoded:find("A_ASSOCIATED_NOTIFY",1,true) then
            mare.fs.write(notify_report,encoded)
          end
        end
        return ev.next(request)
      end)
    end}''', encoding="utf-8")
    env=os.environ.copy(); env['MARE_HOME']=str(base/'home')
    chain_report=base/'tool-result-chain.jsonl'; env['CODEMODE_CHAIN_REPORT']=str(chain_report)
    config=base/'home/config'; config.mkdir(parents=True)
    work=base/'work'; work.mkdir()
    (work/'README.md').write_text('read fixture\n', encoding="utf-8")
    (config/'init.lua').write_text(f'''mare.setup {{model="faux/echo"}}
mare.plugins.add {{ {{"test/codemode",url="{package.as_uri()}"}} }}
mare.plugin("mcp",{{servers={{fixture={{command={json.dumps(sys.executable)},args={{{json.dumps(str(ROOT/'tests/codemode/mock_mcp.py'))}}},tier="codemode",tools={{hidden="hidden"}},disabled_tools={{"blocked"}}}}}}}})
''', encoding="utf-8")
    for args in (['git','init','-q','-b','main'],['git','add','.'],['git','-c','user.name=test','-c','user.email=test@example.invalid','-c','commit.gpgsign=false','commit','-qm','fixture']):
        command(args,env,package)
    command([BIN,'plugin','sync'],env,work)
    def run(code, persistent=False, expect_error=False):
        script=base/'script.json'
        script.write_text(json.dumps([{'tool_calls':[{'name':'codemode','arguments':{'input':code}}]},{'text':'faux complete'}]), encoding="utf-8")
        env['MARE_FAUX_SCRIPT']=str(script)
        args=[BIN,'--yolo','-p','--json']
        if not persistent: args.append('--no-session')
        out=command(args+['exercise codemode'],env,work)
        results=[e['data']['item']['message'] for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and (e.get('data') or {}).get('item',{}).get('type')=='tool_call' and e['data']['item'].get('name')=='codemode']
        assert len(results)==1 and bool(results[0].get('is_error'))==expect_error,results
        return out
    out=run('local r=tools.probe_echo({n=9007199254740993,none=json.null,items=json.array()}); return {n=r.details.n,none=r.details.none,items=r.details.items}')
    assert '9007199254740993' in out and 'large intermediate sentinel' not in out, out
    assert '\\"items\\":[]' in out or '"items":[]' in out, out
    out=run('assert(not io and not os and not mare); assert(load("return 1")==json.null); print("safe VM"); return #ALL_TOOLS')
    assert 'safe VM' in out, out
    out=run('local ok,e=pcall(tools.probe_denied,{}); assert(not ok); return "permission refused"')
    assert 'permission refused' in out and 'DENIED TOOL RAN' not in out, out
    out=run('return tools.read({path="README.md"}).content',persistent=True)
    assert 'read fixture' in out and 'persist_failed' not in out, out
    out=run('while true do pcall(function() while true do end end) end',expect_error=True)
    assert 'instruction limit' in out, out
    out=run('return tools.codemode({input="return 1"})',expect_error=True)
    assert 'Script failed' in out, out
    out=run('local names={}; for _,d in ipairs(ALL_TOOLS) do if d.name:match("^mcp__") then names[#names+1]=d.name end end; assert(#names==1 and names[1]=="mcp__fixture__echo"); return tools[names[1]]({}).content')
    assert 'MCP isolated callback' in out,out
    # core MCP results carry structuredContent as a text block of content
    # (mcp/results.lua content_of: "structuredContent: {...}"), not as a field
    out=run('return tools.mcp__fixture__echo({}).content')
    assert re.search(r'structuredContent: \{\\?"answer\\?":42\}', out), out
    out=run('text({kind="text helper"}); text("ready"); exit(); error("must not run")')
    assert 'text helper' in out and not any((e.get('data',{}).get('item',{}).get('message') or {}).get('is_error') for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and e.get('data',{}).get('item',{}).get('type')=='tool_call'),out
    out=run('setTimeout(function() print("timer fired") end,10); local cancelled=setTimeout(function() print("BAD TIMER") end,20); clearTimeout(cancelled); sleep(40); return "timer complete"')
    assert any('timer fired' in json.dumps((e['data'].get('item',{}).get('message') or {})) and 'BAD TIMER' not in json.dumps((e['data'].get('item',{}).get('message') or {})) for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and e.get('data',{}).get('item',{}).get('type')=='tool_call'),out
    out=run('local r=parallel({{name="probe_echo",arguments={x=1}},{name="probe_echo",arguments={x=2}}}); return {r[1].details.x,r[2].details.x}')
    assert '[1,2]' in out,out
    report=base/'model-error.json';env['CODEMODE_ERROR_REPORT']=str(report)
    out=run('print("MODEL_PARTIAL_OUTPUT"); error("EXPECTED_SCRIPT_ERROR")',expect_error=True)
    seen=json.loads(report.read_text(encoding="utf-8"))
    assert len(seen)==1 and seen[0]['output'] and seen[0]['error'],seen
    assert 'faux complete' in out,out
    del env['CODEMODE_ERROR_REPORT']

    # Multi-block partial output + error seen by model, then model continues with another codemode call.
    report_multi=base/'model-error-multi.json';env['CODEMODE_ERROR_REPORT']=str(report_multi)
    script=base/'error-recover.json'
    script.write_text(json.dumps([
        {'tool_calls':[{'name':'codemode','arguments':{'input':'text("PARTIAL_TEXT_BLOCK"); print("PARTIAL_PRINT_LINE"); error("MULTI_ERR")'}}]},
        {'tool_calls':[{'name':'codemode','arguments':{'input':'return "recovered"'}}]},
        {'text':'recovered complete'},
    ]), encoding="utf-8")
    env['MARE_FAUX_SCRIPT']=str(script)
    out=command([BIN,'--yolo','-p','--json','--no-session','recover after multi-block partial error'],env,work)
    seen=json.loads(report_multi.read_text(encoding="utf-8"))
    assert len(seen)==1 and seen[0]['tool']=='codemode',seen
    assert 'PARTIAL_TEXT_BLOCK' in seen[0]['content'] and 'PARTIAL_PRINT_LINE' in seen[0]['content'] and 'MULTI_ERR' in seen[0]['content'],seen
    results=[e['data']['item']['message'] for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and (e.get('data') or {}).get('item',{}).get('type')=='tool_call']
    assert len(results)==2 and results[0]['is_error'] and not results[1]['is_error'] and 'recovered' in json.dumps(results[1]) and 'recovered complete' in out,out
    del env['CODEMODE_ERROR_REPORT']

    # Background cell partial output + error delivered via codemode_wait, then model continues.
    report_bg=base/'model-error-bg.json';env['CODEMODE_ERROR_REPORT']=str(report_bg)
    script=base/'bg-error-recover.json'
    script.write_text(json.dumps([
        {'tool_calls':[{'name':'codemode','arguments':{'input':'print("BG_BEFORE_GATE"); tools.probe_gate({id="auto_on_wait"}); print("BG_AFTER_GATE"); error("BG_EXPECTED_ERROR")','yield_time_ms':0}}]},
        {'tool_calls':[{'name':'codemode_wait','arguments':{'cell_id':'LAST_VISIBLE_CELL','yield_time_ms':10000}}]},
        {'tool_calls':[{'name':'codemode','arguments':{'input':'return "bg_recovered"'}}]},
        {'text':'bg recovered complete'},
    ]), encoding="utf-8")
    env['MARE_FAUX_SCRIPT']=str(script)
    out=command([BIN,'--yolo','-p','--json','--no-session','recover after background error'],env,work)
    seen=json.loads(report_bg.read_text(encoding="utf-8"))
    assert len(seen)==1 and seen[0]['tool']=='codemode_wait',seen
    assert 'BG_AFTER_GATE' in seen[0]['content'] and 'BG_EXPECTED_ERROR' in seen[0]['content'],seen
    results=[e['data']['item']['message'] for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and (e.get('data') or {}).get('item',{}).get('type')=='tool_call']
    assert len(results)==3 and results[0]['details']['status']=='running' and results[1]['is_error'] and not results[2]['is_error'] and 'bg_recovered' in json.dumps(results[2]),results
    assert 'bg recovered complete' in out,out
    del env['CODEMODE_ERROR_REPORT']

    # Instruction-limit failure after partial print preserved in model tool_result.content + model recovery.
    report_budget=base/'model-error-budget.json';env['CODEMODE_ERROR_REPORT']=str(report_budget)
    script=base/'budget-error-recover.json'
    script.write_text(json.dumps([
        {'tool_calls':[{'name':'codemode','arguments':{'input':'print("BUDGET_PARTIAL_OUTPUT"); while true do pcall(function() while true do end end) end'}}]},
        {'tool_calls':[{'name':'codemode','arguments':{'input':'return "budget_recovered"'}}]},
        {'text':'budget recovered complete'},
    ]), encoding="utf-8")
    env['MARE_FAUX_SCRIPT']=str(script)
    out=command([BIN,'--yolo','-p','--json','--no-session','recover after instruction limit with partial output'],env,work)
    seen=json.loads(report_budget.read_text(encoding="utf-8"))
    assert len(seen)==1 and seen[0]['tool']=='codemode',seen
    assert 'BUDGET_PARTIAL_OUTPUT' in seen[0]['content'] and 'instruction limit' in seen[0]['content'],seen
    results=[e['data']['item']['message'] for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and (e.get('data') or {}).get('item',{}).get('type')=='tool_call']
    assert len(results)==2 and results[0]['is_error'] and not results[1]['is_error'] and 'budget_recovered' in json.dumps(results[1]),results
    del env['CODEMODE_ERROR_REPORT']

    # Huge partial output before error under tight max_output_tokens keeps short error visible and output bounded.
    report_trunc=base/'model-error-trunc.json';env['CODEMODE_ERROR_REPORT']=str(report_trunc)
    script=base/'trunc-error-recover.json'
    script.write_text(json.dumps([
        {'tool_calls':[{'name':'codemode','arguments':{'input':'print("HEAD_" .. string.rep("Z",2000) .. "_TAIL"); error("TRUNCATED_BUT_ERROR_VISIBLE")','max_output_tokens':64}}]},
        {'tool_calls':[{'name':'codemode','arguments':{'input':'return "trunc_recovered"'}}]},
        {'text':'trunc recovered complete'},
    ]), encoding="utf-8")
    env['MARE_FAUX_SCRIPT']=str(script)
    out=command([BIN,'--yolo','-p','--json','--no-session','keep error bounded under tight max_output_tokens'],env,work)
    seen=json.loads(report_trunc.read_text(encoding="utf-8"))
    assert len(seen)==1 and seen[0]['tool']=='codemode',seen
    assert 'TRUNCATED_BUT_ERROR_VISIBLE' in seen[0]['content'] and '[script output truncated' in seen[0]['content'],seen
    results=[e['data']['item']['message'] for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and (e.get('data') or {}).get('item',{}).get('type')=='tool_call']
    assert len(results)==2 and results[0]['is_error'] and not results[1]['is_error'] and 'trunc_recovered' in json.dumps(results[1]),results
    del env['CODEMODE_ERROR_REPORT']
    out=run('assert(tools.probe_value({})==false); local values=parallel({{name="probe_value",arguments={}}});assert(values[1]==false); return json.decode(tools.probe_large({}).content[1].text).answer')
    assert '42' in out,out
    out=run('local ok=pcall(parallel,{{name=7}});assert(not ok);return "caught validation"')
    assert 'caught validation' in out,out
    out=run('local s=parallel({{name="probe_echo",arguments={a=1}},{name="probe_denied",arguments={}}},{settled=true}); assert(s[1].status=="fulfilled" and s[1].value.details.a==1 and s[2].status=="rejected"); local d=describe_tool("probe_echo"); assert(d.declaration and describe_tool("missing_tool")==json.null); return "settled+describe"')
    assert 'settled+describe' in out,out
    script=base/'store-load.json'
    script.write_text(json.dumps([
        {'tool_calls':[{'name':'codemode','arguments':{'input':'store("persist_key",{v=99}); return load("persist_key").v'}}]},
        {'tool_calls':[{'name':'codemode','arguments':{'input':'return load("persist_key").v'}}]},
        {'text':'store-load complete'},
    ]), encoding="utf-8")
    env['MARE_FAUX_SCRIPT']=str(script)
    out=command([BIN,'--yolo','-p','--json','--no-session','store and load across calls'],env,work)
    results=[e['data']['item']['message'] for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and (e.get('data') or {}).get('item',{}).get('type')=='tool_call']
    assert len(results)==2 and '99' in json.dumps(results[0]) and '99' in json.dumps(results[1]),results
    script=base/'background.json'
    script.write_text(json.dumps([{'tool_calls':[{'name':'codemode','arguments':{'input':'sleep(100);return "background survived"','yield_time_ms':0}}]},
        {'tool_calls':[{'name':'codemode_wait','arguments':{'cell_id':'LAST_VISIBLE_CELL','yield_time_ms':10000}}]},{'text':'background complete'}]), encoding="utf-8")
    env['MARE_FAUX_SCRIPT']=str(script)
    out=command([BIN,'--yolo','-p','--json','--no-session','run and wait a background script'],env,work)
    results=[e['data']['item']['message'] for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and (e.get('data') or {}).get('item',{}).get('type')=='tool_call']
    assert len(results)==2 and results[0]['details']['status']=='running' and results[1]['details']['status']=='completed',results
    assert 'background survived' in json.dumps(results[1]) and 'background complete' in out,out
    script=base/'terminate.json'
    script.write_text(json.dumps([{'tool_calls':[{'name':'codemode','arguments':{'input':'-- @exec:{"yield_time_ms":0}\nwhile true do sleep(20) end'}}]},
        {'tool_calls':[{'name':'codemode_wait','arguments':{'cell_id':'LAST_VISIBLE_CELL','terminate':True}}]},
        {'tool_calls':[{'name':'codemode_wait','arguments':{'cell_id':'LAST_VISIBLE_CELL','yield_time_ms':0}}]},
        {'text':'terminate complete'}]), encoding="utf-8")
    env['MARE_FAUX_SCRIPT']=str(script)
    out=command([BIN,'--yolo','-p','--json','--no-session','terminate a background script'],env,work)
    results=[e['data']['item']['message'] for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and (e.get('data') or {}).get('item',{}).get('type')=='tool_call']
    assert (
        len(results) == 3
        and results[0]['details']['status'] == 'running'
        and results[1]['details']['status'] in ('cancelled', 'terminated')
        and results[2]['is_error']
        and 'unknown_cell' in json.dumps(results[2]['content'])
    ), results
    assert 'terminate complete' in out,out

    # Truncated error content must not re-append untruncated cell.error in model-facing tool_result.
    report_trunc=base/'model-error-trunc.json';env['CODEMODE_ERROR_REPORT']=str(report_trunc)
    run('-- @exec:{"max_output_tokens":8}\nerror("LONG_ERR_"..string.rep("E",400).."_TAIL_SENTINEL")',expect_error=True)
    seen_trunc=json.loads(report_trunc.read_text(encoding="utf-8"))
    assert len(seen_trunc)==1,seen_trunc
    # Under an 8-token budget the error is reserved first, so the bounded
    # error survives and there is no room for the content truncation marker
    assert 'runtime error' in seen_trunc[0]['content'],seen_trunc
    assert '_TAIL_SENTINEL' not in seen_trunc[0]['content'],seen_trunc
    del env['CODEMODE_ERROR_REPORT']

    # Cross-cell store/load snapshot isolation and independent output cursors via text()+yield_control() + notify() + probe_gate.
    notify_report=base/'notify-report.json';env['CODEMODE_NOTIFY_REPORT']=str(notify_report)
    script=base/'cross-cell-isolation.json'
    script.write_text(json.dumps([
        {'tool_calls':[{'name':'codemode','arguments':{'input':'store("snap_k",{v=1}); store("snap_other",{v=10}); return "seeded"'}}]},
        {'tool_calls':[{'name':'codemode','arguments':{'input':'store("snap_k",{v=999}); text("A_PARTIAL_BEFORE"); notify("A_ASSOCIATED_NOTIFY"); tools.probe_gate({id="auto_on_wait"}); print("A_PARTIAL_AFTER"); return {own=load("snap_k").v, other=load("snap_other").v}','yield_time_ms':5000}}]},
        {'tool_calls':[{'name':'codemode','arguments':{'input':'local seen_k=load("snap_k").v; store("snap_k",{v=2}); store("snap_other",{v=20}); print("B_CELL_OUTPUT"); return {seen_k=seen_k}'}}]},
        {'tool_calls':[{'name':'codemode_wait','arguments':{'cell_id':'LAST_VISIBLE_CELL','yield_time_ms':5000}}]},
        {'text':'isolation complete'},
    ]), encoding="utf-8")
    env['MARE_FAUX_SCRIPT']=str(script)
    out=command([BIN,'--yolo','-p','--json','--no-session','cross-cell store snapshot and cursor isolation'],env,work)
    del env['CODEMODE_NOTIFY_REPORT']
    results=[e['data']['item']['message'] for e in map(json.loads,out.splitlines()) if e.get('type')=='item/completed' and (e.get('data') or {}).get('item',{}).get('type')=='tool_call']
    assert len(results)==4,results
    a_start, b_res, a_wait = results[1], results[2], results[3]
    a_start_json=json.dumps(a_start['content'])
    assert a_start['details']['status']=='running' and 'A_PARTIAL_BEFORE' in a_start_json and 'A_ASSOCIATED_NOTIFY' not in a_start_json,a_start
    b_res_json=json.dumps(b_res['content'])
    assert b_res['details']['status']=='completed' and b_res['details']['result']=={'seen_k':1} and 'B_CELL_OUTPUT' in b_res_json and 'A_PARTIAL_BEFORE' not in b_res_json and 'A_ASSOCIATED_NOTIFY' not in b_res_json,b_res
    a_wait_json=json.dumps(a_wait['content'])
    assert a_wait['details']['status']=='completed' and 'A_PARTIAL_AFTER' in a_wait_json and a_wait['details']['result']=={'own':999,'other':10},a_wait
    assert 'A_PARTIAL_BEFORE' not in a_wait_json and 'B_CELL_OUTPUT' not in a_wait_json and 'A_ASSOCIATED_NOTIFY' not in a_wait_json,a_wait
    assert notify_report.exists() and 'A_ASSOCIATED_NOTIFY' in notify_report.read_text(encoding="utf-8"), 'notify output did not reach model request'

    # Ordered parallel slow-first/fast-second, write exclusivity, and dynamic tool/before policy change mid-script.
    out=run('local r=parallel({{name="probe_gate",arguments={id="order_p"}},{name="probe_release",arguments={id="order_p",result_id="second"}}}); local log=r[1].details.log; local ri,ei; for i,v in ipairs(log) do if v=="order_p:release_exit" then ri=i elseif v=="order_p:exit" then ei=i end end; assert(r[1].details.id=="order_p" and r[2].details.id=="second" and ri and ei and ri<ei); return "ordered_parallel_ok"')
    assert 'ordered_parallel_ok' in out,out
    w1=str(base/'w1.txt').replace('\\','\\\\'); w2=str(base/'w2.txt').replace('\\','\\\\')
    out=run(f'local r=parallel({{{{name="probe_write_track",arguments={{id="w1",path="{w1}"}}}},{{name="probe_write_track",arguments={{id="w2",path="{w2}"}}}}}}); assert(r[1].details.max_writes==1 and r[2].details.max_writes==1); return r[2].details.log')
    assert 'w1:enter' in out and 'w1:exit' in out and 'w2:enter' in out and 'w2:exit' in out,out
    out=run('local ok1,r1=pcall(tools.probe_dynamic_policy,{phase="one",flip=true}); local ok2,e2=pcall(tools.probe_dynamic_policy,{phase="two"}); assert(ok1 and (r1.content=="dynamic:one" or (type(r1.content)=="table" and r1.content[1].text=="dynamic:one")) and not ok2); return "dynamic_policy_ok"')
    assert 'dynamic_policy_ok' in out,out

    records='\n'.join(p.read_text(encoding="utf-8") for p in (base/'home').rglob('*.jsonl'))
    assert 'tool/nested-result' in records and '/nested/' in records, records
    # every tool/result the probe saw reached its downstream listener with the same call and budget
    chain=[json.loads(line) for line in chain_report.read_text(encoding="utf-8").splitlines()]
    assert chain and all(r['result'] and r['same_call'] and r['same_budget'] and r['budget'] for r in chain), chain
    assert any(r['tool']=='codemode' for r in chain), chain
print('codemode file:// faux: JSON/null/array, capabilities, permissions, nested persistence, CPU budget and recursion passed')
