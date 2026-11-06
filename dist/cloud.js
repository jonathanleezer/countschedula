// CountSchedula shared-workspace client (Supabase).
// Active only when config.js defines window.COUNTSCHEDULA_CONFIG; otherwise the app runs as the
// original browser-local pilot. app.js keeps its UI and client-side checks; every change is then
// sent to the save_state RPC, which re-validates it on the server and is the final authority.
(function(){
  const cfg=window.COUNTSCHEDULA_CONFIG;
  if(!cfg||!cfg.supabaseUrl||!cfg.supabaseKey)return;
  const sb=window.supabase.createClient(cfg.supabaseUrl,cfg.supabaseKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
  let ws=null,wsName='',version=0,role=null,user=null,notes=[],nextMode='edit',chain=Promise.resolve(),epoch=0,inflight=0,seq=0,booted=false,pollTimer=null;
  const roleNames={admin:'Administrator',scheduler:'Scheduler',viewer:'Viewer (read only)'};
  const h=s=>esc(s); // app.js HTML escaper

  let failed=false;
  function setStatus(text,bad){failed=!!bad;const el=document.querySelector('.header-right span:nth-child(2)');if(el)el.textContent=text;const dot=document.querySelector('.localdot');if(dot)dot.style.background=bad?'#b4573f':''}
  function chrome(){
    document.body.classList.remove('cs-auth');
    const p=document.querySelector('.profile');
    if(p&&user){const email=user.email||'';p.innerHTML=`<span class="avatar purple">${h(email.slice(0,2).toUpperCase())}</span><span>${h(email)}<small>${h(roleNames[role]||'')}</small></span><span>⚙</span>`}
    const w=document.querySelector('.workspace span:nth-child(2)');if(w)w.innerHTML=`${h(wsName)}<small>Shared scheduling workspace</small>`;
    const f=document.querySelector('footer span:last-child');if(f)f.textContent='Shared workspace · Server-validated changes';
    setStatus(inflight?'Saving…':'Saved to shared workspace');
  }
  function errorText(error){
    if(!error)return 'Unknown error';
    if(error.message&&/fetch|network/i.test(error.message))return 'Could not reach the server. Check your connection.';
    return error.message||String(error);
  }

  async function signInScreen(message){
    booted=false;clearInterval(pollTimer);
    document.body.classList.add('cs-auth');setStatus('Not signed in');
    const hash=new URLSearchParams(location.hash.slice(1)),err=hash.get('error_description');
    if(err)window.history.replaceState(null,'',location.pathname);
    $('#breadcrumb').textContent='Sign in';$('#nav').innerHTML='';
    $('#main').innerHTML=`<div class="auth-card panel"><a class="brand" href="#"><span class="mark">c<span>·</span></span>CountSchedula</a><h1>Welcome back.</h1><p class="sub">Because staff scheduling doesn't have to suck the life out of you!</p><form id="cs-signin"><label>Work email<input type="email" name="email" required autocomplete="email" maxlength="200"></label><button class="primary">Email me a sign-in link</button></form><p id="cs-authmsg" role="status" class="${err?'danger':''}">${h(message||err||'Invited team members only. We’ll email you a one-time link—no password needed.')}</p></div>`;
    $('#cs-signin').addEventListener('submit',async e=>{
      e.preventDefault();const email=new FormData(e.target).get('email').trim(),msg=$('#cs-authmsg'),btn=e.target.querySelector('button');
      btn.disabled=true;msg.className='';msg.textContent='Sending…';
      const {error}=await sb.auth.signInWithOtp({email,options:{emailRedirectTo:location.origin+location.pathname,shouldCreateUser:true}});
      btn.disabled=false;
      if(error){msg.className='danger';msg.textContent=/invited|not been invited/i.test(error.message)?'That email has not been invited yet. Ask your workspace administrator.':/rate|seconds/i.test(error.message)?'Too many sign-in emails were requested. Please wait a few minutes and try again.':errorText(error);return}
      msg.textContent='Check your inbox for a sign-in link from CountSchedula. You can close this tab.';
    });
  }

  async function noAccessScreen(){
    document.body.classList.add('cs-auth');
    $('#main').innerHTML=`<div class="auth-card panel"><h1>Almost there.</h1><p>You are signed in as <b>${h(user.email)}</b>, but you have not been added to a workspace yet. Ask a workspace administrator to invite this email address.</p><button data-cs="signout">Sign out</button></div>`;
  }

  function apply(data){
    version=data.version;role=data.role;ws=data.workspace.id;wsName=data.workspace.name;
    state=migrate(data.state);
  }
  async function reload(message){
    const {data,error}=await sb.rpc('get_state',{p_ws:ws});
    if(error){setStatus('Not connected',true);toast('Could not load the shared workspace: '+errorText(error));return false}
    epoch++;notes=[];nextMode='edit';const first=!booted;apply(data);if(first)mode=defaultMode();history.length=0;failed=false;chrome();render();
    if(message)toast(message);
    return true;
  }

  let loading=null;
  function loadOnce(){return loading||(loading=loadWorkspace().finally(()=>{loading=null}))}
  async function loadWorkspace(){
    const {data:{user:u}}=await sb.auth.getUser();user=u;
    if(!user)return signInScreen();
    const {data:list,error}=await sb.rpc('my_workspaces');
    if(error){$('#main').innerHTML=`<div class="auth-card panel"><h1>Connection problem</h1><p class="danger">${h(errorText(error))}</p><button onclick="location.reload()">Try again</button></div>`;return}
    if(!list.length)return noAccessScreen();
    ws=(list.find(w=>w.id===cfg.workspace)||list[0]).id;
    if(await reload()){booted=true;startPolling()}
  }

  function startPolling(){
    clearInterval(pollTimer);
    const check=async()=>{
      if(!booted||inflight||document.visibilityState!=='visible'||$('#modal').open)return;
      const {data,error}=await sb.rpc('get_version',{p_ws:ws});
      if(!error&&data!=null&&data>version&&!inflight)reload('Updated with the latest changes from your team.');
    };
    pollTimer=setInterval(check,30000);
    document.addEventListener('visibilitychange',check);
  }

  async function send(st,n,mode,my){
    const {data,error}=await sb.rpc('save_state',{p_ws:ws,p_base_version:version,p_state:st,p_notes:n,p_mode:mode});
    if(error){
      epoch++; // drop saves queued behind the rejected one: they were built on top of it
      const code=error.code||'';
      const text=code==='PT409'?errorText(error):code==='PT403'?errorText(error):code==='PT422'?'Not saved — '+errorText(error):'Not saved — '+errorText(error);
      setStatus('Change not saved',true);
      await reload();
      toast(text);
      return;
    }
    version=data.version;
    if(my===seq){
      const before=JSON.stringify([state.periods,state.rotations]);
      state.audit=data.audit;state.periods=data.periods;if(Array.isArray(data.rotations))state.rotations=data.rotations;
      if(before!==JSON.stringify([state.periods,state.rotations])||view==='Activity')render();
    }
  }

  window.CountSchedulaCloud={
    active:true,
    note(text){notes.push(String(text).slice(0,500))},
    async publicationHistory(department,rotationId){const {data,error}=await sb.rpc('list_publications',{p_ws:ws,p_dept:department,p_month:rotationId});return error?null:data},
    roleLabel(){return (roleNames[role]||role||'')+(user?' · '+user.email:'')},
    save(){
      if(!booted)return;
      const st=JSON.parse(JSON.stringify(state)),n=notes.splice(0),mode=nextMode,my=++seq,e=epoch;
      nextMode='edit';
      if(mode!=='import')delete st.audit;
      if(role==='viewer'){toast('Your role is read-only. Ask a workspace administrator for scheduler access.');reload();return}
      inflight++;setStatus('Saving…');
      chain=chain.then(()=>e===epoch?send(st,n,mode,my):null).catch(err=>{toast('Not saved — '+errorText(err));return reload()}).finally(()=>{inflight--;if(!inflight&&booted&&!failed)setStatus('Saved to shared workspace')});
    },
    confirmImport(data){
      if(role!=='admin'){toast('Only administrators can restore a backup into the shared workspace.');return}
      const published=Object.values(data.periods||{}).filter(p=>p.status==='Published').length;
      modal(`<h2>Restore this backup for everyone?</h2><p>This replaces the shared ${h(wsName)} workspace. A rollback snapshot of the current workspace is saved first.</p><table><tr><td>Providers</td><td>${data.providers.length}</td></tr><tr><td>Assignments</td><td>${data.assignments.length}</td></tr><tr><td>Time-off requests</td><td>${data.requests.length}</td></tr><tr><td>Shift types</td><td>${data.shiftTypes.length}</td></tr><tr><td>Published schedules</td><td>${published}</td></tr><tr><td>Activity entries</td><td>${data.audit.length}</td></tr></table><div class="modalactions"><button onclick="closeModal()">Cancel</button><button class="primary" data-cs="do-import">Restore backup</button></div>`);
      pendingImport=data;
    },
    settingsPanels(){
      setTimeout(fillSettings,0);
      return `<div class="below" style="margin-top:20px"><div class="panel"><h3>Your account</h3><p>Signed in as <b>${h(user?.email||'')}</b><br>Role: ${h(roleNames[role]||role||'')}</p><button data-cs="signout">Sign out</button></div>${role==='admin'?`<div class="panel" id="cs-members"><h3>Team access</h3><p>Loading…</p></div>`:''}</div>${role==='admin'?`<div class="panel" id="cs-snapshots" style="margin-top:20px"><h3>Rollback snapshots</h3><p>Loading…</p></div>`:''}`;
    },
    boot(){
      const f=document.querySelector('footer span:last-child');if(f)f.textContent='Shared workspace · Server-validated changes';
      sb.auth.onAuthStateChange((event)=>{if(event==='SIGNED_OUT')signInScreen();else if(event==='SIGNED_IN'&&!booted)loadOnce()});
      $('#main').innerHTML='<div class="auth-card panel"><p>Loading your workspace…</p></div>';
      sb.auth.getSession().then(({data:{session}})=>session?loadOnce():signInScreen());
    }
  };
  let pendingImport=null;

  async function fillSettings(){
    if(role!=='admin')return;
    const m=document.getElementById('cs-members');
    if(m){
      const {data,error}=await sb.rpc('list_members',{p_ws:ws});
      if(error){m.innerHTML=`<h3>Team access</h3><p class="danger">${h(errorText(error))}</p>`}
      else renderMembers(m,data);
    }
    const s=document.getElementById('cs-snapshots');
    if(s){
      const {data,error}=await sb.rpc('list_snapshots',{p_ws:ws});
      s.innerHTML=`<h3>Rollback snapshots</h3><p>Taken before every restore and at most once a day while people edit. Kept for 45 days (the newest 10 are always kept).</p>`+(error?`<p class="danger">${h(errorText(error))}</p>`:data.length?`<div class="tablewrap"><table><thead><tr><th>When</th><th>Reason</th><th>By</th><th></th></tr></thead><tbody>${data.map(x=>`<tr><td>${h(new Date(x.at).toLocaleString())}</td><td>${h(x.reason)}</td><td>${h(x.by||'—')}</td><td><button data-cs="snap-download" data-id="${Number(x.id)}">Download</button> <button data-cs="snap-rollback" data-id="${Number(x.id)}" data-at="${h(x.at)}">Roll back</button></td></tr>`).join('')}</tbody></table></div>`:'<p class="muted">No snapshots yet.</p>');
    }
  }
  function renderMembers(el,data){
    const opts=r=>['admin','scheduler','viewer'].map(x=>`<option value="${x}" ${x===r?'selected':''}>${h(roleNames[x])}</option>`).join('');
    el.innerHTML=`<h3>Team access</h3><div class="tablewrap"><table><thead><tr><th>Member</th><th>Role</th><th></th></tr></thead><tbody>${data.members.map(x=>`<tr><td>${h(x.email)}${x.user_id===user.id?' <small class="muted">(you)</small>':''}<br><small class="muted">${x.last_sign_in?'Last sign-in '+h(new Date(x.last_sign_in).toLocaleDateString()):'Never signed in'}</small></td><td><select data-cs="role" data-user="${h(x.user_id)}" aria-label="Role for ${h(x.email)}">${opts(x.role)}</select></td><td><button class="danger" data-cs="remove" data-user="${h(x.user_id)}" data-email="${h(x.email)}">Remove</button></td></tr>`).join('')}${data.invitations.map(x=>`<tr><td>${h(x.email)}<br><small class="muted">Invited · not signed in yet</small></td><td>${h(roleNames[x.role])}</td><td><button data-cs="revoke" data-email="${h(x.email)}">Revoke</button></td></tr>`).join('')}</tbody></table></div><form id="cs-invite" class="formgrid" style="margin-top:12px"><label>Email<input type="email" name="email" required maxlength="200"></label><label>Role<select name="role">${opts('scheduler')}</select></label><div class="full"><button class="primary">Invite</button></div></form><p class="muted">Invited people sign in from this site with their email. On the free email service only a few sign-in emails can be sent per hour; configure custom SMTP in Supabase before inviting a whole team.</p><div id="cs-member-error" class="danger" role="alert"></div>`;
    el.querySelector('#cs-invite').addEventListener('submit',async e=>{e.preventDefault();const f=new FormData(e.target);memberCall('invite_member',{p_ws:ws,p_email:f.get('email'),p_role:f.get('role')},'Invitation saved')});
  }
  async function memberCall(fn,args,ok){
    const {data,error}=await sb.rpc(fn,args),el=document.getElementById('cs-members');
    if(error){const e=document.getElementById('cs-member-error');if(e)e.textContent=errorText(error);else toast(errorText(error));fillSettings();return}
    version++; // membership changes bump the workspace version
    if(el)renderMembers(el,data);toast(ok);
  }

  document.addEventListener('change',e=>{const t=e.target.closest('[data-cs="role"]');if(t)memberCall('set_member_role',{p_ws:ws,p_user:t.dataset.user,p_role:t.value},'Role updated')});
  document.addEventListener('click',async e=>{
    const t=e.target.closest('[data-cs]');if(!t||t.tagName==='SELECT')return;
    const a=t.dataset.cs;
    if(a==='signout'){e.preventDefault();await sb.auth.signOut();state=migrate({...seed(),providers:[],assignments:[],requests:[]});history.length=0;booted=false;signInScreen('You are signed out.')}
    else if(a==='revoke')memberCall('revoke_invitation',{p_ws:ws,p_email:t.dataset.email},'Invitation revoked');
    else if(a==='remove'){modal(`<h2>Remove ${h(t.dataset.email)}?</h2><p>They will lose access to this workspace immediately.</p><div class="modalactions"><button onclick="closeModal()">Cancel</button><button class="primary danger" data-cs="remove-confirm" data-user="${h(t.dataset.user)}">Remove</button></div>`)}
    else if(a==='remove-confirm'){closeModal();memberCall('remove_member',{p_ws:ws,p_user:t.dataset.user},'Member removed')}
    else if(a==='do-import'&&pendingImport){const data=pendingImport;pendingImport=null;closeModal();checkpoint();state=data;focusRotations();nextMode='import';commit('Restored workspace backup');toast('Restoring backup…')}
    else if(a==='snap-download'||a==='snap-rollback'){
      const {data,error}=await sb.rpc('get_snapshot',{p_ws:ws,p_id:Number(t.dataset.id)});
      if(error||!data){toast('Could not load snapshot: '+errorText(error));return}
      if(a==='snap-download'){download(JSON.stringify(data,null,2),'CountSchedula-snapshot-'+t.dataset.id+'.json','application/json');return}
      modal(`<h2>Roll back the shared workspace?</h2><p>Everything returns to the snapshot from ${h(new Date(t.dataset.at).toLocaleString())}. The current state is saved as a new snapshot first, so this can be undone the same way.</p><div class="modalactions"><button onclick="closeModal()">Cancel</button><button class="primary" data-cs="snap-confirm" data-id="${Number(t.dataset.id)}">Roll back</button></div>`);
      pendingImport={snapshotId:Number(t.dataset.id),data};
    }
    else if(a==='snap-confirm'&&pendingImport?.snapshotId){const data=pendingImport.data;pendingImport=null;closeModal();checkpoint();state=migrate(data);focusRotations();nextMode='import';commit('Rolled back to snapshot #'+t.dataset.id);toast('Rolling back…')}
  });
})();
