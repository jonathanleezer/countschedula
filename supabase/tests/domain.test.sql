-- Database tests for CountSchedula's server-side rules, access control and history.
-- Run with: npm run test:db   (expects psql variable :sample containing sample-workspace.json)
\set ON_ERROR_STOP 1
\set QUIET 1

-- ------------------------------------------------------------ helpers (test database only)
create function public.t_login(p_uid text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_uid, false)::text; select null::void $$;

create function public.expect_fail(q text, code text, pattern text) returns void language plpgsql as $$
declare ok boolean := false;
begin
  begin
    execute q;
    ok := true;
  exception when others then
    if sqlstate <> code or sqlerrm !~* pattern then
      raise exception 'Wrong error for [%]: % %', left(q, 120), sqlstate, sqlerrm;
    end if;
  end;
  if ok then raise exception 'Expected failure % /%/ for: %', code, pattern, left(q, 160); end if;
end $$;

create function public.t_assert(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'ASSERTION FAILED: %', label; end if;
  raise notice 'ok - %', label;
end $$;

create function public.t_st() returns jsonb language sql as $$ select get_state('vm')->'state' $$;
create function public.t_save(st jsonb, mode text default 'edit', notes text[] default '{}') returns jsonb language sql as $$
  select save_state('vm', get_version('vm'), st, notes, mode) $$;
create function public.t_add(st jsonb, a jsonb) returns jsonb language sql as $$
  select jsonb_set(st, '{assignments}', (st->'assignments') || jsonb_build_array(a)) $$;
create function public.t_set_period(st jsonb, k text, status text) returns jsonb language sql as $$
  select jsonb_set(st, '{periods}', (st->'periods') || jsonb_build_object(k, jsonb_build_object('status', status))) $$;
create function public.t_with_rot(st jsonb, rots jsonb) returns jsonb language sql as $$ select jsonb_set(st, '{rotations}', rots) $$;
grant execute on all functions in schema public to authenticated;
-- re-apply the production grants that the line above widened
revoke execute on function public.cs_bootstrap_workspace(text, text, text, text) from authenticated;
revoke execute on function public.hook_before_user_created(jsonb) from authenticated;

\set admin    '''a0000000-0000-0000-0000-000000000001'''
\set sched    '''a0000000-0000-0000-0000-000000000002'''
\set viewer   '''a0000000-0000-0000-0000-000000000003'''
\set outsider '''a0000000-0000-0000-0000-000000000004'''

-- ------------------------------------------------------------ bootstrap and membership
select cs_bootstrap_workspace('vm', 'Vanderbilt Midwives', 'Admin@Example.test');
select cs_bootstrap_workspace('other', 'Other Workspace', 'outsider@example.test');
insert into auth.users(id, email) values (:admin, 'admin@example.test'), (:outsider, 'outsider@example.test');
select t_assert((select role from members where user_id = :admin and workspace_id = 'vm') = 'admin', 'invited admin becomes member on sign-up (case-insensitive email)');
select t_assert(hook_before_user_created('{"user":{"email":"ADMIN@example.test"}}') = '{}'::jsonb, 'sign-up hook allows invited email');
select t_assert(hook_before_user_created('{"user":{"email":"stranger@example.test"}}') ? 'error', 'sign-up hook rejects uninvited email');

set role authenticated;
select t_login(:admin);
select t_assert((select count(*) from departments where workspace_id = 'vm') = 2, 'admin reads own departments via RLS');
select t_assert(get_state('vm')->>'role' = 'admin', 'get_state returns role');
select t_assert(jsonb_array_length(t_st()->'shiftTypes') = 6, 'bootstrap creates six default shift types');
select expect_fail($$select get_state('other')$$, 'PT403', 'access');
select t_assert((select count(*) from workspaces) = 1, 'RLS hides other workspaces');
select expect_fail($$insert into assignments values ('vm','x','p0','willow','2026-11-01','day',null,0)$$, '42501', 'permission denied');
select expect_fail($$update workspaces set version = 99$$, '42501', 'permission denied');
select expect_fail($$select cs_bootstrap_workspace('evil','x','e@x.test')$$, '42501', 'permission denied');

select invite_member('vm', 'sched@example.test', 'scheduler');
select invite_member('vm', 'viewer@example.test', 'viewer');
select expect_fail($$select invite_member('vm', 'not-an-email', 'viewer')$$, 'PT422', 'valid email');
reset role;
insert into auth.users(id, email) values (:sched, 'sched@example.test'), (:viewer, 'viewer@example.test');
set role authenticated;

-- ------------------------------------------------------------ import (admin only) and round trip
select t_login(:sched);
select expect_fail(format($$select t_save(%L::jsonb, 'import')$$, :'sample'), 'PT403', 'administrators');
select t_login(:admin);
select t_save(:'sample'::jsonb, 'import', array['Restored workspace backup']);
select t_assert(jsonb_array_length(t_st()->'assignments') = 60, 'import keeps 60 assignments');
select t_assert((select jsonb_agg(e - 'rotationTarget' - 'rotationMax') from jsonb_array_elements(t_st()->'providers') e) = (:'sample'::jsonb)->'providers', 'providers round-trip exactly (ids, affiliations, numbers)');
select t_assert((select bool_and((e->>'rotationTarget')::numeric = (e->>'target')::numeric * 2 and (e->>'rotationMax')::numeric = (e->>'max')::numeric * 2)
  from jsonb_array_elements(t_st()->'providers') e), 'older backups get rotation limits of 2 x monthly');
select t_assert(t_st()->'shiftTypes' = (:'sample'::jsonb)->'shiftTypes', 'shift types round-trip exactly');
select t_assert(t_st()->'assignments' = (:'sample'::jsonb)->'assignments', 'assignments round-trip exactly');
select t_assert(t_st()->'requests' = (:'sample'::jsonb)->'requests', 'requests round-trip exactly');
select t_assert(t_st()->'rules' = (:'sample'::jsonb)->'rules', 'rules (incl. legacy coverage keys) round-trip');
select t_assert(jsonb_array_length(list_snapshots('vm')) >= 1, 'import takes a rollback snapshot');
select t_save(:'sample'::jsonb, 'import');
select t_assert((select count(*) from audit_log where workspace_id = 'vm' and kind = 'imported')
                = jsonb_array_length((:'sample'::jsonb)->'audit'), 're-import does not duplicate imported audit entries');

-- ------------------------------------------------------------ hard rules (edit mode)
select t_login(:sched);
select expect_fail($$select save_state('vm', get_version('vm') - 1, t_st())$$, 'PT409', 'someone else');
select t_login(:viewer);
select expect_fail($$select t_save(t_st())$$, 'PT403', 'read-only');
select t_login(:sched);

-- cross-organization overlap (provider affiliated with both teams)
select expect_fail($$select t_save(t_add(t_st(), (select a || '{"id":"t-overlap","dept":"river"}'
  from jsonb_array_elements(t_st()->'assignments') a where (select affiliations from jsonb_to_recordset(t_st()->'providers') as p(id text, affiliations jsonb) where p.id = a->>'provider') ? 'river' limit 1)))$$,
  'PT422', 'Overlapping assignment · Jones Team');
-- affiliation
select expect_fail($$select t_save(t_add(t_st(), '{"id":"t-aff","provider":"p7","dept":"river","date":"2026-11-30","shift":"clinic-am"}'))$$,
  'PT422', 'not affiliated');
-- rest: a night right after the same provider's day shift
select expect_fail($$select t_save(t_add(t_st(), (select a || '{"id":"t-rest","shift":"night","dept":"willow"}'
  from jsonb_array_elements(t_st()->'assignments') a where a->>'shift' = 'day' limit 1)))$$, 'PT422', 'rest not met');
-- unknown references / injection-shaped ids
select expect_fail($$select t_save(t_add(t_st(), '{"id":"t-x","provider":"nobody","dept":"willow","date":"2026-11-30","shift":"day"}'))$$,
  'PT422', 'does not exist');
select expect_fail($$select t_save(t_add(t_st(), '{"id":"x\"><img src=x onerror=alert(1)>","provider":"p0","dept":"willow","date":"2026-12-30","shift":"day"}'))$$,
  'PT422', 'Invalid workspace data');
select expect_fail($$select t_save(jsonb_set(t_st(), '{providers,0,id}', '"p0'');alert(1);//"'))$$, 'PT422', 'Invalid workspace data');
select expect_fail($$select t_save(t_add(t_st(), '{"id":"t-date","provider":"p0","dept":"willow","date":"2026-02-30","shift":"day"}'))$$,
  'PT422', 'Invalid workspace data');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rules,rest}', '500'))$$, 'PT422', 'out of range');
