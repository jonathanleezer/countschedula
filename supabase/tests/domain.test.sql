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
select t_assert(t_st()->'providers' = (:'sample'::jsonb)->'providers', 'providers round-trip exactly (ids, affiliations, numbers)');
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
