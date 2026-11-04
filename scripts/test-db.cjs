// Runs the Supabase migrations and database tests against a throwaway local PostgreSQL cluster.
// Requires PostgreSQL server binaries (initdb, pg_ctl) and psql. Nothing touches the hosted project.
const {spawnSync}=require('node:child_process');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const root=path.resolve(__dirname,'..');

function findBin(name){
  const dirs=[process.env.PG_BIN,...(fs.existsSync('/usr/lib/postgresql')?fs.readdirSync('/usr/lib/postgresql').sort().reverse().map(v=>`/usr/lib/postgresql/${v}/bin`):[]),'/opt/homebrew/bin','/usr/local/bin','/usr/bin'].filter(Boolean);
  for(const d of dirs){const p=path.join(d,name);if(fs.existsSync(p))return p}
  return null;
}
const initdb=findBin('initdb'),pgctl=findBin('pg_ctl'),psql=findBin('psql');
if(!initdb||!pgctl||!psql){console.error('test:db needs PostgreSQL server binaries (initdb, pg_ctl, psql). Set PG_BIN to their directory.');process.exit(1)}

const dir=fs.mkdtempSync(path.join(os.tmpdir(),'countschedula-pg-'));
const data=path.join(dir,'data'),sock=dir,port=String(54000+Math.floor(Math.random()*900));
const run=(cmd,args,opts={})=>{const r=spawnSync(cmd,args,{encoding:'utf8',...opts});if(r.status!==0){process.stdout.write(r.stdout||'');process.stderr.write(r.stderr||'');throw Error(`${path.basename(cmd)} failed`)}return r};
const asUser=process.getuid&&process.getuid()===0?['-u','postgres']:null; // postgres refuses to run as root
const exec=(cmd,args,opts)=>asUser?run('runuser',[...asUser,'--',cmd,...args],opts):run(cmd,args,opts);
let started=false;
try{
  if(asUser)fs.chownSync(dir,...ids('postgres'));
  exec(initdb,['-D',data,'-U','postgres','-A','trust','--no-sync','-E','UTF8']);
  exec(pgctl,['-D',data,'-o',`-k ${sock} -p ${port} -c listen_addresses=''`,'-w','-l',path.join(dir,'log'),'start']);
  started=true;
  const base=['-X','-q','-t','-A','-v','ON_ERROR_STOP=1','-h',sock,'-p',port,'-U','postgres','-d','postgres'];
  exec(psql,[...base,'-f',path.join(root,'supabase/tests/supabase-stub.sql')]);
  const migrations=fs.readdirSync(path.join(root,'supabase/migrations')).filter(f=>f.endsWith('.sql')).sort();
  for(const m of migrations)exec(psql,[...base,'-f',path.join(root,'supabase/migrations',m)]);
  console.log(`Applied ${migrations.length} migrations.`);
  const sample=fs.readFileSync(path.join(root,'sample-data/sample-workspace.json'),'utf8');
  const sampleFile=path.join(dir,'sample.json');fs.writeFileSync(sampleFile,sample);if(asUser)fs.chownSync(sampleFile,...ids('postgres'));
  const r=exec(psql,[...base,'-v',`sample=${JSON.stringify(JSON.parse(sample))}`,'-f',path.join(root,'supabase/tests/domain.test.sql')]);
  const oks=(r.stderr.match(/NOTICE: {2}ok - .*/g)||[]);
  for(const line of oks)console.log('  '+line.replace(/^NOTICE: {2}/,''));
  process.stdout.write(r.stdout.split('\n').filter(l=>l.trim()&&!/^[-+ ]*$|^ *(t_assert|expect_fail|t_login|t_save|invite_member|cs_bootstrap_workspace)/.test(l)&&!/^\(\d+ rows?\)/.test(l)&&!/^ *[{\[]/.test(l)).join('\n')+'\n');
}catch(e){console.error(e.message);process.exitCode=1}
finally{
  if(started)try{exec(pgctl,['-D',data,'-m','fast','-w','stop'])}catch{}
  fs.rmSync(dir,{recursive:true,force:true});
}
function ids(user){const r=spawnSync('id',['-u',user],{encoding:'utf8'}),g=spawnSync('id',['-g',user],{encoding:'utf8'});return [Number(r.stdout),Number(g.stdout)]}
