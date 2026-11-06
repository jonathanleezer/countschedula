// Viewer and scheduler experience in shared-workspace mode, using a stand-in for dist/cloud.js.
const vm=require('node:vm'),fs=require('node:fs');let code=fs.readFileSync('dist/app.js','utf8');code=code.slice(0,code.lastIndexOf('/*@boot*/'));
const cloud={r:'viewer',m:'p3',v:['willow'],role(){return this.r},me(){return this.m},visible(){return this.v},save(){},note(){},roleLabel(){return this.r},settingsPanels(){return '<div id="cs-account"></div>'},calls:[],
 submitRequest(...a){this.calls.push(['submit',...a]);return Promise.resolve(null)},updateRequest(...a){this.calls.push(['update',...a]);return Promise.resolve(null)},withdrawRequest(...a){this.calls.push(['withdraw',...a]);return Promise.resolve(null)},markSynergy(...a){this.calls.push(['mark',...a])}};
const ctx=vm.createContext({console,crypto:require('node:crypto').webcrypto,localStorage:(()=>{let m={};return {getItem:k=>k in m?m[k]:null,setItem:(k,v)=>{m[k]=String(v)},removeItem:k=>{delete m[k]}}})(),document:{addEventListener:()=>{},querySelector:()=>({open:false}),querySelectorAll:()=>[]},window:{COUNTSCHEDULA_CONFIG:{supabaseUrl:'x'},CountSchedulaCloud:cloud}});
vm.runInContext(code,ctx);ctx.CLOUDSTUB=cloud;
vm.runInContext(`render=()=>{};modal=()=>{};closeModal=()=>{};toast=()=>{};
const must=(c,m)=>{if(!c)throw Error(m)};
// a viewer's state as the server sends it: published rotation, assignments, own + others' approved PTO
state=migrate(seed());seedRotations();rotationSel={};mode='Rotation';dept='willow';cursor=new Date(2026,10,1);
CLOUDSTUB.r='admin';generate(true);publish();
state.rotations=state.rotations.filter(r=>r.status==='Published');
state.requests=[{id:'mine1',provider:'p3',start:'2026-12-01',end:'2026-12-02',status:'Pending',reason:'Dentist',mine:true},{id:'mine2',provider:'p3',start:'2026-12-10',end:'2026-12-12',status:'Approved',mine:true},{id:'r2',provider:'p4',start:'2026-11-23',end:'2026-11-25',status:'Approved'}];
CLOUDSTUB.r='viewer';
must(isViewer()&&!isScheduler()&&myProvider()==='p3','viewer role from the cloud client');
must(JSON.stringify(navPages().map(p=>p[1]))==='["My schedule","Schedule","Time off","Settings"]','viewer navigation');
let my=mySchedulePage();must(my.includes('Rachel Morgan')&&my.includes('Synergy is the official record')&&my.includes('Next shift')&&!my.includes('undefined')&&!my.includes('NaN'),'My schedule renders with the Synergy notice');
must(my.split('<tr class=').length-1===state.assignments.filter(a=>a.provider==='p3'&&a.date>=myRange().start&&a.date<=myRange().end).length,'My schedule lists the viewer’s shifts in the selected rotation');
// list / calendar, remembered per person on this device
must(uiGet().view===undefined&&my.includes('Your shifts ·')&&!my.includes('my-calendar'),'list view by default');
uiSet({view:'calendar'});my=mySchedulePage();
must(my.includes('my-calendar')&&my.includes('mychip mine')&&!my.includes('Your shifts ·'),'calendar view');
must(my.split('mychip mine').length-1===state.assignments.filter(a=>a.provider==='p3'&&a.date>=myRange().start&&a.date<=myRange().end).length,'calendar shows each of my shifts once');
must(JSON.parse(localStorage.getItem(uiKey())).view==='calendar','last view is remembered');
// colleagues
must(colleaguePicker().includes('Everyone on Jones Team')&&!colleaguePicker().includes('value="p3"'),'colleague picker lists teammates, not me');
setColleague('p4',true);my=mySchedulePage();
must(my.includes('<b>Mia Patel</b>')&&colleagues().join()==='p4','a colleague’s shifts appear with their name');
setTeamColleagues('willow',true);must(colleagues().length===state.providers.filter(p=>p.id!=='p3'&&p.affiliations.includes('willow')).length,'everyone on a team');
uiSet({colleagues:[]});uiSet({view:'list'});setColleague('p4',true);my=mySchedulePage();
must(my.includes('Colleagues ·')&&my.includes('Mia Patel'),'colleagues table in list view');uiSet({colleagues:[]});
// rotation navigation
let r0=myRotation();myStep(1);must(myRotation()!==r0||rotationsOf(myTeam()).length===1,'next rotation');myStep(-1);must(myRotation()===r0,'previous rotation');
// trade finder against a hand-checked case: p3 works Mon 2026-12-07 Day; p4 is free that day and the days around it
state.assignments=state.assignments.filter(a=>a.date<'2026-12-04'||a.date>'2026-12-10');
state.assignments.push({id:'t-mine',provider:'p3',dept:'willow',date:'2026-12-07',shift:'day'},{id:'t-p0',provider:'p0',dept:'willow',date:'2026-12-07',shift:'night'},{id:'t-p4',provider:'p4',dept:'willow',date:'2026-12-09',shift:'day'});
let o=tradeOptions('t-mine'),can=o.cover.filter(c=>!c.errors.length).map(c=>c.p.id);
must(can.includes('p4')&&!can.includes('p0'),'cover: free colleague can take it; one working that night cannot (rest/overlap)');
must(o.cover.find(c=>c.p.id==='p0').errors.length>0,'reason shown for the unavailable colleague');
must(o.swaps.some(s=>s.p.id==='p4'&&s.b.id==='t-p4'),'swap with p4’s Dec 9 day works both ways');
must(o.swaps.some(s=>s.b.id==='t-p0'),'same-day Day↔Night exchange is a valid swap');
state.assignments.push({id:'t-p0b',provider:'p0',dept:'willow',date:'2026-12-06',shift:'night'});
must(!tradeOptions('t-mine').swaps.some(s=>s.b.id==='t-p0b'),'a swap that would break the 12h rest for me is not offered');
must(tradeOptions('t-p4')===null,'cannot trade someone else’s shift');
let cal=calendarCells();
must(!cal.includes('class="add"')&&!cal.includes('assignment open')&&!cal.includes('onclick="assignmentDialog'),'viewer calendar is read-only (no add buttons, open slots or editors)');
must(cal.includes('assignment mine')&&cal.includes('Off · Mia Patel'),'own shifts highlighted; others’ approved time off shown as Off');
must(!/draggable="true"/.test(cal),'nothing is draggable for viewers');
must(!cal.includes('>Locked<')&&!schedule().includes('Reopen draft'),'viewers see no scheduler lock wording');
let sch=schedule();must(!sch.includes('generateDialog()')&&!sch.includes('Your team, ready to go')&&sch.includes('Synergy is the official record')&&sch.includes('>Team'),'viewer schedule hides scheduler tools');
let to=myTimeOffPage();must(to.includes('Dentist')&&to.includes('myRequestDialog(\\'mine1\\')')&&to.includes('Shorten')&&!to.includes('Mia Patel'),'Time off lists only the viewer’s requests with edit, shorten and withdraw');
must(requestsPage()===myTimeOffPage(),'Requests routes viewers to their Time off page');
must(settingsPage().includes('cs-account')&&!settingsPage().includes('Restore backup'),'viewer settings show the account only');
CLOUDSTUB.v=[];must(schedule().includes('isn’t linked')&&organizationPicker()==='','unlinked viewer sees an explanation, no team picker');CLOUDSTUB.v=['willow'];
CLOUDSTUB.m=null;must(mySchedulePage().includes('isn’t linked')&&myTimeOffPage().includes('isn’t linked'),'unlinked viewer is told to ask an admin');CLOUDSTUB.m='p3';
// scheduler view of the same data with Synergy status
CLOUDSTUB.r='scheduler';
state.requests=[{id:'r9',provider:'p3',start:'2026-12-10',end:'2026-12-12',status:'Approved',via:'app',synergy:{status:'not-entered'}},{id:'r8',provider:'p4',start:'2026-11-23',end:'2026-11-25',status:'Withdrawn',synergy:{status:'changed',at:'2026-11-05T10:00:00Z',by:'claire@example.test'}}];
state.rotations[0].synergy={status:'ok',at:'2026-11-05T10:00:00Z'};
must(navPages()[0][1]==='My schedule'&&navPages().some(p=>p[1]==='Rotations'),'scheduler with a linked provider also gets My schedule');
let rq=requestsPage();must(rq.includes('<th>Synergy</th>')&&rq.includes('via app')&&rq.includes('Not in Synergy')&&rq.includes('Changed · update Synergy')&&rq.includes("markSynergy('request','r9')"),'scheduler sees Synergy status and Mark entered');
must(synergyTodo().length===2&&schedule().includes('2 items need entering or updating in Synergy'),'Schedule shows what still needs Synergy');
must(rotationsPage().includes('✓ In Synergy'),'rotation Synergy status on the Rotations page');
must(calendarCells().includes('class="add"')&&calendarCells().includes('onclick="assignmentDialog'),'scheduler calendar stays editable');
// status follows edits immediately: an entered approval that is then declined shows Changed
state.requests.push({id:'r7',provider:'p3',start:'2027-01-05',end:'2027-01-06',status:'Approved',synergy:{status:'ok',at:'2026-11-05T10:00:00Z',entered:{start:'2027-01-05',end:'2027-01-06',status:'Approved'}}});
must(requestSynergy(state.requests.at(-1)).status==='ok','entered and unchanged → ok');state.requests.at(-1).status='Declined';
must(requestSynergy(state.requests.at(-1)).status==='changed'&&requestsPage().includes("markSynergy('request','r7')"),'declining after Synergy entry → changed, without reload');
state.requests.pop();state.requests[0].synergy={status:'none'};must(requestSynergy(state.requests[0]).status==='not-entered','newly approved → not entered, without reload');
markSynergy('request','r9');must(CLOUDSTUB.calls.some(c=>c[0]==='mark'&&c[2]==='r9'),'Mark entered calls the server');
console.log('PASS: viewer navigation, My schedule, read-only team calendar, off markers, own time off, unlinked accounts; scheduler Synergy status, notices and marks');`,ctx);