-- night eligibility
select t_save(jsonb_set(t_st(), '{providers,7,nights}', 'false'));
select expect_fail($$select t_save(t_add(t_st(), '{"id":"t-night","provider":"p7","dept":"willow","date":"2026-12-05","shift":"night"}'))$$,
  'PT422', 'unavailable for nights');
select t_save(jsonb_set(t_st(), '{providers,7,nights}', 'true'));
-- monthly maximum
select t_save(jsonb_set(jsonb_set(t_st(), '{providers,6,target}', '1'), '{providers,6,max}', to_jsonb((select count(*) from assignments where provider_id = 'p6' and to_char(date,'YYYY-MM') = '2026-11'))));
select expect_fail($$select t_save(t_add(t_st(), '{"id":"t-max","provider":"p6","dept":"willow","date":"2026-11-30","shift":"clinic-am"}'))$$,
  'PT422', 'Monthly maximum');
-- consecutive days: four December days in a row with consecutive limit 3
select t_save(t_add(t_add(t_add(t_st(),
  '{"id":"t-c1","provider":"p3","dept":"willow","date":"2026-12-15","shift":"day"}'),
  '{"id":"t-c2","provider":"p3","dept":"willow","date":"2026-12-16","shift":"day"}'),
  '{"id":"t-c3","provider":"p3","dept":"willow","date":"2026-12-17","shift":"day"}'));
