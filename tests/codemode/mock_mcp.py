import json
import sys

for line in sys.stdin:
    message=json.loads(line)
    if 'id' not in message: continue
    method=message.get('method')
    if method=='initialize':
        result={'protocolVersion':message['params']['protocolVersion'],'capabilities':{'tools':{}},'serverInfo':{'name':'codemode-test','version':'1'}}
    elif method=='tools/list':
        result={'tools':[{'name':name,'description':name,'inputSchema':{'type':'object'},'outputSchema':{'type':'object','properties':{'answer':{'type':'integer'}},'required':['answer']},'annotations':{'readOnlyHint':True}} for name in ('echo','hidden','blocked')]}
    elif method=='tools/call': result={'content':[{'type':'text','text':'MCP isolated callback'}],'structuredContent':{'answer':42}}
    else:
        print(json.dumps({'jsonrpc':'2.0','id':message['id'],'error':{'code':-32601,'message':'unsupported'}}),flush=True);continue
    print(json.dumps({'jsonrpc':'2.0','id':message['id'],'result':result}),flush=True)
