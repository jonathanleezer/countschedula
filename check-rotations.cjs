// Rotations, holidays and per-rotation workload (domain logic, no browser).
const vm=require('node:vm'),fs=require('node:fs');let code=fs.readFileSync('dist/app.js','utf8');code=code.slice(0,code.lastIndexOf('/*@boot*/'));
const ctx=vm.createContext({console,crypto:require('node:crypto').webcrypto,localStorage:{getItem:()=>null,setItem:()=>{}},document:{addEventListener:()=>{},querySelector:()=>({open:false}),querySelectorAll:()=>[]}});
vm.runInContext(code,ctx);vm.runInContext(`render=()=>{};modal=()=>{};closeModal=()=>{};toast=m=>{lastToast=m};var lastToast='';
const must=(c,m)=>{if(!c)throw Error(m)};
// migration: per-rotation limits from monthly (×2), empty rotation data
must(state.providers[0].rotationTarget===20&&state.providers[0].rotationMax===28,'Monthly limits not converted to rotation limits');
must(Array.isArray(state.rotations)&&state.rotations.length===0&&Array.isArray(state.holidayHistory),'Rotation data not initialised');
let legacy=migrate({providers:[{id:'x',name:'X',role:'CNM',target:5,max:7,affiliations:['willow']}],rules:{rest:12,consecutive:3}});must(legacy.providers[0].rotationMax===14&&legacy.rotations.length===0,'Legacy backup migration');
must(migrate(JSON.parse(JSON.stringify(state))).providers[0].rotationMax===28,'Migration must be idempotent');
// durations
must(addDuration('2026-11-01',8,'weeks')==='2026-12-26','8 weeks');
must(addDuration('2026-11-01',10,'days')==='2026-11-10','10 days');
must(addDuration('2026-11-01',2,'months')==='2026-12-31','2 months');
// defaults + adding rotations with standard holidays
must(period().kind==='month','No rotations should mean month periods');
state.rotationDefaults={willow:{start:'2026-11-01',length:8,unit:'weeks'}};
addRotations(3,true);
let rs=rotationsOf('willow');
must(rs.length===3&&rs[0].start==='2026-11-01'&&rs[0].end==='2026-12-26'&&rs[1].start==='2026-12-27'&&rs[2].start==='2027-02-21','Consecutive rotations from defaults');
must(rs[0].holidays.map(h=>h.name).join()==='Thanksgiving Day,Christmas Eve,Christmas Day','Standard holidays in first rotation: '+rs[0].holidays.map(h=>h.name));
must(rs[0].holidays.find(h=>h.name==='Thanksgiving Day').date==='2026-11-26','Thanksgiving date');
must(rotationsOf('river').length===0&&period('river').kind==='month','Rotations are per team');
// validation
const bad=(list,msg)=>{try{validateRotations(list);throw Error('accepted: '+msg)}catch(e){if(e.message.startsWith('accepted'))throw e}};
bad([...state.rotations,{...rs[0],id:'dup-overlap',start:'2026-12-01',end:'2026-12-31'}],'overlap');
bad([{...rs[0],holidays:[{id:'h1',name:'Out',date:'2027-03-01',coverage:{}}]}],'holiday outside rotation');
bad([{...rs[0],id:'x"><b'}],'unsafe id');
bad([{...rs[0],end:'2026-10-01'}],'end before start');
bad([{...rs[0],holidays:[{id:'h1',name:'X',date:'2026-11-26',coverage:{day:11}}]}],'coverage out of range');
validateRotations([...state.rotations,{...rs[0],id:'boehm-1',dept:'river'}]);
// period, coverage, holiday overrides
rotationSel.willow=rs[0].id;
must(period().kind==='rotation'&&period().start==='2026-11-01'&&period().end==='2026-12-26','Selected rotation is the period');
must(totalSlots()===112&&coverageMissing().length===112,'56 days × Day+Night = 112');
rs[0].holidays.find(h=>h.name==='Christmas Day').coverage={day:2,night:0};
must(totalSlots()===112+1-1&&required('willow','2026-12-25',shiftType('day'))===2&&required('willow','2026-12-25',shiftType('night'))===0,'Holiday coverage override');
must(required('river','2026-12-25',shiftType('day'))===1,'Holiday override must not leak to the other team');
// year-over-year holiday rotation: everyone but Rachel Morgan (p3) covered Christmas Day last year
state.holidayHistory=state.providers.filter(p=>p.id!=='p3').map(p=>({id:'hh-'+p.id,provider:p.id,holiday:'Christmas Day',year:2025}));
generate(true);
must(coverageMissing().length===0&&validateAll().length===0,'Rotation generation should fill all slots without conflicts: '+coverageMissing().length+' open, '+validateAll().length+' conflicts');
let xmas=state.assignments.filter(a=>a.dept==='willow'&&a.date==='2026-12-25');
must(xmas.length===2&&xmas.every(a=>a.shift==='day'),'Holiday override generated 2 day shifts, no night');
must(xmas.some(a=>a.provider==='p3'),'Provider without last year’s Christmas should get Christmas');
must(holidayHistory('p3','christmas day').includes(2026),'Holiday history counts CountSchedula assignments');
must(state.assignments.every(a=>a.date<'2026-12-27'),'Generation stays inside the rotation');
// per-rotation maximum
let pr=state.providers[0],n=state.assignments.filter(a=>a.provider===pr.id&&a.date>='2026-11-01'&&a.date<='2026-12-26').length;
must(n>0&&n<=pr.rotationMax,'Generated load within rotation max');
pr.rotationMax=n;must(violations({id:'new',provider:pr.id,dept:'willow',date:'2026-12-20',shift:'clinic-am'}).some(e=>e.startsWith('Rotation maximum of '+n)),'Rotation maximum enforced');
must(!violations({id:'new',provider:pr.id,dept:'willow',date:'2027-06-20',shift:'clinic-am'}).some(e=>e.includes('maximum')),'Outside any rotation monthly limits apply');
pr.rotationMax=28;
// publish locks only this team’s rotation
publish();
must(rs[0].status==='Published'&&rs[0].snapshot.length===state.assignments.length&&locked(),'Rotation published with snapshot');
must(isPublished('willow','2026-12-26')&&!isPublished('willow','2026-12-27')&&!isPublished('river','2026-11-10'),'Lock is per team and per rotation');
must(!canEdit('2026-11-10','willow')&&canEdit('2026-11-10','river'),'canEdit respects rotation locks');
reopenNow();must(rs[0].status==='Draft'&&!locked(),'Reopen');
// navigation between rotations
mode='Rotation';changePeriod(1);must(period().rotation.id===rs[1].id,'Next rotation');changePeriod(-1);must(period().rotation.id===rs[0].id,'Previous rotation');
// rendering and export
let html=calendarCells()+schedule()+rotationsPage()+reportsPage();
must(!html.includes('undefined')&&!html.includes('NaN'),'Rendering invalid values');
must(html.includes('✦ Christmas Day')&&html.includes('2026 Rotation 1'),'Holiday and rotation labels rendered');
let out;download=t=>out=t;view='Schedule';selectedOrgs=['willow'];exportCSV();must(out.split('\\n')[0].includes('Holiday')&&out.includes('Christmas Day'),'CSV holiday column');
console.log('PASS: per-rotation limits migration, durations, per-team rotations from defaults, standard holidays, validation, holiday coverage overrides, year-over-year holiday rotation, rotation generation/max/publish/locks, rendering, CSV');`,ctx);