select expect_fail($$select t_save(t_add(t_st(), '{"id":"t-c4","provider":"p3","dept":"willow","date":"2026-12-18","shift":"day"}'))$$,
  'PT422', 'consecutive');
-- a valid edit succeeds and is audited with the actor
select t_save(t_add(t_st(), '{"id":"t-ok","provider":"p3","dept":"willow","date":"2026-12-10","shift":"clinic-am","note":"ok"}'), 'edit', array['Assigned Rachel Morgan']);
select t_assert((select actor_email from audit_log where text = 'Assigned Rachel Morgan') = 'sched@example.test', 'audit records actor email');
-- PTO approval blocked by overlapping assignment
select expect_fail($$select t_save(jsonb_set(t_st(), '{requests}', (t_st()->'requests') || '[{"id":"t-pto","provider":"p3","start":"2026-12-10","end":"2026-12-10","status":"Approved"}]'))$$,
  'PT422', 'Approval blocked');

-- ------------------------------------------------------------ publication
select expect_fail($$select t_save(t_set_period(t_st(), 'river:2026-11', 'Published'))$$, 'PT422', 'Cannot publish 2026-11: 60 open shifts');
select t_save(t_set_period(t_st(), 'willow:2026-11', 'Published'), 'edit', array['Published Jones Team · Labor & Delivery · 2026-11']);
select t_assert((select jsonb_array_length(snapshot) from periods where dept_id = 'willow' and month = '2026-11') = 60, 'server builds the publication snapshot');
select t_assert((select count(*) from publications where dept_id = 'willow' and month = '2026-11') = 1, 'publication history row recorded');
select expect_fail($$select t_save(jsonb_set(t_st(), '{assignments,0,note}', '"edit after publish"'))$$, 'PT422', 'is published');
select expect_fail($$select t_save(jsonb_set(t_st(), '{shiftTypes,4,coverage}', '1'))$$, 'PT422', 'Reopen affected');
select expect_fail($$select t_save(jsonb_set(t_st(), '{shiftTypes,0,end}', '"18:00"'))$$, 'PT422', 'Reopen affected');
select expect_fail($$select t_save(jsonb_set(t_st(), '{providers,0,affiliations}', '["river"]'))$$, 'PT422', 'conflict with a published');
-- the other organization stays independently editable
select t_save(t_add(t_st(), '{"id":"t-boehm","provider":"p1","dept":"river","date":"2026-12-12","shift":"day"}'));
-- reopen, then edit
select t_save(t_set_period(t_st(), 'willow:2026-11', 'Draft'), 'edit', array['Reopened schedule · 2026-11']);
select t_save(jsonb_set(t_st(), '{assignments,0,note}', '"edit after reopen"'));
select t_assert((t_st()->'assignments'->0->>'note') = 'edit after reopen', 'reopened schedule is editable');
select t_save(t_set_period(t_st(), 'willow:2026-11', 'Published'));
select t_assert((select count(*) from publications where dept_id = 'willow' and month = '2026-11') = 2, 'republish appends history');
-- undoing a first publish (period key disappears) reopens instead of leaving a hidden lock
select t_save(t_st() #- '{periods,willow:2026-11}');
select t_assert((select status from periods where dept_id = 'willow' and month = '2026-11') = 'Draft', 'missing published period is reopened');

-- ------------------------------------------------------------ immutability and roles
reset role;
select expect_fail($$update audit_log set text = 'tampered'$$, 'PT403', 'append-only');
select expect_fail($$delete from publications$$, 'PT403', 'append-only');
set role authenticated;
select t_login(:sched);
select expect_fail($$select list_members('vm')$$, 'PT403', 'Administrators');
select t_login(:admin);
select expect_fail(format($$select set_member_role('vm', %L, 'viewer')$$, :admin), 'PT422', 'at least one administrator');
select t_assert(jsonb_array_length(list_members('vm')->'members') = 3, 'admin lists members');
select t_login(:outsider);
select t_assert((select count(*) from assignments) = 0, 'outsider sees no Vanderbilt assignments');
select expect_fail($$select save_state('vm', 0, '{}'::jsonb)$$, 'PT403', 'access');
select t_login('');
select expect_fail($$select get_state('vm')$$, 'PT403', 'access');
-- ------------------------------------------------------------ rotations (per team) and holidays
select t_login(:sched);
select t_save(t_with_rot(t_st(), '[{"id":"r-nov","dept":"willow","name":"Nov rotation","start":"2026-11-01","end":"2026-11-30","status":"Draft","holidays":[{"id":"h-tg","name":"Thanksgiving Day","date":"2026-11-26","coverage":{}}]}]'), 'edit', array['Added rotation']);
select t_assert(t_st()->'rotations'->0->>'name' = 'Nov rotation' and t_st()->'rotations'->0->'holidays'->0->>'name' = 'Thanksgiving Day', 'rotation and holiday round-trip');
select expect_fail($$select t_save(t_with_rot(t_st(), (t_st()->'rotations') || '[{"id":"r-x","dept":"willow","name":"Overlap","start":"2026-11-20","end":"2026-12-20","status":"Draft","holidays":[]}]'))$$,
  'PT422', 'overlap');
select t_save(t_with_rot(t_st(), (t_st()->'rotations') || '[{"id":"r-boehm","dept":"river","name":"Boehm Nov","start":"2026-11-20","end":"2026-12-20","status":"Draft","holidays":[]}]'));
select t_assert(jsonb_array_length(t_st()->'rotations') = 2, 'teams have independent, possibly overlapping rotation calendars');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,holidays}', '[{"id":"h-bad","name":"Outside","date":"2027-01-01","coverage":{}}]'))$$, 'PT422', 'within the rotation');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,holidays,0,coverage}', '{"day":11}'))$$, 'PT422', 'whole numbers from 0 to 10');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotationDefaults}', '{"willow":{"start":"2026-11-01","length":8,"unit":"fortnights"}}'))$$, 'PT422', 'Rotation length');
select t_save(jsonb_set(t_st(), '{rotationDefaults}', '{"willow":{"start":"2026-11-01","length":8,"unit":"weeks"}}'));
select t_assert(t_st()->'rotationDefaults'->'willow'->>'unit' = 'weeks', 'rotation defaults saved');
-- older clients that do not send rotations leave them untouched
select t_save(t_st() - 'rotations' - 'rotationDefaults' - 'holidayHistory');
select t_assert(jsonb_array_length(t_st()->'rotations') = 2, 'payload without rotations keeps them');
-- holiday coverage override counts toward publication: Thanksgiving needs 2 day providers
select t_save(jsonb_set(t_st(), '{rotations,0,holidays,0,coverage}', '{"day":2}'));
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,status}', '"Published"'))$$, 'PT422', 'Cannot publish Nov rotation: 1 open shifts');
select t_save(jsonb_set(t_st(), '{rotations,0,holidays,0,coverage}', '{}'));
-- per-rotation maximum (rotation_max) replaces the monthly maximum inside a rotation
select t_save(jsonb_set(jsonb_set(t_st(), '{providers,5,rotationTarget}', '1'), '{providers,5,rotationMax}',
  to_jsonb((select count(*) from assignments where provider_id = 'p5' and date between '2026-11-01' and '2026-11-30'))));
