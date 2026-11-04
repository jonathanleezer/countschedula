const http=require('node:http');
const fs=require('node:fs/promises');
const path=require('node:path');
const root=path.resolve(__dirname,'../dist');
const {configScript}=require('./config.cjs');
const port=Number(process.env.PORT||3000);
if(!Number.isInteger(port)||port<1||port>65535)throw Error('PORT must be an integer from 1 to 65535');
const types={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.json':'application/json; charset=utf-8','.svg':'image/svg+xml','.png':'image/png','.ico':'image/x-icon'};
const server=http.createServer(async(req,res)=>{
 if(!['GET','HEAD'].includes(req.method)){res.writeHead(405,{'Allow':'GET, HEAD'});return res.end()}
 try{
  const url=new URL(req.url,'http://localhost');
  const pathname=decodeURIComponent(url.pathname);
  if(pathname==='/config.js'){res.writeHead(200,{'Content-Type':'text/javascript; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});return res.end(req.method==='HEAD'?undefined:configScript())}
  const target=path.resolve(root,'.'+(pathname==='/'?'/index.html':pathname));
  if(target!==root&&!target.startsWith(root+path.sep)){res.writeHead(403);return res.end('Forbidden')}
  const data=await fs.readFile(target);
  res.writeHead(200,{'Content-Type':types[path.extname(target)]||'application/octet-stream','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});
  res.end(req.method==='HEAD'?undefined:data);
 }catch(e){res.writeHead(e.code==='ENOENT'||e.code==='EISDIR'?404:400);res.end('Not found')}
});
server.on('error',error=>{console.error('Could not start CountSchedula: '+error.message);process.exitCode=1});
server.listen(port,'127.0.0.1',()=>console.log(`CountSchedula: http://localhost:${port} (Ctrl+C to stop)`));
