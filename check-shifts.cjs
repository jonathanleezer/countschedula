const vm=require('node:vm'),fs=require('node:fs'),assert=require('node:assert/strict');let code=fs.readFileSync('dist/app.js','utf8');code=code.slice(0,code.lastIndexOf('if(!localStorage.getItem(KEY))'));let ctx=vm.createContext({console,crypto:require('node:crypto').webcrypto,localStorage:{getItem:()=>null,setItem:()=>{}},document:{addEventListener:()=>{},querySelector:()=>({open:false}),querySelectorAll:()=>[]}});vm.runInContext(code,ctx);vm.runInContext(`render=()=>{};toast=()=>{};
if(state.shiftTypes.length!==6)throw Error('Six sample types required');
if(shiftHours('clinic-am')!==4||shiftHours('night')!==12||shiftHours('flex')!==8)throw Error('Durations wrong');
let a={id:'a',provider:'p0',dept:'willow',date:'2026-11-01',shift:'night'},[s,e]=interval(a);if(new Date(e).getDate()!==2||new Date(e).getHours()!==7)throw Error('Overnight rollover');
state.assignments=[{...a,shift:'clinic-am'}];if(!violations({...a,id:'b',shift:'day'}).some(e=>e.includes('Overlapping')))throw Error('Custom overlap missed');
state.requests.push({provider:'p0',status:'Approved',start:'2026-11-02',end:'2026-11-02'});if(!violations(a).some(e=>e.includes('PTO')))throw Error('Overnight PTO missed');
state=migrate(seed());shiftType('triage').coverage=1;if(totalSlots()!==90||coverageMissing().length!==90)throw Error('Custom coverage not counted');generate(true);if(!state.assignments.some(a=>a.shift==='triage')||validateAll().length)throw Error('Generator ignores custom type');
if(!assignmentDialog.toString().includes('shiftOptions'))throw Error('Editor not configurable');
let old=migrate({rules:{dayCoverage:2,nightCoverage:3}});if(old.shiftTypes[0].coverage!==2||old.shiftTypes[1].coverage!==3)throw Error('Legacy coverage lost');
let invalid=JSON.parse(JSON.stringify(state.shiftTypes));invalid[0].end=invalid[0].start;try{validateShiftTypes(invalid);throw Error('Equal times accepted')}catch(e){if(e.message==='Equal times accepted')throw e}
let html=calendarCells()+reportsPage()+shiftTypesPage();if(html.includes('undefined')||html.includes('NaN'))throw Error('Rendering invalid values');
console.log('PASS: six types, legacy migration, durations, overnight rollover/PTO, custom overlap, coverage, generator, rendering, configuration validation');`,ctx);
