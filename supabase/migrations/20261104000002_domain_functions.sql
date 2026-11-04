-- CountSchedula shared backend: authoritative domain rules, state load/save, publication.
-- The rule functions mirror dist/app.js violations()/coverageMissing() so the server is the
-- final gate for every mutation path (forms, drag/drop, generation, undo, provider/rule/type edits,
-- PTO review, publish/reopen, restore/import).
--
-- Error codes (PostgREST maps PTxyz to HTTP xyz):
--   PT403 not allowed for this role   PT409 stale version   PT422 rejected by a rule / invalid data

-- ---------------------------------------------------------------- small helpers

create or replace function public.cs_num(n numeric) returns text
language sql immutable as $$ select trim_scale(n)::text $$;

create or replace function public.cs_iso(t timestamptz) returns text
language sql immutable as $$ select to_char(t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') $$;

-- Real start/end instants of a shift in the workspace time zone; end <= start rolls to next day.
create or replace function public.cs_interval(p_tz text, p_date date, p_start time, p_end time,
  out s timestamptz, out e timestamptz)
language plpgsql immutable as $$
begin
  s := (p_date + p_start) at time zone p_tz;
  e := (p_date + p_end) at time zone p_tz;
  if p_end <= p_start then e := ((p_date + 1) + p_end) at time zone p_tz; end if;
end $$;

-- ---------------------------------------------------------------- rules

-- Violations for one stored assignment, evaluated against everything stored in the workspace
-- (all organizations, including ones hidden in the UI).
create or replace function public.cs_violations(p_ws text, p_id text) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare
  w record; a record; p record; t record; b record;
  s timestamptz; e timestamptz; bs timestamptz; be timestamptz;
  errs text[] := '{}'; rest numeric; cons numeric; gap numeric; win int; n int; streak int; i int;
begin
  select * into w from workspaces where id = p_ws;
  select * into a from assignments where workspace_id = p_ws and id = p_id;
  if not found then return '{}'; end if;
  select * into p from providers where workspace_id = p_ws and id = a.provider_id;
  if not found then return array['Provider does not exist']; end if;
  if not exists (select 1 from affiliations where workspace_id = p_ws and provider_id = p.id and dept_id = a.dept_id) then
    errs := errs || 'Provider is not affiliated with this department'::text;
  end if;
  select * into t from shift_types where workspace_id = p_ws and id = a.shift_id;
  if not found then return array['Unknown shift type']; end if;
  if t.night and not p.nights then errs := errs || 'Provider is unavailable for nights'::text; end if;

  select x.s, x.e into s, e from cs_interval(w.timezone, a.date, t.start_time, t.end_time) x;

  if exists (select 1 from requests r where r.workspace_id = p_ws and r.provider_id = p.id and r.status = 'Approved'
             and s < ((r.end_date + 1)::timestamp at time zone w.timezone)
             and e > (r.start_date::timestamp at time zone w.timezone)) then
    errs := errs || 'Approved PTO overlaps this shift'::text;
  end if;

  rest := (w.rules->>'rest')::numeric;
  cons := (w.rules->>'consecutive')::numeric;
  win := ceil(rest / 24)::int + 2;   -- anything farther away cannot overlap or break rest
  for b in
    select x.id, x.date, x.dept_id, st.start_time, st.end_time
    from assignments x join shift_types st on st.workspace_id = x.workspace_id and st.id = x.shift_id
    where x.workspace_id = p_ws and x.provider_id = a.provider_id and x.id <> a.id
      and x.date between a.date - win and a.date + win
    order by x.date, x.sort, x.id
  loop
    select y.s, y.e into bs, be from cs_interval(w.timezone, b.date, b.start_time, b.end_time) y;
    if s < be and e > bs then
      errs := errs || ('Overlapping assignment · ' ||
        coalesce((select name from departments where workspace_id = p_ws and id = b.dept_id), b.dept_id));
    else
      gap := extract(epoch from (case when s >= be then s - be else bs - e end)) / 3600;
      if gap < rest then
        errs := errs || ('Minimum ' || cs_num(rest) || 'h rest not met · ' || to_char(b.date, 'YYYY-MM-DD'));
      end if;
    end if;
  end loop;

  select count(*) into n from assignments x
   where x.workspace_id = p_ws and x.provider_id = a.provider_id and x.id <> a.id
     and date_trunc('month', x.date) = date_trunc('month', a.date);
  if n >= p.max then errs := errs || ('Monthly maximum of ' || cs_num(p.max) || ' shifts exceeded'); end if;

  streak := 1; i := 1;
  while exists (select 1 from assignments x where x.workspace_id = p_ws and x.provider_id = a.provider_id
                and x.id <> a.id and x.date = a.date - i) loop streak := streak + 1; i := i + 1; end loop;
  i := 1;
  while exists (select 1 from assignments x where x.workspace_id = p_ws and x.provider_id = a.provider_id
                and x.id <> a.id and x.date = a.date + i) loop streak := streak + 1; i := i + 1; end loop;
  if streak > cons then errs := errs || ('Maximum ' || cs_num(cons) || ' consecutive workdays exceeded'); end if;

  return coalesce((select array_agg(v order by o) from (select v, min(o) o from unnest(errs) with ordinality u(v, o) group by v) d), '{}');
end $$;

create or replace function public.cs_coverage_missing(p_ws text, p_dept text, p_month text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(greatest(0, t.coverage - (
           select count(*) from assignments a
           where a.workspace_id = p_ws and a.dept_id = p_dept and a.date = d::date and a.shift_id = t.id))), 0)::int
  from generate_series(to_date(p_month, 'YYYY-MM'),
                       (to_date(p_month, 'YYYY-MM') + interval '1 month' - interval '1 day'),
                       interval '1 day') d
  cross join shift_types t
  where t.workspace_id = p_ws and t.active and t.coverage > 0
$$;

create or replace function public.cs_period_conflicts(p_ws text, p_dept text, p_month text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(cardinality(cs_violations(p_ws, a.id))), 0)::int from assignments a
  where a.workspace_id = p_ws and a.dept_id = p_dept and to_char(a.date, 'YYYY-MM') = p_month
$$;

-- Violations of every assignment in a published period, as 'id|error' strings.
create or replace function public.cs_published_violations(p_ws text) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(a.id || '|' || v), '{}') from assignments a
  join periods pe on pe.workspace_id = a.workspace_id and pe.dept_id = a.dept_id
                 and pe.month = to_char(a.date, 'YYYY-MM') and pe.status = 'Published'
  cross join lateral unnest(cs_violations(p_ws, a.id)) v
  where a.workspace_id = p_ws
