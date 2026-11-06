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
must(holidayDate(STANDARD_HOLIDAYS.find(d=>d.name==='Thanksgiving Day'),2026)==='2026-11-26'&&holidayDate(STANDARD_HOLIDAYS.find(d=>d.name==='Memorial Day'),2027)==='2027-05-31'&&holidayDate(STANDARD_HOLIDAYS.find(d=>d.name==='Labor Day'),2027)==='2027-09-06','Holiday rules (nth / last weekday)');
must(holidayDate({kind:'fixed',month:2,day:29},2027)===null&&holidayDate({kind:'fixed',month:2,day:29},2028)==='2028-02-29','Feb 29 only in leap years');
addStandardTeamHolidays();
must(teamHolidays('willow').length===8&&teamHolidays('river').length===0,'Standard holidays added to Jones Team only');
addRotations(3);
let rs=rotationsOf('willow');
must(rs.length===3&&rs[0].start==='2026-11-01'&&rs[0].end==='2026-12-26'&&rs[1].start==='2026-12-27'&&rs[2].start==='2027-02-21','Consecutive rotations from defaults');
must(rs[0].holidays.map(h=>h.name).join()==='Thanksgiving Day,Christmas Eve,Christmas Day','Standard holidays in first rotation: '+rs[0].holidays.map(h=>h.name));
must(rs[0].holidays.find(h=>h.name==='Thanksgiving Day').date==='2026-11-26','Thanksgiving date');
must(rotationsOf('river').length===0&&period('river').kind==='month','Rotations are per team');
must(rs[0].holidays.every(h=>h.team),'Team holidays are linked to their definitions');
// team-specific calendars: Boehm gets its own rotation and only its own holidays
state.rotationDefaults.river={start:'2026-11-01',length:8,unit:'weeks'};dept='river';
let own={id:'th-river-1',dept:'river',name:'Founders Day',kind:'nth',month:11,weekday:1,nth:2,coverage:{day:2}};
must(applyTeamHolidays([...state.teamHolidays,own],'test')===null,'Add Boehm holiday');addRotations(1);
let br=rotationsOf('river')[0];
must(br.holidays.length===1&&br.holidays[0].name==='Founders Day'&&br.holidays[0].date==='2026-11-09','Boehm rotation has only Boehm holidays: '+JSON.stringify(br.holidays));
must(!holidayOn('willow','2026-11-09')&&holidayOn('river','2026-11-26')===undefined,'Holidays do not cross teams');
must(required('river','2026-11-09',shiftType('day'))===2&&required('willow','2026-11-09',shiftType('day'))===1,'Team holiday staffing applies to that team only');
copyTeamHolidays('willow');must(teamHolidays('river').length===9,'Copy holidays from Jones Team');
must(rotationsOf('river')[0].holidays.some(h=>h.name==='Thanksgiving Day'),'Copied holidays reach Boehm draft rotations');
state.rotations=state.rotations.filter(r=>r.dept!=='river');state.teamHolidays=state.teamHolidays.filter(h=>h.dept!=='river');dept='willow';
// editing a team holiday updates draft rotations; one-off rotation holidays stay
rs=rotationsOf('willow');rs[1].holidays.push({id:'one-off',name:'Unit retreat',date:'2027-01-15',coverage:{day:0}});
let xdef=teamHolidays().find(h=>h.name==='Christmas Day');
must(applyTeamHolidays(state.teamHolidays.map(h=>h.id===xdef.id?{...h,coverage:{day:2,night:0}}:h),'test')===null,'Edit team holiday');
rs=rotationsOf('willow');
must(rs[0].holidays.find(h=>h.name==='Christmas Day').coverage.day===2&&rs[1].holidays.some(h=>h.id==='one-off'),'Team edit synced; one-off kept');
let bad2=applyTeamHolidays([...state.teamHolidays,{id:'dup',dept:'willow',name:'christmas day',kind:'fixed',month:12,day:25,coverage:{}}],'x');
must(bad2&&bad2.includes('already'),'Duplicate team holiday names refused');
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
must(totalSlots()===112&&required('willow','2026-12-25',shiftType('day'))===2&&required('willow','2026-12-25',shiftType('night'))===0,'Holiday coverage override');
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
// published rotations keep their holidays when the team calendar changes
let before=JSON.stringify(rs[0].holidays);applyTeamHolidays(state.teamHolidays.filter(h=>h.name!=='Thanksgiving Day'),'test');
must(JSON.stringify(rotationsOf('willow')[0].holidays)===before&&!rotationsOf('willow')[1].holidays.some(h=>h.name==='Thanksgiving Day'),'Published rotation frozen; drafts follow the team calendar');
rs=rotationsOf('willow');reopenNow();must(rs[0].status==='Draft'&&!locked(),'Reopen');
// navigation between rotations
mode='Rotation';changePeriod(1);must(period().rotation.id===rs[1].id,'Next rotation');changePeriod(-1);must(period().rotation.id===rs[0].id,'Previous rotation');
// rendering and export
let html=calendarCells()+schedule()+rotationsPage()+reportsPage();
must(!html.includes('undefined')&&!html.includes('NaN'),'Rendering invalid values');
must(html.includes('✦ Christmas Day')&&html.includes('2026 Rotation 1'),'Holiday and rotation labels rendered');
let out;download=t=>out=t;view='Schedule';selectedOrgs=['willow'];exportCSV();must(out.split('\\n')[0].includes('Holiday')&&out.includes('Christmas Day'),'CSV holiday column');
// rotation-first behavior
mode='Month';cursor=new Date(2026,11,1);delete rotationSel.willow;
must(period().rotation.id===rs[0].id,'Month view targets the rotation covering the viewed dates (mid-December → rotation 1)');
changePeriod(1);must(period().rotation.id===rs[1].id&&period().kind==='rotation','Moving months moves the target rotation');
must(!rotationSelect().includes('Calendar month'),'Teams with rotations have no month fallback option');
must(required('willow','2027-12-01',shiftType('day'))===0&&required('willow','2026-11-10',shiftType('day'))===1,'No required coverage outside rotations for a team that uses rotations');
must(required('river','2027-12-01',shiftType('day'))===1,'Teams without rotations keep daily coverage');
setMode('Rotation');must(mode==='Rotation'&&period().rotation.id===rs[1].id&&iso(cursor)===rs[1].start,'Switching to Rotation keeps the target rotation');
view='Reports';let rep=reportsPage();must(rep.includes('Rotation by rotation')&&rep.includes(rs[1].name)&&!rep.includes('undefined')&&!rep.includes('NaN'),'Rotation reports with rotation history');
setMode('Month');rep=reportsPage();must(rep.includes('Monthly workload')&&!rep.includes('Rotation by rotation'),'Monthly report scope still available');
setMode('Week');rep=reportsPage();must(rep.includes('Weekly workload'),'Weekly report scope still available');
setMode('Rotation');view='Schedule';
state.requests.push({id:'rq',provider:'p0',start:'2026-12-20',end:'2026-12-30',status:'Pending'});must(requestRotations(state.requests.at(-1)).includes(rs[0].name)&&requestRotations(state.requests.at(-1)).includes(rs[1].name),'Requests show the rotations they touch');state.requests.pop();
rotationSel.willow=rs[0].id;download=t=>out=t;exportCSV();must(out.split('\\r\\n')[0].includes('Rotation')&&out.includes(rs[0].name),'CSV includes the rotation');
// local sample starts rotation-first
state=migrate(seed());rotationSel={};mode='Rotation';cursor=new Date(2026,10,1);seedRotations();
must(rotationsOf('willow').length===6&&rotationsOf('river').length===6&&teamHolidays('river').length===8&&rotationsOf('river')[0].holidays.some(h=>h.name==='Thanksgiving Day'),'Sample has rotations and holidays for both teams');
generate(true);must(relevant().length===112-1+1&&coverageMissing().length===0&&validateAll().length===0,'Sample generation fills the first Jones rotation: '+relevant().length+' / '+coverageMissing().length+' open');
// weekly shift patterns and date-specific shifts
must(JSON.stringify(defaultPattern())===JSON.stringify({day:{days:[0,1,2,3,4,5,6],count:1},night:{days:[0,1,2,3,4,5,6],count:1}}),'Default pattern mirrors daily defaults');
state.rotationDefaults.willow.pattern={day:{days:[0,1,2,3,4,5,6],count:1},night:{days:[0,1,2,3,4,5,6],count:1},'clinic-am':{days:[1,2,3,4,5],count:1}};
let pr2=nextRotation('willow');must(pr2.pattern['clinic-am'].days.join()==='1,2,3,4,5'&&pr2.pattern!==state.rotationDefaults.willow.pattern,'New rotations copy the team default pattern');
let R2=rotationsOf('willow')[1];R2.pattern=JSON.parse(JSON.stringify(state.rotationDefaults.willow.pattern));
must(required('willow','2027-01-04',shiftType('clinic-am'))===1&&required('willow','2027-01-09',shiftType('clinic-am'))===0,'Clinic AM on Monday only, not Saturday');
must(required('willow','2027-01-09',shiftType('triage'))===0&&required('willow','2027-01-09',shiftType('day'))===1,'Types outside the pattern are not scheduled');
must(required('willow','2026-12-02',shiftType('clinic-am'))===0&&required('willow','2026-12-02',shiftType('day'))===1,'Rotation without a pattern keeps daily defaults');
R2.dateShifts={'2027-01-15':{triage:2,day:0},'2027-01-01':{day:3}};
let nyd=R2.holidays.find(h=>h.date==='2027-01-01');nyd.coverage={day:2};
must(required('willow','2027-01-15',shiftType('triage'))===2&&required('willow','2027-01-15',shiftType('day'))===0,'Date-specific shifts add and remove');
must(required('willow','2027-01-01',shiftType('day'))===3,'Date-specific shift beats holiday staffing');
delete R2.dateShifts['2027-01-01'];must(required('willow','2027-01-01',shiftType('day'))===2,'Holiday staffing beats the weekly pattern');
const badR=(r,msg)=>{try{validateRotations(state.rotations.map(x=>x.id===R2.id?r:x));throw Error('accepted: '+msg)}catch(e){if(e.message.startsWith('accepted'))throw e}};
badR({...R2,pattern:{day:{days:[0,7],count:1}}},'weekday 7');badR({...R2,pattern:{day:{days:[1],count:0}}},'count 0');
badR({...R2,dateShifts:{'2027-06-01':{day:1}}},'date outside rotation');badR({...R2,dateShifts:{'2027-01-15':{day:11}}},'count 11');
validateRotations(state.rotations);
rotationSel.willow=R2.id;mode='Rotation';generate(true);
must(coverageMissing().length===0&&validateAll().length===0,'Pattern rotation generated without gaps or conflicts: '+coverageMissing().length);
let r2a=relevant();must(r2a.filter(a=>a.shift==='clinic-am').every(a=>[1,2,3,4,5].includes(date(a.date).getDay()))&&r2a.some(a=>a.shift==='clinic-am'),'Clinic AM generated on weekdays only');
must(r2a.filter(a=>a.date==='2027-01-15'&&a.shift==='day').length===0&&r2a.filter(a=>a.date==='2027-01-15'&&a.shift==='triage').length===2,'Date-specific shifts generated');
let html2=rotationsPage()+calendarCells();must(html2.includes('Mon–Fri')&&!html2.includes('undefined')&&!html2.includes('NaN'),'Pattern summary rendered');
// weeks start on the rotation's start weekday
state.rotations=state.rotations.filter(r=>r.dept!=='river');state.rotationDefaults.river={start:'2026-11-02',length:8,unit:'weeks'};dept='river';addRotations(2);
let mr=rotationsOf('river');must(mr[0].start==='2026-11-02'&&date(mr[0].start).getDay()===1,'Monday rotation');
const firstDow=h=>h.split('<div class="dow">')[1].split('<')[0],firstDate=h=>h.split('data-date="')[1].slice(0,10);
rotationSel.river=mr[0].id;mode='Rotation';let wk=calendarCells();
must(firstDow(wk)==='Mon','Rotation weeks start on Monday');
must(wk.split('class="day ').length-1===56&&firstDate(wk)==='2026-11-02'&&!wk.includes('class="day out'),'Eight whole Mon–Sun weeks, first cell is the start date');
must(wk.includes('Week 1')&&wk.includes('Week 8')&&!wk.includes('Week 9'),'Week numbers within the rotation');
mode='Week';cursor=date('2026-11-12');must(visibleRange().start==='2026-11-09'&&visibleRange().end==='2026-11-15'&&firstDow(calendarCells())==='Mon','Week view runs Mon–Sun');
mode='Month';cursor=new Date(2026,10,1);must(firstDow(calendarCells())==='Mon','Month columns follow the rotation weekday');
let wr={...nextRotation('river'),start:plus(mr[1].end,3)};wr.end=addDuration(wr.start,8,'weeks');state.rotations.push(wr);validateRotations(state.rotations);
rotationSel.river=wr.id;mode='Rotation';cursor=date(wr.start);wk=calendarCells();
must(date(wr.start).getDay()===3&&firstDow(wk)==='Wed'&&firstDate(wk)===wr.start,'A Wednesday rotation runs Wed–Tue');
mode='Week';cursor=date(plus(wr.start,9));must(date(visibleRange().start).getDay()===3,'Week view inside a Wednesday rotation starts Wednesday');
let grid=patternGrid({},'x',1);must(grid.indexOf('<th>Mon</th>')<grid.indexOf('<th>Sun</th>'),'Weekly shifts grid follows the rotation week order');
must(firstDow((dept='willow',mode='Rotation',rotationSel.willow=rotationsOf('willow')[0].id,calendarCells()))==='Sun','Each rotation uses its own start weekday (Jones starts Sunday)');
// Rotation view for a team without rotations offers set-up instead of silently switching to Month
state.rotations=state.rotations.filter(r=>r.dept!=='willow');state.rotationDefaults.willow={start:'2026-11-02',length:8,unit:'weeks'};dept='willow';rotationSel={};view='Schedule';
setMode('Rotation');let sv=schedule();
must(mode==='Rotation'&&sv.includes('Create rotations for Jones Team')&&sv.includes('value="2026-11-02"')&&!sv.includes('class="calendar '),'Rotation view shows the set-up panel, prefilled from defaults');
must(sv.includes('onclick="generateDialog()" disabled'),'Generate is disabled until rotations exist');
let fake={preventDefault(){},target:null};const FD=globalThis.FormData;globalThis.FormData=function(){return {get:k=>({start:'2026-11-02',length:'8',unit:'weeks',count:'3'})[k]}};
quickCreateRotations(fake);globalThis.FormData=FD;
must(rotationsOf('willow').length===3&&mode==='Rotation'&&period().rotation.start==='2026-11-02'&&rotationsOf('willow')[0].holidays.some(h=>h.name==='Thanksgiving Day'),'Quick create makes rotations with team holidays and opens the first');
must(schedule().includes('class="calendar ')&&calendarCells().split('<div class="dow">')[1].startsWith('Mon'),'Rotation calendar appears, weeks Mon–Sun');
console.log('PASS: Rotation view set-up for teams without rotations (prefilled, quick create); weeks start on each rotation’s start weekday (rotation/week/month views, week numbers, grid order); weekly shift patterns per rotation (team default, weekday selection, date-specific shifts, precedence, validation, generation); rotation-first views (month/week target the covering rotation, no month fallback, no coverage outside rotations, rotation/month/week reports, request rotations, CSV rotation, rotation-first sample); team holiday calendars (rules, per-team, copy, sync, frozen when published), per-rotation limits migration, durations, per-team rotations from defaults, standard holidays, validation, holiday coverage overrides, year-over-year holiday rotation, rotation generation/max/publish/locks, rendering, CSV');`,ctx);
