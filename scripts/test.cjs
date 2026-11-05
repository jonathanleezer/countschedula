const {spawnSync}=require('node:child_process');
const {resolve}=require('node:path');
process.chdir(resolve(__dirname,'..'));
const checks=[['--check','dist/app.js'],['--check','scripts/serve.cjs'],['--check','dist/cloud.js'],['--check','scripts/build.cjs'],['check.cjs'],['check-shifts.cjs'],['check-organizations.cjs'],['check-rotations.cjs']];
for(const args of checks){const r=spawnSync(process.execPath,args,{stdio:'inherit'});if(r.error){console.error(r.error.message);process.exit(1)}if(r.status!==0)process.exit(r.status||1)}
console.log('All baseline checks passed. Browser acceptance is documented in docs/ACCEPTANCE.md.');