$$;

-- ---------------------------------------------------------------- export (client state shape)

create or replace function public.cs_assignment_json(a public.assignments) returns jsonb
language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object('id', a.id, 'provider', a.provider_id, 'dept', a.dept_id,
    'date', to_char(a.date, 'YYYY-MM-DD'), 'shift', a.shift_id, 'note', a.note))
$$;

create or replace function public.cs_audit_json(p_ws text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('text', text, 'time', cs_iso(at), 'by', actor_email) order by id desc), '[]')
  from (select * from audit_log where workspace_id = p_ws order by id desc limit 300) x
$$;

create or replace function public.cs_export(p_ws text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'providers', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'role', p.role,
        'target', p.target, 'max', p.max, 'nights', p.nights,
        'affiliations', coalesce((select jsonb_agg(f.dept_id order by d.sort, f.dept_id) from affiliations f
                                  join departments d on d.workspace_id = f.workspace_id and d.id = f.dept_id
                                  where f.workspace_id = p.workspace_id and f.provider_id = p.id), '[]'))
        order by p.sort, p.id) from providers p where p.workspace_id = p_ws), '[]'),
    'shiftTypes', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name,
        'start', to_char(t.start_time, 'HH24:MI'), 'end', to_char(t.end_time, 'HH24:MI'), 'color', t.color,
        'coverage', t.coverage, 'night', t.night, 'active', t.active) order by t.sort, t.id)
        from shift_types t where t.workspace_id = p_ws), '[]'),
    'assignments', coalesce((select jsonb_agg(cs_assignment_json(a) order by a.sort, a.date, a.id)
        from assignments a where a.workspace_id = p_ws), '[]'),
    'requests', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', r.id, 'provider', r.provider_id,
        'start', to_char(r.start_date, 'YYYY-MM-DD'), 'end', to_char(r.end_date, 'YYYY-MM-DD'),
        'status', r.status, 'reason', r.reason)) order by r.sort, r.id) from requests r where r.workspace_id = p_ws), '[]'),
    'rules', (select rules from workspaces where id = p_ws),
    'periods', coalesce((select jsonb_object_agg(pe.dept_id || ':' || pe.month, jsonb_strip_nulls(jsonb_build_object(
        'status', pe.status, 'at', cs_iso(pe.published_at), 'snapshot', pe.snapshot)))
        from periods pe where pe.workspace_id = p_ws), '{}'),
    'audit', cs_audit_json(p_ws))
