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
ok('Sample opens on Rotation view; first Jones rotation generated (112), all covered',n0===112&&await p.evaluate(()=>mode==='Rotation'&&period().kind==='rotation')&&await p.evaluate(()=>coverageMissing('willow').length===0&&validateAll().length===0),`count=${n0}`);
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
// Month and Week remain available
await p.click('.segmented button:has-text("Week")');ok('Week view available',await p.evaluate(()=>mode==='Week')&&await p.locator('.calendar .day').count()===7);
await p.click('.segmented button:has-text("Month")');ok('Month view available; target stays a rotation',await p.evaluate(()=>mode==='Month'&&period().kind==='rotation')&&(await p.textContent('.calhead')).includes('November 2026'));
// drag/drop: move an assignment to another day (expect either move or explained block)
const dragId=await p.evaluate(()=>state.assignments.find(a=>a.dept==='willow'&&a.date==='2026-11-05').id);
const before=await p.evaluate(id=>JSON.stringify(state.assignments.find(a=>a.id===id)),dragId);
await p.dragAndDrop(`[data-assignment="${dragId}"]`,'.org-lane[data-dept="river"][data-date="2026-11-07"]');
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
// ---------------------------------------------------------------- rotations and holidays
const rp=await (await b.newContext({viewport:{width:1366,height:900}})).newPage();const rerr=[];rp.on('pageerror',e=>rerr.push(e.message));
await rp.goto(URL);await rp.waitForSelector('.calendar');await rp.evaluate(()=>{localStorage.clear()});await rp.reload();await rp.waitForSelector('.calendar');
await rp.evaluate(()=>{state.rotations=[];state.teamHolidays=[];state.rotationDefaults={};state.assignments=state.assignments.filter(a=>a.date<'2026-12-01');rotationSel={};mode=defaultMode();persist();render()});
ok('A team without rotations is told to set them up',(await rp.textContent('#main')).includes('has no rotations yet')&&await rp.evaluate(()=>mode==='Month'));
await rp.click('#nav button:has-text("Rotations")');await rp.waitForSelector('form[onsubmit^="saveRotationDefaults"]');
await rp.fill('form[onsubmit^="saveRotationDefaults"] input[name=start]','2026-11-01');await rp.fill('form[onsubmit^="saveRotationDefaults"] input[name=length]','8');
await rp.click('form[onsubmit^="saveRotationDefaults"] button.primary');await rp.waitForTimeout(150);
ok('Rotation defaults saved (8 weeks)',await rp.evaluate(()=>state.rotationDefaults.willow.length===8&&state.rotationDefaults.willow.unit==='weeks'));
await rp.click('button:has-text("+ Add standard US holidays")');await rp.waitForTimeout(150);
ok('Standard holidays added to the Jones Team calendar',await rp.evaluate(()=>teamHolidays('willow').length===8&&teamHolidays('river').length===0));
// Christmas needs 2 day providers and no night, for Jones Team
await rp.click('.panel:has(h3:has-text("Holidays · Jones Team")) tr:has-text("Christmas Day") button:has-text("Edit")');await rp.waitForSelector('#modal[open] input[name="th-cov-day"]');
await rp.fill('#modal input[name="th-cov-day"]','2');await rp.fill('#modal input[name="th-cov-night"]','0');await rp.screenshot({path:out+'/r2-team-holiday.png'});await rp.click('#modal button.primary');await rp.waitForTimeout(150);
// a team-specific holiday with a weekday rule
await rp.click('button:has-text("+ Add holiday")');ok('Holiday dialog shows only the fields for the chosen repeat type',!(await rp.isVisible('#modal select[name="n-weekday"]'))&&await rp.isVisible('#modal input[name="f-day"]'));await rp.fill('#modal input[name=name]','Unit Founders Day');await rp.selectOption('#modal select[name=kind]','nth');
await rp.selectOption('#modal select[name="n-nth"]','2');await rp.selectOption('#modal select[name="n-weekday"]','1');await rp.selectOption('#modal select[name="n-month"]','11');await rp.click('#modal button.primary');await rp.waitForTimeout(150);
ok('Weekday-rule team holiday saved (2nd Monday of November)',(await rp.textContent('.panel:has(h3:has-text("Holidays · Jones Team"))')).includes('2nd Monday of November'));
await rp.fill('#rot-count','6');await rp.click('button:has-text("Add rotations")');await rp.waitForTimeout(200);
ok('Six consecutive 8-week rotations added',await rp.evaluate(()=>{let r=rotationsOf('willow');return r.length===6&&r[0].end==='2026-12-26'&&r[5].end==='2027-10-02'}));
ok('Team holidays appear in new rotations',await rp.evaluate(()=>{let r=rotationsOf('willow')[0];return r.holidays.some(h=>h.name==='Thanksgiving Day')&&r.holidays.some(h=>h.name==='Unit Founders Day'&&h.date==='2026-11-09')}));
await rp.selectOption('.toolbar select[aria-label="Department"]','river');await rp.waitForTimeout(150);
ok('Boehm Team keeps its own (empty) holiday calendar',(await rp.textContent('#main')).includes('No holidays for Boehm Team yet')&&await rp.evaluate(()=>rotationsOf('river').length===0));
await rp.selectOption('.toolbar select[aria-label="Department"]','willow');await rp.waitForTimeout(150);
await rp.screenshot({path:out+'/r1-rotations.png',fullPage:true});
// rotation dialog: team holidays read-only, one-off holiday editable
await rp.click('#rotation-table tbody tr:first-child button:has-text("Edit")');await rp.waitForSelector('#modal[open] form[onsubmit^="saveRotation"]');
ok('Rotation dialog lists team holidays',await rp.locator('#modal .holiday-team').count()===4,String(await rp.locator('#modal .holiday-team').count()));
await rp.click('#modal button:has-text("+ Add one-off holiday")');await rp.fill('#holiday-rows .holiday-row:last-child input[name=h-name]','Unit retreat');await rp.fill('#holiday-rows .holiday-row:last-child input[name=h-date]','2026-12-10');
await rp.fill('#holiday-rows .holiday-row:last-child input[name="h-cov-day"]','0');await rp.screenshot({path:out+'/r2b-rotation-dialog.png'});await rp.click('#modal button.primary');await rp.waitForTimeout(150);
ok('One-off rotation holiday saved alongside team holidays',await rp.evaluate(()=>{let h=rotationsOf('willow')[0].holidays;return h.some(x=>x.name==='Unit retreat'&&!x.team)&&h.filter(x=>x.team).length===4}));
ok('Holiday coverage override saved',await rp.evaluate(()=>required('willow','2026-12-25',shiftType('day'))===2&&required('willow','2026-12-25',shiftType('night'))===0));
// invalid: overlapping dates refused in the dialog
await rp.click('#rotation-table tbody tr:nth-child(2) button:has-text("Edit")');await rp.waitForSelector('#modal[open]');await rp.fill('#modal input[name=start]','2026-12-20');await rp.click('#modal button.primary');await rp.waitForTimeout(150);
ok('Overlapping rotation dates are refused with a reason',/overlap/.test(await rp.textContent('#formerror')),await rp.textContent('#formerror'));
await rp.click('#modal button:has-text("Cancel")');
// open in schedule: Rotation view, 8 weeks, holiday tags, open slots incl. override
await rp.click('#rotation-table tbody tr:first-child button:has-text("Open")');await rp.waitForSelector('.calendar');
ok('Schedule opens in Rotation view for that rotation',await rp.evaluate(()=>mode==='Rotation'&&period().rotation.name==='2026 Rotation 1'));
ok('Rotation view shows 8 weeks of days',await rp.locator('.calendar .day:not(.out)').count()===56,String(await rp.locator('.calendar .day:not(.out)').count()));
ok('Holiday tags shown on the calendar',await rp.locator('.org-lane[data-dept="willow"][data-date="2026-11-26"] .holiday-tag').count()===1);
ok('Team holiday staffing shapes open slots (2 Day, 0 Night on Christmas)',await rp.locator('.org-lane[data-dept="willow"][data-date="2026-12-25"] .assignment.open').count()===2);
ok('Coverage stat covers the rotation (111 required: Christmas 2+0, retreat 0 Day)',(await rp.textContent('.stats')).includes('of 111 covered'),await rp.textContent('.stats .stat small'));
await rp.click('button:has-text("Generate")');await rp.click('#modal button.primary:has-text("Generate draft")');await rp.waitForTimeout(300);
ok('Generate fills the rotation without conflicts',await rp.evaluate(()=>coverageMissing().length===0&&validateAll().length===0&&state.assignments.every(a=>a.date<='2026-12-26')));
await rp.screenshot({path:out+'/r3-rotation-schedule.png'});
await rp.click('button.primary:has-text("Publish")');await rp.click('#modal button.primary:has-text("Publish schedule")');await rp.waitForTimeout(200);
ok('Publishing locks the rotation',await rp.evaluate(()=>locked()&&rotationsOf('willow')[0].status==='Published'&&isPublished('willow','2026-12-26')&&!isPublished('willow','2026-12-27')));
await rp.click('button[aria-label="Next period"]');await rp.waitForTimeout(100);
ok('Next moves to the following rotation (draft)',await rp.evaluate(()=>period().rotation.name==='2026 Rotation 2'&&!locked()));
// published version: matches, then shows a change after reopen + edit
await rp.evaluate(()=>navigate('Rotations'));await rp.click('#rotation-table tbody tr:first-child button:has-text("Published version")');await rp.waitForSelector('#modal[open]');
ok('Published version matches the current schedule',(await rp.textContent('#modal')).includes('matches the published version'));await rp.click('#modal button:has-text("Close")');
await rp.evaluate(()=>{rotationSel.willow=rotationsOf('willow')[0].id;reopenNow();let a=state.assignments.find(a=>a.dept==='willow'&&a.date==='2026-11-03');state.assignments=state.assignments.filter(x=>x!==a);persist();navigate('Rotations')});
await rp.click('#rotation-table tbody tr:first-child button:has-text("Published version")');await rp.waitForSelector('#modal[open]');
ok('Published version lists changes since publishing',(await rp.textContent('#modal')).includes('Removed since publishing · 1')&&(await rp.textContent('#modal')).includes('reopened'));
await rp.screenshot({path:out+'/r5-published-version.png'});await rp.click('#modal button:has-text("Close")');
// reports: scope follows Rotation / Month / Week
await rp.evaluate(()=>{mode='Rotation';navigate('Reports')});ok('Reports default to the rotation with rotation-by-rotation history',(await rp.textContent('#main')).includes('Rotation by rotation'));
await rp.screenshot({path:out+'/r6-reports.png',fullPage:true});
await rp.click('#main .segmented button:has-text("Month")');ok('Reports by month still available',(await rp.textContent('#main')).includes('Monthly workload'));
await rp.click('#main .segmented button:has-text("Week")');ok('Reports by week still available',(await rp.textContent('#main')).includes('Weekly workload'));
await rp.click('#main .segmented button:has-text("Rotation")');
// reports: holiday fairness
await rp.evaluate(()=>{rotationSel.willow=rotationsOf('willow')[0].id;navigate('Reports')});
ok('Reports show holiday coverage and fairness',(await rp.textContent('#main')).includes('Holiday fairness over the years')&&(await rp.textContent('#main')).includes('Christmas Day'));
// providers show rotation limits
await rp.evaluate(()=>navigate('Providers'));ok('Providers show rotation target/max',(await rp.textContent('table')).includes('20 / 28'));
// weekly shift pattern + date-specific shift on rotation 2
await rp.evaluate(()=>navigate('Rotations'));await rp.click('#rotation-table tbody tr:nth-child(2) button:has-text("Edit")');await rp.waitForSelector('#modal[open] .pattern-grid');
await rp.click('#modal .pattern-grid tr[data-type="clinic-am"] button[title="Mon–Fri"]');
await rp.click('#modal button:has-text("+ Add date-specific shift")');await rp.fill('#ds-rows .ds-row:last-child input[name=ds-date]','2027-01-15');await rp.selectOption('#ds-rows .ds-row:last-child select[name=ds-type]','triage');await rp.fill('#ds-rows .ds-row:last-child input[name=ds-count]','2');
await rp.screenshot({path:out+'/r7-weekly-shifts.png'});await rp.click('#modal button.primary');await rp.waitForTimeout(150);
ok('Weekly pattern and date-specific shift saved',await rp.evaluate(()=>{let r=rotationsOf('willow')[1];return r.pattern['clinic-am'].days.join()==='1,2,3,4,5'&&r.pattern.day.days.length===7&&r.dateShifts['2027-01-15'].triage===2}));
ok('Rotations table summarises weekly shifts',(await rp.textContent('#rotation-table')).includes('Mon–Fri'));
await rp.click('#rotation-table tbody tr:nth-child(2) button:has-text("Open")');await rp.waitForSelector('.calendar');
ok('Clinic AM open on Monday, not on Saturday',await rp.locator('.org-lane[data-dept="willow"][data-date="2027-01-04"] .assignment.open:has-text("Clinic AM")').count()===1&&await rp.locator('.org-lane[data-dept="willow"][data-date="2027-01-09"] .assignment.open:has-text("Clinic AM")').count()===0);
ok('Date-specific shift adds 2 Triage on Jan 15',await rp.locator('.org-lane[data-dept="willow"][data-date="2027-01-15"] .assignment.open:has-text("Triage")').count()===2);
// team default pattern is used by the next rotation
await rp.evaluate(()=>navigate('Rotations'));await rp.click('form[onsubmit^="saveRotationDefaults"] .pattern-grid tr[data-type="clinic-pm"] button[title="Mon–Fri"]');await rp.click('form[onsubmit^="saveRotationDefaults"] button.primary');await rp.waitForTimeout(150);
await rp.click('button:has-text("+ Add next rotation")');await rp.waitForTimeout(150);
ok('New rotation starts from the team default weekly pattern',await rp.evaluate(()=>{let l=rotationsOf('willow'),r=l[l.length-1];return r.pattern&&r.pattern['clinic-pm']?.days.join()==='1,2,3,4,5'}));
// weeks follow the rotation start weekday: a Monday rotation for Boehm Team
await rp.evaluate(()=>{dept='river';navigate('Rotations')});await rp.fill('form[onsubmit^="saveRotationDefaults"] input[name=start]','2026-11-02');await rp.click('form[onsubmit^="saveRotationDefaults"] button.primary');await rp.waitForTimeout(150);
await rp.click('button:has-text("+ Add next rotation")');await rp.waitForTimeout(150);
await rp.click('#rotation-table tbody tr:first-child button:has-text("Edit")');await rp.waitForSelector('#modal[open] .pattern-grid');
ok('Weekly shifts grid starts on Monday for a Monday rotation',(await rp.locator('#modal .pattern-grid thead th').nth(1).textContent())==='Mon');
await rp.click('#modal .pattern-grid tr[data-type="clinic-am"] button[title="Mon–Fri"]');await rp.click('#modal button.primary');await rp.waitForTimeout(150);
ok('M–F still selects Monday–Friday in the reordered grid',await rp.evaluate(()=>rotationsOf('river')[0].pattern['clinic-am'].days.join()==='1,2,3,4,5'));
await rp.click('#rotation-table tbody tr:first-child button:has-text("Open")');await rp.waitForSelector('.calendar');
ok('Rotation view runs Mon–Sun from the start date',(await rp.locator('.calendar .dow').first().textContent())==='Mon'&&(await rp.locator('.calendar .day').first().getAttribute('data-date'))==='2026-11-02'&&(await rp.textContent('.calhead')).includes('weeks start Mon'));
await rp.click('.segmented button:has-text("Week")');ok('Week view inside it also starts Monday',(await rp.locator('.calendar .dow').first().textContent())==='Mon'&&await rp.evaluate(()=>date(visibleRange().start).getDay()===1));
await rp.click('.segmented button:has-text("Rotation")');await rp.evaluate(()=>{dept='willow'});
// mobile: rotations page fits
const rm=await (await b.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true})).newPage();await rm.goto(URL);await rm.waitForSelector('.calendar');
await rm.evaluate(()=>{state.rotationDefaults={willow:{start:'2026-11-01',length:8,unit:'weeks'}};addStandardTeamHolidays();addRotations(2);navigate('Rotations')});await rm.waitForTimeout(200);
ok('Rotations page has no horizontal page overflow on a phone',await rm.evaluate(()=>document.documentElement.scrollWidth<=390),String(await rm.evaluate(()=>document.documentElement.scrollWidth)));
await rm.screenshot({path:out+'/r4-rotations-mobile.png',fullPage:true});
ok('No JS errors (rotations)',rerr.length===0,rerr.join(' | '));
await b.close();
finish(0);
})().catch(e=>{console.error(e);results.push(['FAIL','Test run aborted',e.message.split('\n')[0]]);finish(1)});