select expect_fail($$select t_save(t_add(t_st(), '{"id":"t-rmax","provider":"p5","dept":"willow","date":"2026-11-28","shift":"clinic-pm"}'))$$,
  'PT422', 'Rotation maximum of \d+ shifts exceeded · Nov rotation');
select t_save(jsonb_set(t_st(), '{providers,5,rotationMax}', '28'));
-- publish the rotation (server builds snapshot, appends history), then it is locked
select t_save(jsonb_set(t_st(), '{rotations,0,status}', '"Published"'), 'edit', array['Published Nov rotation']);
select t_assert((select status = 'Published' and jsonb_array_length(snapshot) >= 60 from rotations where id = 'r-nov'), 'rotation published with server snapshot');
select t_assert((select count(*) from publications where rotation_id = 'r-nov') = 1, 'rotation publication history recorded');
select expect_fail($$select t_save(jsonb_set(t_st(), '{assignments,0,note}', '"edit inside published rotation"'))$$, 'PT422', 'Nov rotation is published');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,end}', '"2026-11-29"'))$$, 'PT422', 'Reopen Nov rotation before changing');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,holidays}', '[]'))$$, 'PT422', 'Reopen Nov rotation before changing');
select expect_fail($$select t_save(t_with_rot(t_st(), jsonb_build_array(t_st()->'rotations'->1)))$$, 'PT422', 'Reopen Nov rotation before deleting');
select expect_fail($$select t_save(jsonb_set(t_st(), '{shiftTypes,4,coverage}', '1'))$$, 'PT422', 'Reopen affected');
select t_save(t_add(jsonb_set(t_st(), '{providers}', (t_st()->'providers') || '[{"id":"p-boehm","name":"Boehm Only","role":"CNM","target":5,"max":10,"rotationTarget":10,"rotationMax":20,"nights":true,"affiliations":["river"]}]'),
  '{"id":"t-boehm-nov","provider":"p-boehm","dept":"river","date":"2026-11-28","shift":"clinic-am"}'));
