"""Large enabled schemas stay on the host; a script discovers and calls one tool."""
import importlib.util
import os
import pathlib
import sys
import tempfile

sys.dont_write_bytecode=True
ROOT=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('mare_rpc_client',os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pty", "rpc_client.py"))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='mare-script-catalog-') as tmp:
    base=pathlib.Path(tmp);(base/'home/config').mkdir(parents=True)
    (base/'home/config/init.lua').write_text('mare.setup {model="faux/echo"}\n', encoding="utf-8")
    env=os.environ.copy();env['MARE_HOME']=str(base/'home')
    client=module.Client([os.environ['MARE_BIN'],'--rpc','--no-session','--yolo'],env,base)
    try:
        sid=client.call('initialize',{'protocol_version':'3.0','capabilities':{'tools':True,'callbacks':True}})['session']['session_id']
        names=[f'catalog_{n}' for n in range(100)]
        for name in names:
            client.call('tools.register', {
                'name': name,
                'description': f'fixture {name}',
                'parameters': {'type': 'object', 'properties': {'input': {'type': 'string', 'description': 'x' * 20000}}},
                'side_effect': 'read',
                'callbacks': ['execute'],
            })
        result=client.call('cells.start',{'session_id':sid,'cell_id':'catalog','capabilities':names,'code':'''assert(#ALL_TOOLS==100)
for _,entry in ipairs(ALL_TOOLS) do
  for key in pairs(entry) do assert(key=="name" or key=="description") end
end
local chosen=describe_tool("catalog_50")
assert(#chosen.parameters.properties.input.description==20000)
assert(chosen.declaration:find("tools[",1,true))
assert(describe_tool("not_declared")==json.null)
return tools.catalog_50({}).content'''})
        assert result['result']=='ok' and result['status']=='completed',result
        assert len(client.tool_calls)==1 and client.tool_calls[0]['name']=='catalog_50',client.tool_calls
        client.call('shutdown');client.p.stdin.close();assert client.p.wait(timeout=15)==0
    finally:
        if client.p.poll() is None:client.p.kill();client.p.wait()
print('large catalog: 2MB schema set, summary-only ALL_TOOLS, on-demand schema and real nested call passed')