$$;

create or replace function public.get_state(p_ws text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r text; w record;
begin
  r := cs_role(p_ws);
  if r is null then raise exception 'You do not have access to this workspace.' using errcode = 'PT403'; end if;
  select * into w from workspaces where id = p_ws;
  return jsonb_build_object('version', w.version, 'role', r,
    'workspace', jsonb_build_object('id', w.id, 'name', w.name, 'timezone', w.timezone),
    'departments', (select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'org', org_name) order by sort, id)
                    from departments where workspace_id = p_ws),
    'state', cs_export(p_ws));
end $$;

create or replace function public.get_version(p_ws text) returns bigint
language sql stable security definer set search_path = public as $$
  select version from workspaces where id = p_ws and cs_is_member(p_ws)
$$;

-- Workspaces the caller belongs to (for choosing one after sign-in).
create or replace function public.my_workspaces() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'role', m.role) order by w.name), '[]')
  from members m join workspaces w on w.id = m.workspace_id where m.user_id = auth.uid()
$$;

-- ---------------------------------------------------------------- payload validation

create or replace function public.cs_fail(msg text) returns void language plpgsql as $$
begin raise exception '%', msg using errcode = 'PT422'; end $$;

create or replace function public.cs_check_payload(p_ws text, st jsonb) returns void
language plpgsql stable security definer set search_path = public as $$
declare x jsonb; k text; rest numeric; cons numeric;
begin
  if jsonb_typeof(st) <> 'object' then perform cs_fail('Invalid workspace data: expected an object.'); end if;
  if octet_length(st::text) > 20000000 then perform cs_fail('Invalid workspace data: payload is larger than 20 MB.'); end if;
  foreach k in array array['providers','assignments','requests','shiftTypes'] loop
    if jsonb_typeof(st->k) is distinct from 'array' then perform cs_fail('Invalid workspace data: ' || k || ' must be a list.'); end if;
  end loop;
  if jsonb_typeof(st->'rules') is distinct from 'object' or jsonb_typeof(st->'periods') is distinct from 'object' then
    perform cs_fail('Invalid workspace data: rules and periods are required.');
  end if;
  if jsonb_array_length(st->'providers') > 1000 or jsonb_array_length(st->'shiftTypes') > 50
     or jsonb_array_length(st->'assignments') > 100000 or jsonb_array_length(st->'requests') > 20000 then
    perform cs_fail('Invalid workspace data: too many records.');
  end if;
  if jsonb_array_length(st->'shiftTypes') = 0 or not exists (
       select 1 from jsonb_array_elements(st->'shiftTypes') t where t->'active' = 'true'::jsonb) then
    perform cs_fail('Keep at least one shift type active');
  end if;
  if jsonb_typeof(st->'rules'->'rest') <> 'number' or jsonb_typeof(st->'rules'->'consecutive') <> 'number' then
    perform cs_fail('Invalid workspace data: rules need numeric rest and consecutive values.');
  end if;
  rest := (st->'rules'->>'rest')::numeric; cons := (st->'rules'->>'consecutive')::numeric;
  if rest < 0 or rest > 72 or cons < 1 or cons > 14 then
    perform cs_fail('Rules out of range: rest must be 0–72 hours and consecutive workdays 1–14.');
  end if;
  for x in select * from jsonb_array_elements(st->'providers') loop
    if jsonb_typeof(x->'id') <> 'string' or jsonb_typeof(x->'name') <> 'string'
       or jsonb_typeof(x->'affiliations') is distinct from 'array' or jsonb_typeof(x->'target') <> 'number'
       or jsonb_typeof(x->'max') <> 'number' or jsonb_typeof(coalesce(x->'nights', 'true')) <> 'boolean' then
      perform cs_fail('Invalid provider record: ' || left(coalesce(x->>'name', x->>'id', '?'), 60));
    end if;
  end loop;
  for x in select * from jsonb_array_elements(st->'shiftTypes') loop
    if jsonb_typeof(x->'active') <> 'boolean' or jsonb_typeof(x->'night') <> 'boolean'
       or jsonb_typeof(x->'coverage') <> 'number' or (x->>'coverage')::numeric <> trunc((x->>'coverage')::numeric)
       or coalesce(x->>'start', '') !~ '^([01]\d|2[0-3]):[0-5]\d$' or coalesce(x->>'end', '') !~ '^([01]\d|2[0-3]):[0-5]\d$' then
      perform cs_fail('Check shift names, hours, color, and required coverage (0–10). Names must be unique and start/end times must differ.');
    end if;
  end loop;
  for x in select * from jsonb_array_elements(st->'assignments') loop
    if coalesce(x->>'date', '') !~ '^\d{4}-\d{2}-\d{2}$' or jsonb_typeof(x->'id') <> 'string' then
      perform cs_fail('Invalid assignment record: ' || left(coalesce(x->>'id', '?'), 64));
    end if;
  end loop;
  for x in select * from jsonb_array_elements(st->'requests') loop
    if coalesce(x->>'start', '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(x->>'end', '') !~ '^\d{4}-\d{2}-\d{2}$'
       or jsonb_typeof(x->'id') <> 'string' then
      perform cs_fail('Invalid time-off request record: ' || left(coalesce(x->>'id', '?'), 64));
    end if;
  end loop;
  for k in select jsonb_object_keys(st->'periods') loop
    if k !~ '^[A-Za-z0-9_-]{1,64}:\d{4}-(0[1-9]|1[0-2])$'
       or (st->'periods'->k->>'status') not in ('Draft', 'Published') or (st->'periods'->k->>'status') is null then
      perform cs_fail('Invalid schedule period: ' || left(k, 80));
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------- save

-- Replace the workspace's state with p_state after authoritative validation, in one transaction.
--   p_base_version  version the client loaded; mismatch => PT409 (someone else saved first)
--   p_notes         human-readable change descriptions recorded in the audit log
--   p_mode          'edit' (normal) or 'import' (admin restore/import/reset; see below)
-- In 'edit' mode every inserted/changed assignment must have zero violations, published periods
-- cannot be edited, publishing requires full coverage and zero conflicts, and configuration
-- changes may not introduce new conflicts into published schedules.
-- 'import' mode validates structure and referential integrity only, keeps existing conflicts
-- visible rather than rejecting them, and snapshots the prior state for rollback.
create or replace function public.save_state(p_ws text, p_base_version bigint, p_state jsonb,
  p_notes text[] default '{}', p_mode text default 'edit') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r text; w record; old jsonb; uid uuid := auth.uid(); email text;
  changed text[]; touched text[]; k text; v text[]; msg text; n_missing int; n_conf int;
  before_pub text[]; after_pub text[]; config_changed boolean; new_version bigint; x record; cnt jsonb;
begin
  r := cs_role(p_ws);
  if r is null then raise exception 'You do not have access to this workspace.' using errcode = 'PT403'; end if;
  if r = 'viewer' then raise exception 'Your role is read-only. Ask a workspace administrator for scheduler access.' using errcode = 'PT403'; end if;
  if p_mode not in ('edit', 'import') then perform cs_fail('Unknown save mode'); end if;
  if p_mode = 'import' and r <> 'admin' then raise exception 'Only administrators can restore or import a workspace.' using errcode = 'PT403'; end if;

  select * into w from workspaces where id = p_ws for update;
  if w.version <> p_base_version then
    raise exception 'Someone else saved changes to this workspace. The latest version has been loaded; please redo your last change.' using errcode = 'PT409';
  end if;
  select u.email into email from auth.users u where u.id = uid;

  perform cs_check_payload(p_ws, p_state);
  old := cs_export(p_ws);

  -- snapshots for rollback
  if p_mode = 'import' then
    insert into state_snapshots(workspace_id, created_by, reason, version, state) values (p_ws, uid, 'Before restore/import', w.version, old);
  elsif not exists (select 1 from state_snapshots where workspace_id = p_ws and created_at > now() - interval '24 hours') then
    insert into state_snapshots(workspace_id, created_by, reason, version, state) values (p_ws, uid, 'Daily automatic snapshot', w.version, old);
  end if;
  delete from state_snapshots where workspace_id = p_ws and created_at < now() - interval '45 days'
    and id not in (select id from state_snapshots where workspace_id = p_ws order by id desc limit 10);

  create temp table if not exists _na (id text, provider text, dept text, date date, shift text, note text, sort int) on commit drop;
  create temp table if not exists _np (id text, name text, role text, target numeric, max numeric, nights boolean, affiliations jsonb, sort int) on commit drop;
  create temp table if not exists _nt (id text, name text, start_time time, end_time time, color text, coverage int, night boolean, active boolean, sort int) on commit drop;
  create temp table if not exists _nr (id text, provider text, start_date date, end_date date, status text, reason text, sort int) on commit drop;
  create temp table if not exists _ne (dept text, month text, status text, at timestamptz, snapshot jsonb) on commit drop;
  truncate _na, _np, _nt, _nr, _ne;

  begin
    insert into _na select e->>'id', e->>'provider', e->>'dept', (e->>'date')::date, e->>'shift', nullif(e->>'note', ''), (o - 1)::int
      from jsonb_array_elements(p_state->'assignments') with ordinality j(e, o);
    insert into _np select e->>'id', btrim(e->>'name'), coalesce(e->>'role', ''), (e->>'target')::numeric, (e->>'max')::numeric,
      coalesce((e->>'nights')::boolean, true), e->'affiliations', (o - 1)::int
      from jsonb_array_elements(p_state->'providers') with ordinality j(e, o);
    insert into _nt select e->>'id', btrim(e->>'name'), (e->>'start')::time, (e->>'end')::time, e->>'color', (e->>'coverage')::int,
      (e->>'night')::boolean, (e->>'active')::boolean, (o - 1)::int
      from jsonb_array_elements(p_state->'shiftTypes') with ordinality j(e, o);
    insert into _nr select e->>'id', e->>'provider', (e->>'start')::date, (e->>'end')::date, e->>'status', nullif(e->>'reason', ''), (o - 1)::int
      from jsonb_array_elements(p_state->'requests') with ordinality j(e, o);
    insert into _ne select split_part(key, ':', 1), split_part(key, ':', 2), value->>'status',
      case when value->>'at' ~ '^\d{4}-' then (value->>'at')::timestamptz end, value->'snapshot'
      from jsonb_each(p_state->'periods');
  exception when invalid_datetime_format or datetime_field_overflow or invalid_text_representation
            or numeric_value_out_of_range then
    perform cs_fail('Invalid workspace data: ' || sqlerrm);
  end;

  if exists (select 1 from _na group by id having count(*) > 1) or exists (select 1 from _np group by id having count(*) > 1)
     or exists (select 1 from _nt group by id having count(*) > 1) or exists (select 1 from _nr group by id having count(*) > 1) then
    perform cs_fail('Invalid workspace data: duplicate record IDs.');
  end if;
  if exists (select 1 from _na where date < date '2000-01-01' or date > date '2100-12-31') then
    perform cs_fail('Invalid workspace data: assignment dates must be between 2000 and 2100.');
  end if;

  -- assignments whose scheduling-relevant fields are new or changed
  changed := array(select n.id from _na n left join assignments o on o.workspace_id = p_ws and o.id = n.id
    where o.id is null or (o.provider_id, o.dept_id, o.date, o.shift_id) is distinct from (n.provider, n.dept, n.date, n.shift));
  -- department-months touched by any assignment difference (including notes and removals)
  touched := array(
    select distinct dept || ':' || to_char(date, 'YYYY-MM') from (
      select n.dept, n.date from _na n left join assignments o on o.workspace_id = p_ws and o.id = n.id
        where o.id is null or (o.provider_id, o.dept_id, o.date, o.shift_id, o.note) is distinct from (n.provider, n.dept, n.date, n.shift, n.note)
      union all
      select o.dept_id, o.date from assignments o left join _na n on n.id = o.id
        where o.workspace_id = p_ws and (n.id is null or (o.provider_id, o.dept_id, o.date, o.shift_id, o.note) is distinct from (n.provider, n.dept, n.date, n.shift, n.note))
    ) d);

  config_changed := (old->'providers') is distinct from (p_state->'providers')
    or (old->'shiftTypes') is distinct from (p_state->'shiftTypes')
    or (old->'rules') is distinct from (p_state->'rules')
    or (old->'requests') is distinct from (p_state->'requests');

  if p_mode = 'edit' then
    -- published periods are locked (checked against both the stored and the submitted status)
    foreach k in array touched loop
      if exists (select 1 from periods where workspace_id = p_ws and dept_id || ':' || month = k and status = 'Published')
         or exists (select 1 from _ne where dept || ':' || month = k and status = 'Published') then
        perform cs_fail('The ' || coalesce((select name from departments where workspace_id = p_ws and id = split_part(k, ':', 1)), k)
          || ' schedule for ' || split_part(k, ':', 2) || ' is published. Reopen it as a draft to edit.');
      end if;
    end loop;
    -- shift-type edits that would rewrite published schedules
    if exists (select 1 from periods where workspace_id = p_ws and status = 'Published') and exists (
         select 1 from shift_types o full join _nt n on n.id = o.id and o.workspace_id = p_ws
         where (o.workspace_id = p_ws or o.workspace_id is null)
           and coalesce(case when o.active then o.coverage end, 0) is distinct from coalesce(case when n.active then n.coverage end, 0)) then
      perform cs_fail('Reopen affected published schedules before changing required coverage or assigned shift hours/category.');
    end if;
    if exists (select 1 from shift_types o join _nt n on n.id = o.id
               where o.workspace_id = p_ws and (o.start_time, o.end_time, o.night) is distinct from (n.start_time, n.end_time, n.night)
                 and exists (select 1 from assignments a join periods pe on pe.workspace_id = a.workspace_id and pe.dept_id = a.dept_id
                             and pe.month = to_char(a.date, 'YYYY-MM') and pe.status = 'Published'
                             where a.workspace_id = p_ws and a.shift_id = o.id)) then
      perform cs_fail('Reopen affected published schedules before changing required coverage or assigned shift hours/category.');
    end if;
    if config_changed then before_pub := cs_published_violations(p_ws); end if;
  end if;

  -- apply (constraint failures become readable PT422 errors and roll everything back)
  begin
    update workspaces set rules = p_state->'rules' where id = p_ws;
    delete from assignments a where a.workspace_id = p_ws and not exists (select 1 from _na n where n.id = a.id);
    delete from requests q where q.workspace_id = p_ws and not exists (select 1 from _nr n where n.id = q.id);
    insert into shift_types(workspace_id, id, name, start_time, end_time, color, coverage, night, active, sort)
      select p_ws, id, name, start_time, end_time, color, coverage, night, active, sort from _nt
      on conflict (workspace_id, id) do update set name = excluded.name, start_time = excluded.start_time, end_time = excluded.end_time,
        color = excluded.color, coverage = excluded.coverage, night = excluded.night, active = excluded.active, sort = excluded.sort;
    insert into providers(workspace_id, id, name, role, target, max, nights, sort)
      select p_ws, id, name, role, target, max, nights, sort from _np
      on conflict (workspace_id, id) do update set name = excluded.name, role = excluded.role, target = excluded.target,
        max = excluded.max, nights = excluded.nights, sort = excluded.sort;
    delete from affiliations where workspace_id = p_ws;
    insert into affiliations(workspace_id, provider_id, dept_id)
      select distinct p_ws, n.id, d from _np n cross join jsonb_array_elements_text(n.affiliations) d;
    insert into assignments(workspace_id, id, provider_id, dept_id, date, shift_id, note, sort)
      select p_ws, id, provider, dept, date, shift, note, sort from _na
      on conflict (workspace_id, id) do update set provider_id = excluded.provider_id, dept_id = excluded.dept_id,
        date = excluded.date, shift_id = excluded.shift_id, note = excluded.note, sort = excluded.sort;
    insert into requests(workspace_id, id, provider_id, start_date, end_date, status, reason, sort)
      select p_ws, id, provider, start_date, end_date, status, reason, sort from _nr
      on conflict (workspace_id, id) do update set provider_id = excluded.provider_id, start_date = excluded.start_date,
        end_date = excluded.end_date, status = excluded.status, reason = excluded.reason, sort = excluded.sort;
    delete from providers p where p.workspace_id = p_ws and not exists (select 1 from _np n where n.id = p.id);
    delete from shift_types t where t.workspace_id = p_ws and not exists (select 1 from _nt n where n.id = t.id);
  exception
    when foreign_key_violation then
      perform cs_fail('Invalid workspace data: a record refers to a provider, department, or shift type that does not exist (or one still in use was removed).');
    when check_violation or not_null_violation or unique_violation or string_data_right_truncation then
      perform cs_fail('Invalid workspace data: ' || sqlerrm);
  end;

  -- PTO approval is blocked while assignments overlap (mirrors reviewRequest)
  if p_mode = 'edit' then
    for x in select n.* from _nr n left join (select * from jsonb_to_recordset(old->'requests') as (id text, status text)) o on o.id = n.id
             where n.status = 'Approved' and o.status is distinct from 'Approved' loop
      select count(*) into n_conf from assignments a join shift_types t on t.workspace_id = a.workspace_id and t.id = a.shift_id
        cross join lateral cs_interval(w.timezone, a.date, t.start_time, t.end_time) iv
        where a.workspace_id = p_ws and a.provider_id = x.provider
          and iv.s < ((x.end_date + 1)::timestamp at time zone w.timezone) and iv.e > (x.start_date::timestamp at time zone w.timezone);
      if n_conf > 0 then
        perform cs_fail('Approval blocked: ' || n_conf || ' assignments overlap this PTO. Move or remove them first.');
      end if;
    end loop;

    -- every new or changed assignment must satisfy all hard rules, across all organizations
    foreach k in array changed loop
      v := cs_violations(p_ws, k);
      if cardinality(v) > 0 then
        select to_char(date, 'YYYY-MM-DD') || ' ' || coalesce((select name from shift_types t where t.workspace_id = p_ws and t.id = a.shift_id), a.shift_id)
          || ' · ' || coalesce((select name from providers p where p.workspace_id = p_ws and p.id = a.provider_id), a.provider_id)
          into msg from assignments a where a.workspace_id = p_ws and a.id = k;
        perform cs_fail('Blocked: ' || array_to_string(v, ' · ') || ' (' || msg || ')');
      end if;
    end loop;

    if config_changed then
      after_pub := cs_published_violations(p_ws);
      if exists (select unnest(after_pub) except select unnest(before_pub)) then
        perform cs_fail('This change would conflict with a published schedule. Reopen the affected schedule first.');
      end if;
    end if;
  end if;

  -- periods: publication / reopen
  for x in select n.*, o.status old_status, o.published_at old_at, o.snapshot old_snapshot
           from _ne n left join periods o on o.workspace_id = p_ws and o.dept_id = n.dept and o.month = n.month loop
    if not exists (select 1 from departments where workspace_id = p_ws and id = x.dept) then
      perform cs_fail('Invalid schedule period: unknown department ' || x.dept);
    end if;
    if x.status = 'Published' and x.old_status is distinct from 'Published' and p_mode = 'edit' then
      n_missing := cs_coverage_missing(p_ws, x.dept, x.month);
      n_conf := cs_period_conflicts(p_ws, x.dept, x.month);
      if n_missing > 0 or n_conf > 0 then
        perform cs_fail('Cannot publish ' || x.month || ': ' || n_missing || ' open shifts · ' || n_conf || ' rule conflicts.');
      end if;
      insert into periods(workspace_id, dept_id, month, status, published_at, snapshot)
        values (p_ws, x.dept, x.month, 'Published', now(),
          (select coalesce(jsonb_agg(cs_assignment_json(a) order by a.sort, a.date, a.id), '[]') from assignments a
           where a.workspace_id = p_ws and a.dept_id = x.dept and to_char(a.date, 'YYYY-MM') = x.month))
        on conflict (workspace_id, dept_id, month) do update set status = excluded.status, published_at = excluded.published_at, snapshot = excluded.snapshot;
      insert into publications(workspace_id, dept_id, month, published_by, snapshot)
        select p_ws, x.dept, x.month, uid, snapshot from periods where workspace_id = p_ws and dept_id = x.dept and month = x.month;
    elsif p_mode = 'import' then
      insert into periods(workspace_id, dept_id, month, status, published_at, snapshot)
        values (p_ws, x.dept, x.month, x.status, x.at, x.snapshot)
        on conflict (workspace_id, dept_id, month) do update set status = excluded.status, published_at = excluded.published_at, snapshot = excluded.snapshot;
      if x.status = 'Published' and x.snapshot is not null and not exists (
           select 1 from publications where workspace_id = p_ws and dept_id = x.dept and month = x.month and snapshot = x.snapshot) then
        insert into publications(workspace_id, dept_id, month, published_at, published_by, snapshot)
          values (p_ws, x.dept, x.month, coalesce(x.at, now()), uid, x.snapshot);
      end if;
    else
      -- status kept or reopened; the server's own publication time and snapshot are retained
      insert into periods(workspace_id, dept_id, month, status, published_at, snapshot)
        values (p_ws, x.dept, x.month, x.status, x.old_at, x.old_snapshot)
        on conflict (workspace_id, dept_id, month) do update set status = excluded.status;
    end if;
  end loop;
  -- periods absent from the submitted state: drafts are removed; in edit mode (e.g. undoing a first
  -- publish) a published period is reopened rather than deleted, keeping its publication history.
  delete from periods pe where pe.workspace_id = p_ws and not exists (select 1 from _ne n where n.dept = pe.dept_id and n.month = pe.month)
    and (p_mode = 'import' or pe.status = 'Draft');
  update periods pe set status = 'Draft' where pe.workspace_id = p_ws and pe.status = 'Published'
    and not exists (select 1 from _ne n where n.dept = pe.dept_id and n.month = pe.month);

  -- audit
  cnt := jsonb_build_object('mode', p_mode, 'version', w.version + 1,
    'assignmentsChanged', cardinality(changed),
    'assignmentsRemoved', (select count(*) from jsonb_to_recordset(old->'assignments') as o(id text) where not exists (select 1 from _na n where n.id = o.id)));
  if p_mode = 'import' then
    insert into audit_log(workspace_id, at, actor, actor_email, kind, text)
      select p_ws, (e->>'time')::timestamptz, null, null, 'imported', left(e->>'text', 500)
      from jsonb_array_elements(case when jsonb_typeof(p_state->'audit') = 'array' then p_state->'audit' else '[]' end) with ordinality j(e, o)
      where jsonb_typeof(e->'text') = 'string' and e->>'time' ~ '^\d{4}-\d{2}-\d{2}T'
        and not exists (select 1 from audit_log l where l.workspace_id = p_ws and l.text = left(e->>'text', 500) and l.at = (e->>'time')::timestamptz)
      order by o desc
      limit 1000;
  end if;
  if coalesce(cardinality(p_notes), 0) = 0 then
    insert into audit_log(workspace_id, actor, actor_email, kind, text, detail) values (p_ws, uid, email, 'save', 'Saved workspace changes', cnt);
  else
    insert into audit_log(workspace_id, actor, actor_email, kind, text, detail)
      select p_ws, uid, email, case when p_mode = 'import' then 'import' else 'change' end, left(t, 500), case when o = 1 then cnt end
      from unnest(p_notes[1:50]) with ordinality u(t, o) order by o;
  end if;

  update workspaces set version = version + 1 where id = p_ws returning version into new_version;
  return jsonb_build_object('version', new_version, 'audit', cs_audit_json(p_ws), 'periods', cs_export(p_ws)->'periods');
end $$;

-- ---------------------------------------------------------------- snapshots / history

create or replace function public.list_snapshots(p_ws text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'at', cs_iso(s.created_at), 'reason', s.reason, 'version', s.version,
           'by', (select email from auth.users u where u.id = s.created_by)) order by s.id desc)
         from state_snapshots s where s.workspace_id = p_ws), '[]');
end $$;

create or replace function public.get_snapshot(p_ws text, p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  return (select state from state_snapshots where workspace_id = p_ws and id = p_id);
end $$;

create or replace function public.list_publications(p_ws text, p_dept text, p_month text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not cs_is_member(p_ws) then raise exception 'You do not have access to this workspace.' using errcode = 'PT403'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'at', cs_iso(p.published_at),
           'by', (select email from auth.users u where u.id = p.published_by), 'assignments', jsonb_array_length(p.snapshot)) order by p.id desc)
         from publications p where p.workspace_id = p_ws and p.dept_id = p_dept and p.month = p_month), '[]');
end $$;
