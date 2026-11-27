-- Independent stdlib-only Node adapter for the installed official mmdc. PNG stays a Buffer
-- until base64 encoding; mare.proc's UTF-8 stdout decoder never sees binary data.
return [====[
const {spawn} = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const MAX_PNG = 8 * 1024 * 1024;
let active;
const renderer = process.argv[1];
let entry = process.argv[2];
function command() {
  if (entry) return [process.execPath, [entry]];
  if (process.platform === 'win32') {
    for (const directory of (process.env.PATH || '').split(path.delimiter)) {
      const candidate = path.join(directory,'node_modules','@mermaid-js','mermaid-cli','src','cli.js');
      if (fs.existsSync(candidate)) return [process.execPath,[candidate]];
    }
  }
  return [renderer, []];
}
function run(args, limit, timeoutMs, maxHeapMb) {
  return new Promise((resolve,reject) => {
    const [executable,prefix] = command();
    const env = { ...process.env };
    if (Number.isInteger(maxHeapMb) && maxHeapMb >= 128 && maxHeapMb <= 4096) {
      const opt = `--max-old-space-size=${maxHeapMb}`;
      const existing = env.NODE_OPTIONS || '';
      if (!existing.includes('--max-old-space-size')) {
        env.NODE_OPTIONS = existing ? `${existing} ${opt}` : opt;
      }
    }
    const child = spawn(executable,[...prefix,...args],{stdio:['pipe','pipe','pipe'],shell:false,env});
    active = child;
    const output = [], errors = [];
    let size=0, errorSize=0, exceeded=false, timedOut=false;
    let killTimer;
    const watchdog = Number.isInteger(timeoutMs) && timeoutMs > 0 ? setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      killTimer = setTimeout(() => { if (active === child) child.kill('SIGKILL'); }, 500);
    }, timeoutMs) : undefined;
    child.on('error', err => {
      if (watchdog) clearTimeout(watchdog);
      if (killTimer) clearTimeout(killTimer);
      reject(err);
    });
    child.stdout.on('data',chunk => {
      size += chunk.length;
      if (size > limit) { exceeded=true; child.kill('SIGTERM'); }
      else output.push(chunk);
    });
    child.stderr.on('data',chunk => {
      if (errorSize < 65536) { const part=chunk.subarray(0,65536-errorSize); errors.push(part); errorSize+=part.length; }
    });
    child.on('close',(code,signal) => {
      if (watchdog) clearTimeout(watchdog);
      if (killTimer) clearTimeout(killTimer);
      active=undefined;
      const stderr=Buffer.concat(errors).toString('utf8');
      if (timedOut) return reject(new Error('Renderer exceeded timeout limit.'));
      if (exceeded) return reject(new Error('Renderer output exceeds the byte limit.'));
      if (code !== 0) return reject(new Error(`Renderer exited ${code === null ? signal : code}: ${stderr.slice(0,4096)}`));
      resolve({bytes:Buffer.concat(output),stderr});
    });
    child.stdin.on('error',()=>{});
    child.stdin.end(args.includes('--version') ? undefined : source);
  });
}
let source;
const input=[];
let inputSize=0;
process.stdin.on('data',chunk=>{
  inputSize+=chunk.length;
  if(inputSize>512*1024) { process.stderr.write('Renderer input exceeds limit.'); process.exit(1); }
  input.push(chunk);
});
process.stdin.on('end',async()=>{
  try {
    const request=JSON.parse(Buffer.concat(input).toString('utf8'));
    source=request.source;
    const profile=request.profile;
    const timeoutMs=request.timeout_ms;
    const maxHeapMb=request.max_heap_mb;
    const maxEdges=Number.isInteger(request.max_edges) && request.max_edges >= 1 && request.max_edges <= 20000 ? request.max_edges : 200;
    if(typeof source!=='string' || Buffer.byteLength(source)>65536) throw new Error('Invalid renderer source.');
    if(!profile || !Number.isInteger(profile.size_px) || profile.size_px<64 || profile.size_px>2048 || ![1,2].includes(profile.scale)) throw new Error('Invalid renderer geometry.');
    if(!['dark','default'].includes(profile.theme) || !/^(transparent|#[a-fA-F0-9]{6})$/.test(profile.background)) throw new Error('Invalid renderer theme.');
    const version=(await run(['--version'],4096,timeoutMs,maxHeapMb)).bytes.toString('utf8').trim();
    if(!/^(1[2-9]|[2-9][0-9])\./.test(version)) throw new Error(`mmdc >=12 is required for the fixed PNG stdout protocol (found ${version}).`);
    const cfgDir=fs.mkdtempSync(path.join(os.tmpdir(),'mare-mermaid-'));
    let result;
    try {
      const cfgPath=path.join(cfgDir,'config.json');
      const hardened={
        securityLevel:'strict',
        htmlLabels:false,
        flowchart:{htmlLabels:false},
        class:{htmlLabels:false},
        themeCSS:'',
        maxEdges:maxEdges,
        secure:['secure','securityLevel','startOnLoad','maxTextSize','maxEdges','htmlLabels','themeCSS']
      };
      fs.writeFileSync(cfgPath,JSON.stringify(hardened));
      result=await run(['-i','-','-o','-','-e','png','-q','-j','1','-c',cfgPath,'-t',profile.theme,'-b',profile.background,'--size',String(profile.size_px),'-s',String(profile.scale)],MAX_PNG,timeoutMs,maxHeapMb);
    } finally {
      fs.rmSync(cfgDir,{recursive:true,force:true});
    }
    const png=result.bytes;
    if(png.length<33 || !png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])) || png.toString('ascii',12,16)!=='IHDR') throw new Error('Renderer did not return PNG.');
    const width=png.readUInt32BE(16),height=png.readUInt32BE(20);
    if(!width || !height || width>4096 || height>4096 || width*height>16777216) throw new Error('Renderer PNG dimensions exceed limit.');
    process.stdout.write(JSON.stringify({png:png.toString('base64'),version,width,height}));
  } catch(error) { process.stderr.write(String(error.message).slice(0,8192)); process.exitCode=1; }
});
for(const signal of ['SIGTERM','SIGINT']) process.on(signal,()=>{
  if(active) active.kill(signal);
  process.exit(128+(signal==='SIGTERM'?15:2));
});
]====]