select t_assert(exists (select 1 from assignments where id = 't-boehm-nov'), 'the other team stays editable during a published rotation');
-- reopen and edit
select t_save(jsonb_set(t_st(), '{rotations,0,status}', '"Draft"'), 'edit', array['Reopened Nov rotation']);
select t_save(jsonb_set(t_st(), '{assignments,0,note}', '"edit after rotation reopen"'));
select t_assert((select snapshot is not null from rotations where id = 'r-nov'), 'reopen keeps the published snapshot');
-- holiday history
select t_save(jsonb_set(t_st(), '{holidayHistory}', '[{"id":"hh1","provider":"p3","holiday":"Christmas Day","year":2025}]'));
select t_assert(t_st()->'holidayHistory'->0->>'holiday' = 'Christmas Day', 'holiday history round-trip');
select expect_fail($$select t_save(jsonb_set(t_st(), '{holidayHistory}', '[{"id":"hh2","provider":"p3","holiday":"X","year":1800}]'))$$, 'PT422', 'Invalid workspace data');
select expect_fail($$select t_save(jsonb_set(t_st(), '{holidayHistory}', '[{"id":"hh3","provider":"nobody","holiday":"X","year":2025}]'))$$, 'PT422', 'does not exist');
-- weekly shift patterns and date-specific shifts (server publish check mirrors required())
select t_assert(t_st()->'rotations'->0->'dateShifts' = '{}'::jsonb and not (t_st()->'rotations'->0 ? 'pattern'), 'rotations default to no pattern and no date-specific shifts');
select t_save(jsonb_set(t_st(), '{rotations,0,pattern}', '{"day":{"days":[0,1,2,3,4,5,6],"count":1},"night":{"days":[0,1,2,3,4,5,6],"count":1},"clinic-am":{"days":[1,2,3,4,5],"count":1}}'));
select t_assert(t_st()->'rotations'->0->'pattern'->'clinic-am'->'days' = '[1,2,3,4,5]', 'weekly pattern round-trip');
select t_assert(cs_required('vm', 'willow', '2026-11-02', 'clinic-am', 0, true) = 1 and cs_required('vm', 'willow', '2026-11-07', 'clinic-am', 0, true) = 0
  and cs_required('vm', 'willow', '2026-11-07', 'triage', 0, true) = 0 and cs_required('vm', 'river', '2026-11-25', 'triage', 0, true) = 0, 'server weekday pattern');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,status}', '"Published"'))$$, 'PT422', 'Cannot publish Nov rotation: 21 open shifts');
