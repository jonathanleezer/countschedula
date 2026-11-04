// Browser acceptance checks for the local (browser-only) mode. Starts its own server on a free port.
// Requires Playwright with Chromium (npm i -D playwright && npx playwright install chromium if missing).
let chromium;try{({chromium}=require('playwright'))}catch{console.error('test:browser needs Playwright: npm i -D playwright && npx playwright install chromium');process.exit(1)}
const {spawn}=require('node:child_process'),path=require('node:path'),fs=require('node:fs'),os=require('node:os');
const port=String(41000+Math.floor(Math.random()*2000)),URL=`http://localhost:${port}/`;
const env={...process.env,PORT:port};for(const k of ['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','SUPABASE_ANON_KEY'])delete env[k];
const server=spawn(process.execPath,[path.resolve(__dirname,'serve.cjs')],{env,stdio:'ignore'});
const out=fs.mkdtempSync(path.join(os.tmpdir(),'countschedula-shots-'));
const results=[];const ok=(n,c,d='')=>{results.push([c?'PASS':'FAIL',n,d]);};
const finish=code=>{server.kill();for(const r of results)console.log(r.join('  '));const f=results.filter(r=>r[0]==='FAIL').length;console.log(f+' failures of '+results.length+' · screenshots: '+out);process.exit(code||(f?1:0))};
(async()=>{
await new Promise(r=>setTimeout(r,400));
const b=await chromium.launch();
const ctx=await b.newContext({viewport:{width:1366,height:900}});const p=await ctx.newPage();
const errors=[];p.on('pageerror',e=>errors.push(e.message));p.on('console',m=>{if(m.type()==='error')errors.push(m.text())});
await p.goto(URL);await p.waitForSelector('.calendar');
// 1 branding/default
ok('Brand + workspace',(await p.textContent('.brand')).includes('CountSchedula')&&(await p.textContent('.workspace')).includes('Vanderbilt Midwives'));
ok('Jones Team default selected',await p.evaluate(()=>JSON.stringify(selectedOrgs)==='["willow"]'));
ok('No Willow/Riverside in UI',!/Willow|Riverside/.test(await p.textContent('body')));
const n0=await p.evaluate(()=>state.assignments.length);
ok('Initial generation 60 Jones assignments, all covered',n0===60&&await p.evaluate(()=>coverageMissing('willow').length===0&&validateAll().length===0),`count=${n0}`);
ok('Persisted to localStorage',await p.evaluate(()=>!!localStorage.getItem(KEY)));
await p.screenshot({path:out+'/01-schedule-jones.png'});
// 2 org multiselect
const snap=await p.evaluate(()=>JSON.stringify(state.assignments));
await p.click('.org-picker summary');
await p.check('.org-picker input[value="river"]');
ok('Both orgs displayed',await p.evaluate(()=>selectedOrgs.length===2)&&await p.locator('.org-lane[data-dept="river"]').count()>0&&await p.locator('.org-lane[data-dept="willow"]').count()>0);
ok('Picker stays open after toggle',await p.evaluate(()=>$('.org-picker').open));
await p.screenshot({path:out+'/02-both-orgs.png'});
await p.uncheck('.org-picker input[value="willow"]');
ok('Boehm only',await p.evaluate(()=>JSON.stringify(selectedOrgs)==='["river"]')&&await p.locator('.org-lane[data-dept="willow"]').count()===0);
await p.click('.org-picker input[value="river"]');await p.waitForTimeout(100);
ok('Zero selection prevented',await p.evaluate(()=>selectedOrgs.length===1)&&await p.isChecked('.org-picker input[value="river"]'));
ok('Display change did not mutate assignments',await p.evaluate(s=>JSON.stringify(state.assignments)===s,snap));
await p.check('.org-picker input[value="willow"]');
await p.mouse.click(5,890); // outside click closes picker
ok('Picker closes on outside click',await p.evaluate(()=>!$('.org-picker').open));
// 4 open Boehm slot while target is Jones
await p.locator('.org-lane[data-dept="river"] .assignment.open').first().click();
await p.waitForSelector('#modal[open]');
const dsel=await p.inputValue('#modal select[name=department]');
const provs=await p.$$eval('#modal select[name=provider] option',o=>o.map(x=>x.textContent));
ok('Boehm slot editor defaults to Boehm',dsel==='river',dsel);
ok('Only Boehm-affiliated providers listed',JSON.stringify(provs)===JSON.stringify(['Emma Wilson','Sarah Chen','Olivia Brooks']),provs.join(','));
await p.screenshot({path:out+'/03-boehm-editor.png'});
// pick a provider with no conflict: try each
let saved=false;
for(const name of provs){await p.selectOption('#modal select[name=provider]',{label:name});const before=await p.evaluate(()=>state.assignments.length);await p.click('#modal button.primary');await p.waitForTimeout(150);const after=await p.evaluate(()=>state.assignments.length);if(after===before+1){saved=true;break}}
const lastErr=await p.textContent('#formerror').catch(()=>'');
ok('Save to Boehm (or explained block)',saved?await p.evaluate(()=>state.assignments.at(-1).dept==='river'):lastErr.length>0,saved?'saved':lastErr);
if(!saved)await p.click('#modal button:has-text("Cancel")');
// edit existing via keyboard Enter
const first=p.locator('.org-lane[data-dept="willow"] .assignment[data-assignment]').first();
await first.focus();await p.keyboard.press('Enter');
ok('Keyboard Enter opens editor',await p.isVisible('#modal[open]')&&(await p.textContent('#modal h2'))==='Edit assignment');
await p.fill('#modal textarea[name=note]','smoke note');await p.click('#modal button.primary');await p.waitForTimeout(100);
ok('Edit note saved',await p.evaluate(()=>state.assignments.some(a=>a.note==='smoke note')));
// conflict via form: put same provider in an overlapping Boehm slot
const conflict=await p.evaluate(()=>{let a=state.assignments.find(a=>a.provider==='p0'&&a.dept==='willow');assignmentDialog(null,a.date,a.shift,'p0','river');return a.date});
await p.click('#modal button.primary');await p.waitForTimeout(100);
const ferr=await p.textContent('#formerror');
ok('Cross-org overlap blocked w/ explanation',/Overlapping|rest/i.test(ferr),ferr);
await p.click('#modal button:has-text("Cancel")');
// drag/drop: move an assignment to another day (expect either move or explained block)
const dragId=await p.evaluate(()=>state.assignments.find(a=>a.dept==='willow'&&a.date==='2026-11-05').id);
const before=await p.evaluate(id=>JSON.stringify(state.assignments.find(a=>a.id===id)),dragId);
await p.dragAndDrop(`[data-assignment="${dragId}"]`,'.org-lane[data-dept="river"][data-date="2026-11-20"]');
await p.waitForTimeout(200);
const afterA=await p.evaluate(id=>JSON.stringify(state.assignments.find(a=>a.id===id)),dragId);
const toast=await p.textContent('#toast');
ok('Drag/drop moves or explains block',(before!==afterA&&/moved/i.test(toast))||(before===afterA&&/blocked/i.test(toast)),`${before===afterA?'unchanged':'moved'} · toast="${toast}"`);
// 5 shift configuration
await p.evaluate(()=>navigate('Shift types'));
ok('Six shift types listed',await p.locator('tbody tr').count()===6);
await p.click('button:has-text("+ Add shift type")');
await p.fill('#modal input[name=name]','Late Triage');await p.fill('#modal input[name=start]','21:00');await p.fill('#modal input[name=end]','03:00');await p.fill('#modal input[name=coverage]','1');
await p.click('#modal button.primary');await p.waitForTimeout(100);
const lt=await p.evaluate(()=>{let t=state.shiftTypes.find(t=>t.name==='Late Triage');return t&&{h:shiftHours(t.id),id:t.id}});
ok('Custom overnight type saved with 6h duration',lt&&lt.h===6,JSON.stringify(lt));
ok('Shift table shows +1 day',(await p.textContent('tbody')).includes('(+1 day)'));
await p.screenshot({path:out+'/04-shift-types.png'});
await p.evaluate(()=>navigate('Schedule'));
ok('New type creates open slots',await p.locator('.assignment.open:has-text("Late Triage")').count()>0);
// equal times rejected
await p.evaluate(()=>navigate('Shift types'));await p.click('button:has-text("+ Add shift type")');
await p.fill('#modal input[name=name]','Bad');await p.fill('#modal input[name=start]','07:00');await p.fill('#modal input[name=end]','07:00');await p.click('#modal button.primary');await p.waitForTimeout(100);
ok('Equal start/end rejected',(await p.textContent('#formerror')).length>0,await p.textContent('#formerror'));
await p.click('#modal button:has-text("Cancel")');
// reload persistence
const cnt=await p.evaluate(()=>state.assignments.length);await p.reload();await p.waitForSelector('.calendar');
ok('Reload keeps workspace; display resets to Jones',await p.evaluate(c=>state.assignments.length===c&&state.shiftTypes.length===7&&selectedOrgs.join()==='willow',cnt));
ok('No JS errors (desktop)',errors.length===0,errors.join(' | '));
// mobile
const m=await b.newContext({viewport:{width:390,height:844},hasTouch:true,isMobile:true});const mp=await m.newPage();const merr=[];mp.on('pageerror',e=>merr.push(e.message));
await mp.goto(URL);await mp.waitForSelector('.calendar');
ok('Menu toggle visible on mobile',await mp.isVisible('#menuToggle'));
const sbHidden=async()=>{const r=await mp.$eval('#sidebar',e=>e.getBoundingClientRect());return r.right<=0||r.left>=390};
ok('Sidebar hidden initially',await sbHidden());
await mp.tap('#menuToggle');await mp.waitForTimeout(400);
ok('Sidebar opens; aria-expanded=true',!(await sbHidden())&&(await mp.getAttribute('#menuToggle','aria-expanded'))==='true');
await mp.screenshot({path:out+'/05-mobile-open.png'});
await mp.tap('#nav button:has-text("Providers")');await mp.waitForTimeout(400);
ok('Closes after navigation',await mp.evaluate(()=>!document.body.classList.contains('sidebar-open'))&&(await mp.textContent('#breadcrumb')).includes('Providers'));
await mp.tap('#menuToggle');await mp.waitForTimeout(300);await mp.tap('.sidebar-close');await mp.waitForTimeout(300);
ok('Closes via close button',await mp.evaluate(()=>!document.body.classList.contains('sidebar-open')));
await mp.tap('#menuToggle');await mp.waitForTimeout(300);await mp.mouse.click(380,500);await mp.waitForTimeout(300);
ok('Closes via outside (backdrop) click',await mp.evaluate(()=>!document.body.classList.contains('sidebar-open')));
await mp.tap('#menuToggle');await mp.waitForTimeout(300);await mp.keyboard.press('Escape');await mp.waitForTimeout(300);
ok('Closes via Escape and refocuses toggle',await mp.evaluate(()=>!document.body.classList.contains('sidebar-open')&&document.activeElement.id==='menuToggle'));
await mp.evaluate(()=>navigate('Schedule'));await mp.waitForTimeout(200);
const sw=await mp.evaluate(()=>document.documentElement.scrollWidth);
ok('No horizontal page overflow on 390px',sw<=390,`scrollWidth=${sw}`);
await mp.screenshot({path:out+'/06-mobile-schedule.png',fullPage:false});
ok('No JS errors (mobile)',merr.length===0,merr.join(' | '));
// restore must reject injection-shaped IDs (regression for the KNOWN-GAPS import finding)
const ip=await (await b.newContext()).newPage();await ip.goto(URL);await ip.waitForSelector('.calendar');
const evil=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../sample-data/sample-workspace.json'),'utf8'));
const bad='p0"><img src=x onerror="window.__pwn=1">';evil.assignments.forEach(a=>{if(a.provider===evil.providers[0].id)a.provider=bad});evil.providers[0].id=bad;
const evilFile=path.join(out,'evil.json');fs.writeFileSync(evilFile,JSON.stringify(evil));
await ip.evaluate(()=>navigate('Settings'));await ip.locator('input[type=file]').setInputFiles(evilFile);await ip.waitForTimeout(400);
const itoast=await ip.textContent('#toast');await ip.evaluate(()=>navigate('Schedule'));await ip.waitForTimeout(300);
ok('Restore rejects injection-shaped IDs',/not a valid/.test(itoast)&&!(await ip.evaluate(()=>window.__pwn===1)),itoast);
await ip.locator('body').evaluate(()=>navigate('Settings'));await ip.locator('input[type=file]').setInputFiles(path.resolve(__dirname,'../sample-data/sample-workspace.json'));await ip.waitForTimeout(400);
ok('Restore still accepts the sample backup',(await ip.textContent('#toast')).includes('Backup restored'));
await b.close();
finish(0);
})().catch(e=>{console.error(e);finish(1)});