select t_save(jsonb_set(t_st(), '{rotations,0,dateShifts}', '{"2026-11-27":{"triage":2},"2026-11-26":{"day":3}}'));
select t_assert(cs_required('vm', 'willow', '2026-11-27', 'triage', 0, true) = 2 and cs_required('vm', 'willow', '2026-11-26', 'day', 1, true) = 3, 'date-specific shifts on the server (beat holidays)');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,status}', '"Published"'))$$, 'PT422', 'Cannot publish Nov rotation: 25 open shifts');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,pattern}', '{"day":{"days":[7],"count":1}}'))$$, 'PT422', 'days of the week');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,pattern}', '{"day":{"days":[1],"count":0}}'))$$, 'PT422', 'days of the week');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,dateShifts}', '{"2027-03-01":{"day":1}}'))$$, 'PT422', 'within the rotation dates');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,dateShifts}', '{"2026-11-27":{"day":11}}'))$$, 'PT422', 'date-specific shifts need');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotationDefaults,willow,pattern}', '{"day":{"days":[1,1],"count":1}}'))$$, 'PT422', 'Default rotation');
select t_save(jsonb_set(t_st(), '{rotationDefaults,willow,pattern}', '{"day":{"days":[0,1,2,3,4,5,6],"count":1}}'));
select t_assert(t_st()->'rotationDefaults'->'willow'->'pattern'->'day'->>'count' = '1', 'team default pattern saved');
-- publish with the daily-default pattern, then the pattern is frozen
select t_save(jsonb_set(jsonb_set(t_st() #- '{rotations,0,pattern}', '{rotations,0,dateShifts}', '{}'), '{rotations,0,status}', '"Published"'));
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,pattern}', '{"day":{"days":[1],"count":1}}'))$$, 'PT422', 'Reopen Nov rotation before changing its dates, weekly shifts');
select expect_fail($$select t_save(jsonb_set(t_st(), '{rotations,0,dateShifts}', '{"2026-11-27":{"triage":1}}'))$$, 'PT422', 'Reopen Nov rotation before changing');
select t_save(jsonb_set(t_st(), '{rotations,0,status}', '"Draft"'));
-- provider shift preferences (stored and validated; soft rules, never blocking)
select t_save(jsonb_set(t_st(), '{providers,3,preferences}', '{"weekly":{"night:2":"prefer","night:3":"prefer","day:5":"avoid"}}'));
select t_assert(t_st()->'providers'->3->'preferences'->'weekly'->>'day:5' = 'avoid' and not (t_st()->'providers'->0 ? 'preferences'), 'preferences round-trip; absent when unset');
select t_save(jsonb_set(t_st(), '{providers}', (select jsonb_agg(e - 'preferences') from jsonb_array_elements(t_st()->'providers') e)));
select t_assert(t_st()->'providers'->3->'preferences'->'weekly'->>'night:2' = 'prefer', 'payload without preferences keeps them (older clients)');
select expect_fail($$select t_save(jsonb_set(t_st(), '{providers,3,preferences}', '{"weekly":{"night:9":"prefer"}}'))$$, 'PT422', 'Invalid provider record');
select expect_fail($$select t_save(jsonb_set(t_st(), '{providers,3,preferences}', '{"weekly":{"night:2":"love"}}'))$$, 'PT422', 'Invalid provider record');
select t_save(jsonb_set(t_st(), '{providers,3,preferences}', 'null'));
select t_assert(not (t_st()->'providers'->3 ? 'preferences'), 'preferences can be cleared');
-- per-team holiday calendars
select t_save(jsonb_set(t_st(), '{teamHolidays}', '[{"id":"th-xmas","dept":"willow","name":"Christmas Day","kind":"fixed","month":12,"day":25,"coverage":{"day":2}},
  {"id":"th-tg","dept":"willow","name":"Thanksgiving Day","kind":"nth","month":11,"weekday":4,"nth":4,"coverage":{}},
  {"id":"th-b","dept":"river","name":"Founders Day","kind":"once","date":"2026-11-23","coverage":{}}]'));
select t_assert(jsonb_array_length(t_st()->'teamHolidays') = 3 and (select count(*) from team_holidays where dept_id = 'river') = 1
  and t_st()->'teamHolidays'->0->'coverage'->>'day' = '2' and not (t_st()->'teamHolidays'->2 ? 'month'), 'team holidays round-trip per team');
select t_save(jsonb_set(t_st(), '{rotations,1,holidays}', '[{"id":"hb1","name":"Founders Day","date":"2026-11-23","coverage":{},"team":"th-b"}]'));
select t_assert(t_st()->'rotations'->1->'holidays'->0->>'team' = 'th-b' and not (t_st()->'rotations'->0->'holidays'->0 ? 'team'), 'rotation holidays keep their team link');
select expect_fail($$select t_save(jsonb_set(t_st(), '{teamHolidays}', (t_st()->'teamHolidays') || '[{"id":"th-dup","dept":"willow","name":"christmas day","kind":"fixed","month":12,"day":24,"coverage":{}}]'))$$, 'PT422', 'Invalid workspace data');
select expect_fail($$select t_save(jsonb_set(t_st(), '{teamHolidays}', '[{"id":"th-x","dept":"willow","name":"X","kind":"weekly","coverage":{}}]'))$$, 'PT422', 'Invalid team holiday');
select expect_fail($$select t_save(jsonb_set(t_st(), '{teamHolidays}', '[{"id":"th-y","dept":"willow","name":"Y","kind":"nth","month":11,"coverage":{}}]'))$$, 'PT422', 'Invalid workspace data');
select t_save(t_st() - 'teamHolidays');
select t_assert(jsonb_array_length(t_st()->'teamHolidays') = 3, 'payload without teamHolidays keeps them');
-- import keeps a published rotation and records its publication
select t_login(:admin);
select t_save(jsonb_set(jsonb_set(t_st(), '{rotations,1,status}', '"Published"'), '{rotations,1,snapshot}', '[]'), 'import');
select t_assert((select status from rotations where id = 'r-boehm') = 'Published' and (select count(*) from publications where rotation_id = 'r-boehm') = 1, 'import keeps published rotation');
reset role;
-- operator removal of a whole workspace (see docs/OPERATIONS.md)
begin;
alter table audit_log disable trigger audit_log_append_only;
alter table publications disable trigger publications_append_only;
delete from workspaces where id = 'vm';
alter table audit_log enable trigger audit_log_append_only;
alter table publications enable trigger publications_append_only;
commit;
select t_assert(not exists (select 1 from assignments where workspace_id = 'vm') and not exists (select 1 from affiliations where workspace_id = 'vm')
  and exists (select 1 from workspaces where id = 'other'), 'deleting a workspace removes only its rows');
\echo 'All database tests passed.'
