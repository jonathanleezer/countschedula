-- CountSchedula: rotations (per-team scheduling periods), rotation holidays, holiday history,
-- per-rotation workload limits. Mirrors dist/app.js (rotationFor, required, violations, publish).
-- Rotations replace calendar months as the unit that is generated, published and locked.
-- Legacy month periods remain valid and keep locking their dates.

create extension if not exists btree_gist;

-- ---------------------------------------------------------------- schema

alter table public.providers add column rotation_target numeric, add column rotation_max numeric;
update public.providers set rotation_target = target * 2, rotation_max = max * 2;   -- one-time conversion (8-week ≈ 2 months)
alter table public.providers alter column rotation_target set not null, alter column rotation_max set not null,
  add constraint providers_rotation_limits check (rotation_target >= 0 and rotation_max >= 1 and rotation_target <= rotation_max);

alter table public.workspaces add column rotation_defaults jsonb not null default '{}'::jsonb;

create table public.rotations (
  workspace_id text not null references public.workspaces(id) on delete cascade,
  id           text not null check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  dept_id      text not null,
  name         text not null check (length(btrim(name)) between 1 and 60),
  start_date   date not null,
  end_date     date not null,
  status       text not null default 'Draft' check (status in ('Draft','Published')),
  published_at timestamptz,
  snapshot     jsonb,
  sort         int not null default 0,
  primary key (workspace_id, id),
  foreign key (workspace_id, dept_id) references public.departments(workspace_id, id),
  check (end_date >= start_date and end_date - start_date <= 366),
  constraint rotations_no_overlap exclude using gist
    (workspace_id with =, dept_id with =, daterange(start_date, end_date, '[]') with &&) deferrable initially immediate
);

create table public.rotation_holidays (
  workspace_id text not null references public.workspaces(id) on delete cascade,
  rotation_id  text not null,
  id           text not null check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  name         text not null check (length(btrim(name)) between 1 and 60),
  date         date not null,
  coverage     jsonb not null default '{}'::jsonb check (jsonb_typeof(coverage) = 'object'),
  sort         int not null default 0,
  primary key (workspace_id, rotation_id, id),
  unique (workspace_id, rotation_id, date),
  foreign key (workspace_id, rotation_id) references public.rotations(workspace_id, id) on delete cascade
);
create index rotation_holidays_date_idx on public.rotation_holidays(workspace_id, date);

-- Who covered which holiday in years before CountSchedula (for year-over-year holiday rotation).
create table public.holiday_history (
  workspace_id text not null references public.workspaces(id) on delete cascade,
  id           text not null check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  provider_id  text not null,
  holiday      text not null check (length(btrim(holiday)) between 1 and 60),
  year         int  not null check (year between 1990 and 2100),
  sort         int  not null default 0,
  primary key (workspace_id, id),
  foreign key (workspace_id, provider_id) references public.providers(workspace_id, id) on delete cascade
);

alter table public.publications alter column month drop not null, add column rotation_id text;

alter table public.rotations         enable row level security;
alter table public.rotation_holidays enable row level security;
alter table public.holiday_history   enable row level security;
create policy rot_read on public.rotations         for select to authenticated using (public.cs_is_member(workspace_id));
create policy hol_read on public.rotation_holidays for select to authenticated using (public.cs_is_member(workspace_id));
create policy hh_read  on public.holiday_history   for select to authenticated using (public.cs_is_member(workspace_id));
revoke all on public.rotations, public.rotation_holidays, public.holiday_history from anon, authenticated;
grant select on public.rotations, public.rotation_holidays, public.holiday_history to authenticated;

-- ---------------------------------------------------------------- rule helpers

-- Dates are locked by a published legacy month period or a published rotation of that team.
create or replace function public.cs_is_locked(p_ws text, p_dept text, p_day date) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from periods where workspace_id = p_ws and dept_id = p_dept and month = to_char(p_day, 'YYYY-MM') and status = 'Published')
      or exists (select 1 from rotations where workspace_id = p_ws and dept_id = p_dept and status = 'Published' and p_day between start_date and end_date)
$$;

-- Required providers for a shift type on a day: a holiday override in that team's rotation, else daily coverage.
create or replace function public.cs_required(p_ws text, p_dept text, p_day date, p_shift text, p_coverage int, p_active boolean) returns int
language sql stable security definer set search_path = public as $$
  select case when not p_active then 0 else coalesce((
    select (h.coverage->>p_shift)::int from rotation_holidays h
    join rotations r on r.workspace_id = h.workspace_id and r.id = h.rotation_id
    where r.workspace_id = p_ws and r.dept_id = p_dept and h.date = p_day and p_day between r.start_date and r.end_date
      and jsonb_typeof(h.coverage->p_shift) = 'number' limit 1), p_coverage) end
$$;

create or replace function public.cs_coverage_missing_range(p_ws text, p_dept text, p_start date, p_end date) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(greatest(0, cs_required(p_ws, p_dept, d::date, t.id, t.coverage, t.active) - (
           select count(*) from assignments a
           where a.workspace_id = p_ws and a.dept_id = p_dept and a.date = d::date and a.shift_id = t.id))), 0)::int
  from generate_series(p_start, p_end, interval '1 day') d
  cross join shift_types t
  where t.workspace_id = p_ws and t.active
$$;

create or replace function public.cs_coverage_missing(p_ws text, p_dept text, p_month text) returns int
language sql stable security definer set search_path = public as $$
  select cs_coverage_missing_range(p_ws, p_dept, to_date(p_month, 'YYYY-MM'), (to_date(p_month, 'YYYY-MM') + interval '1 month' - interval '1 day')::date)
$$;

create or replace function public.cs_range_conflicts(p_ws text, p_dept text, p_start date, p_end date) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(cardinality(cs_violations(p_ws, a.id))), 0)::int from assignments a
  where a.workspace_id = p_ws and a.dept_id = p_dept and a.date between p_start and p_end
$$;

create or replace function public.cs_published_violations(p_ws text) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(a.id || '|' || v), '{}') from assignments a
  cross join lateral unnest(cs_violations(p_ws, a.id)) v
  where a.workspace_id = p_ws and cs_is_locked(p_ws, a.dept_id, a.date)
$$;

-- Same as before except the workload maximum: inside a rotation of the assignment's team, count the
-- provider's shifts (all teams) during that rotation against rotation_max; outside, the calendar month.
create or replace function public.cs_violations(p_ws text, p_id text) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare
  w record; a record; p record; t record; b record; rot record;
  s timestamptz; e timestamptz; bs timestamptz; be timestamptz;
  errs text[] := '{}'; rest numeric; cons numeric; gap numeric; win int; n int; streak int; i int; mx numeric;
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
  win := ceil(rest / 24)::int + 2;
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

  select * into rot from rotations r where r.workspace_id = p_ws and r.dept_id = a.dept_id and a.date between r.start_date and r.end_date limit 1;
  if found then
    select count(*) into n from assignments x
     where x.workspace_id = p_ws and x.provider_id = a.provider_id and x.id <> a.id and x.date between rot.start_date and rot.end_date;
    mx := p.rotation_max;
    if n >= mx then errs := errs || ('Rotation maximum of ' || cs_num(mx) || ' shifts exceeded · ' || rot.name); end if;
  else
    select count(*) into n from assignments x
     where x.workspace_id = p_ws and x.provider_id = a.provider_id and x.id <> a.id
       and date_trunc('month', x.date) = date_trunc('month', a.date);
    if n >= p.max then errs := errs || ('Monthly maximum of ' || cs_num(p.max) || ' shifts exceeded'); end if;
  end if;

  streak := 1; i := 1;
  while exists (select 1 from assignments x where x.workspace_id = p_ws and x.provider_id = a.provider_id
                and x.id <> a.id and x.date = a.date - i) loop streak := streak + 1; i := i + 1; end loop;
  i := 1;
  while exists (select 1 from assignments x where x.workspace_id = p_ws and x.provider_id = a.provider_id
                and x.id <> a.id and x.date = a.date + i) loop streak := streak + 1; i := i + 1; end loop;
  if streak > cons then errs := errs || ('Maximum ' || cs_num(cons) || ' consecutive workdays exceeded'); end if;

  return coalesce((select array_agg(v order by o) from (select v, min(o) o from unnest(errs) with ordinality u(v, o) group by v) d), '{}');
end $$;

-- ---------------------------------------------------------------- export

create or replace function public.cs_export(p_ws text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'providers', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'role', p.role,
        'target', p.target, 'max', p.max, 'rotationTarget', p.rotation_target, 'rotationMax', p.rotation_max, 'nights', p.nights,
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
    'rotations', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', r.id, 'dept', r.dept_id, 'name', r.name,
        'start', to_char(r.start_date, 'YYYY-MM-DD'), 'end', to_char(r.end_date, 'YYYY-MM-DD'), 'status', r.status,
        'at', cs_iso(r.published_at), 'snapshot', r.snapshot)) || jsonb_build_object('holidays',
          coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'date', to_char(h.date, 'YYYY-MM-DD'), 'coverage', h.coverage) order by h.sort, h.date)
                    from rotation_holidays h where h.workspace_id = r.workspace_id and h.rotation_id = r.id), '[]'))
        order by r.sort, r.start_date, r.id) from rotations r where r.workspace_id = p_ws), '[]'),
    'rotationDefaults', (select rotation_defaults from workspaces where id = p_ws),
    'holidayHistory', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'provider', x.provider_id, 'holiday', x.holiday, 'year', x.year)
        order by x.sort, x.id) from holiday_history x where x.workspace_id = p_ws), '[]'),
    'audit', cs_audit_json(p_ws))
$$;

-- ---------------------------------------------------------------- payload validation (additions)

create or replace function public.cs_check_rotation_payload(p_ws text, st jsonb) returns void
language plpgsql stable security definer set search_path = public as $$
declare x jsonb; h jsonb; k text; v jsonb;
begin
  if st ? 'rotations' then
    if jsonb_typeof(st->'rotations') <> 'array' or jsonb_array_length(st->'rotations') > 2000 then perform cs_fail('Invalid workspace data: rotations must be a list.'); end if;
    for x in select * from jsonb_array_elements(st->'rotations') loop
      if jsonb_typeof(x) <> 'object' or jsonb_typeof(x->'id') <> 'string' or jsonb_typeof(x->'name') <> 'string' or jsonb_typeof(x->'dept') <> 'string'
         or coalesce(x->>'start', '') !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(x->>'end', '') !~ '^\d{4}-\d{2}-\d{2}$'
         or coalesce(x->>'status', '') not in ('Draft', 'Published')
         or jsonb_typeof(coalesce(x->'holidays', '[]')) <> 'array' or jsonb_array_length(coalesce(x->'holidays', '[]')) > 60 then
        perform cs_fail('Invalid rotation: ' || left(coalesce(x->>'name', x->>'id', '?'), 60));
      end if;
      for h in select * from jsonb_array_elements(coalesce(x->'holidays', '[]')) loop
        if jsonb_typeof(h) <> 'object' or jsonb_typeof(h->'id') <> 'string' or jsonb_typeof(h->'name') <> 'string'
           or coalesce(h->>'date', '') !~ '^\d{4}-\d{2}-\d{2}$' or jsonb_typeof(coalesce(h->'coverage', '{}')) <> 'object' then
          perform cs_fail('Invalid holiday in ' || left(x->>'name', 60));
        end if;
        for k, v in select * from jsonb_each(coalesce(h->'coverage', '{}')) loop
          if k !~ '^[a-z0-9-]{1,64}$' or jsonb_typeof(v) <> 'number' or v::text::numeric <> trunc(v::text::numeric) or v::text::numeric < 0 or v::text::numeric > 10 then
            perform cs_fail(x->>'name' || ': holiday coverage must be whole numbers from 0 to 10');
          end if;
        end loop;
      end loop;
    end loop;
  end if;
  if st ? 'rotationDefaults' then
    if jsonb_typeof(st->'rotationDefaults') <> 'object' then perform cs_fail('Invalid rotation defaults.'); end if;
    for k, v in select * from jsonb_each(st->'rotationDefaults') loop
      if not exists (select 1 from departments where workspace_id = p_ws and id = k) or jsonb_typeof(v) <> 'object'
         or jsonb_typeof(v->'length') <> 'number' or (v->>'length')::numeric <> trunc((v->>'length')::numeric)
         or (v->>'length')::numeric < 1 or (v->>'length')::numeric > 366 or coalesce(v->>'unit', '') not in ('days', 'weeks', 'months')
         or (coalesce(v->>'start', '') <> '' and v->>'start' !~ '^\d{4}-\d{2}-\d{2}$') then
        perform cs_fail('Rotation length must be 1–366 days, weeks, or months.');
      end if;
      if coalesce(v->>'start', '') <> '' then perform (v->>'start')::date; end if;
    end loop;
  end if;
  if st ? 'holidayHistory' then
    if jsonb_typeof(st->'holidayHistory') <> 'array' or jsonb_array_length(st->'holidayHistory') > 5000 then perform cs_fail('Invalid holiday history.'); end if;
    for x in select * from jsonb_array_elements(st->'holidayHistory') loop
      if jsonb_typeof(x) <> 'object' or jsonb_typeof(x->'id') <> 'string' or jsonb_typeof(x->'provider') <> 'string'
         or jsonb_typeof(x->'holiday') <> 'string' or jsonb_typeof(x->'year') <> 'number' or (x->>'year')::numeric <> trunc((x->>'year')::numeric) then
        perform cs_fail('Invalid holiday history entry.');
      end if;
    end loop;
  end if;
  for x in select * from jsonb_array_elements(st->'providers') loop
    if (x ? 'rotationTarget' and jsonb_typeof(x->'rotationTarget') <> 'number') or (x ? 'rotationMax' and jsonb_typeof(x->'rotationMax') <> 'number') then
      perform cs_fail('Invalid provider record: ' || left(coalesce(x->>'name', x->>'id', '?'), 60));
    end if;
  end loop;
exception when invalid_datetime_format or datetime_field_overflow then
  perform cs_fail('Invalid workspace data: ' || sqlerrm);
end $$;

-- ---------------------------------------------------------------- save (rotation-aware)
-- Differences from the previous version:
--  * rotations, rotation holidays, rotation defaults and holiday history are saved; payloads that omit
--    these keys (older clients) leave them unchanged;
--  * provider rotation limits are saved (derived from monthly ×2 when omitted for a new provider);
--  * locks consider published rotations as well as legacy months;
--  * published rotations cannot be deleted or have their dates/holidays changed until reopened;
--  * publishing a rotation re-checks coverage (with holiday overrides) and conflicts over its dates,
--    stores a server-built snapshot, and appends to publications.
create or replace function public.save_state(p_ws text, p_base_version bigint, p_state jsonb,
  p_notes text[] default '{}', p_mode text default 'edit') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r text; w record; old jsonb; uid uuid := auth.uid(); email text;
  changed text[]; v text[]; msg text; n_missing int; n_conf int;
  before_pub text[]; after_pub text[]; config_changed boolean; new_version bigint; x record; cnt jsonb;
  has_rot boolean := p_state ? 'rotations'; has_rd boolean := p_state ? 'rotationDefaults'; has_hh boolean := p_state ? 'holidayHistory';
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
  perform cs_check_rotation_payload(p_ws, p_state);
  old := cs_export(p_ws);

  if p_mode = 'import' then
    insert into state_snapshots(workspace_id, created_by, reason, version, state) values (p_ws, uid, 'Before restore/import', w.version, old);
  elsif not exists (select 1 from state_snapshots where workspace_id = p_ws and created_at > now() - interval '24 hours') then
    insert into state_snapshots(workspace_id, created_by, reason, version, state) values (p_ws, uid, 'Daily automatic snapshot', w.version, old);
  end if;
  delete from state_snapshots where workspace_id = p_ws and created_at < now() - interval '45 days'
    and id not in (select id from state_snapshots where workspace_id = p_ws order by id desc limit 10);

  create temp table if not exists _na (id text, provider text, dept text, date date, shift text, note text, sort int) on commit drop;
  create temp table if not exists _np (id text, name text, role text, target numeric, max numeric, rotation_target numeric, rotation_max numeric, nights boolean, affiliations jsonb, sort int) on commit drop;
  create temp table if not exists _nt (id text, name text, start_time time, end_time time, color text, coverage int, night boolean, active boolean, sort int) on commit drop;
  create temp table if not exists _nr (id text, provider text, start_date date, end_date date, status text, reason text, sort int) on commit drop;
  create temp table if not exists _ne (dept text, month text, status text, at timestamptz, snapshot jsonb) on commit drop;
  create temp table if not exists _nrot (id text, dept text, name text, start_date date, end_date date, status text, at timestamptz, snapshot jsonb, holidays jsonb, sort int) on commit drop;
  create temp table if not exists _nhol (rotation_id text, id text, name text, date date, coverage jsonb, sort int) on commit drop;
  create temp table if not exists _nhh (id text, provider text, holiday text, year int, sort int) on commit drop;
  create temp table if not exists _touched (dept text, date date) on commit drop;
  truncate _na, _np, _nt, _nr, _ne, _nrot, _nhol, _nhh, _touched;

  begin
    insert into _na select e->>'id', e->>'provider', e->>'dept', (e->>'date')::date, e->>'shift', nullif(e->>'note', ''), (o - 1)::int
      from jsonb_array_elements(p_state->'assignments') with ordinality j(e, o);
    insert into _np select e->>'id', btrim(e->>'name'), coalesce(e->>'role', ''), (e->>'target')::numeric, (e->>'max')::numeric,
      coalesce((e->>'rotationTarget')::numeric, op.rotation_target, (e->>'target')::numeric * 2),
      coalesce((e->>'rotationMax')::numeric, op.rotation_max, (e->>'max')::numeric * 2),
      coalesce((e->>'nights')::boolean, true), e->'affiliations', (o - 1)::int
      from jsonb_array_elements(p_state->'providers') with ordinality j(e, o)
      left join providers op on op.workspace_id = p_ws and op.id = e->>'id';
    insert into _nt select e->>'id', btrim(e->>'name'), (e->>'start')::time, (e->>'end')::time, e->>'color', (e->>'coverage')::int,
      (e->>'night')::boolean, (e->>'active')::boolean, (o - 1)::int
      from jsonb_array_elements(p_state->'shiftTypes') with ordinality j(e, o);
    insert into _nr select e->>'id', e->>'provider', (e->>'start')::date, (e->>'end')::date, e->>'status', nullif(e->>'reason', ''), (o - 1)::int
      from jsonb_array_elements(p_state->'requests') with ordinality j(e, o);
    insert into _ne select split_part(key, ':', 1), split_part(key, ':', 2), value->>'status',
      case when value->>'at' ~ '^\d{4}-' then (value->>'at')::timestamptz end, value->'snapshot'
      from jsonb_each(p_state->'periods');
    if has_rot then
      insert into _nrot select e->>'id', e->>'dept', btrim(e->>'name'), (e->>'start')::date, (e->>'end')::date, e->>'status',
        case when e->>'at' ~ '^\d{4}-' then (e->>'at')::timestamptz end, e->'snapshot', coalesce(e->'holidays', '[]'), (o - 1)::int
        from jsonb_array_elements(p_state->'rotations') with ordinality j(e, o);
    else
      insert into _nrot select r2.id, r2.dept_id, r2.name, r2.start_date, r2.end_date, r2.status, r2.published_at, r2.snapshot,
        coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'date', h.date, 'coverage', h.coverage) order by h.sort)
                  from rotation_holidays h where h.workspace_id = p_ws and h.rotation_id = r2.id), '[]'), r2.sort
        from rotations r2 where r2.workspace_id = p_ws;
    end if;
    insert into _nhol select n.id, h->>'id', btrim(h->>'name'), (h->>'date')::date, coalesce(h->'coverage', '{}'), (o - 1)::int
      from _nrot n cross join jsonb_array_elements(n.holidays) with ordinality j(h, o);
    if has_hh then
      insert into _nhh select e->>'id', e->>'provider', btrim(e->>'holiday'), (e->>'year')::int, (o - 1)::int
        from jsonb_array_elements(p_state->'holidayHistory') with ordinality j(e, o);
    end if;
  exception when invalid_datetime_format or datetime_field_overflow or invalid_text_representation
            or numeric_value_out_of_range then
    perform cs_fail('Invalid workspace data: ' || sqlerrm);
  end;

  if exists (select 1 from _na group by id having count(*) > 1) or exists (select 1 from _np group by id having count(*) > 1)
     or exists (select 1 from _nt group by id having count(*) > 1) or exists (select 1 from _nr group by id having count(*) > 1)
     or exists (select 1 from _nrot group by id having count(*) > 1) or exists (select 1 from _nhol group by rotation_id, id having count(*) > 1)
     or exists (select 1 from _nhh group by id having count(*) > 1) then
    perform cs_fail('Invalid workspace data: duplicate record IDs.');
  end if;
  if exists (select 1 from _na where date < date '2000-01-01' or date > date '2100-12-31') then
    perform cs_fail('Invalid workspace data: assignment dates must be between 2000 and 2100.');
  end if;
  if exists (select 1 from _nhol h join _nrot n on n.id = h.rotation_id where h.date not between n.start_date and n.end_date) then
    perform cs_fail((select n.name || ': ' || h.name || ' must fall within the rotation dates' from _nhol h join _nrot n on n.id = h.rotation_id
                     where h.date not between n.start_date and n.end_date limit 1));
  end if;

  changed := array(select n.id from _na n left join assignments o on o.workspace_id = p_ws and o.id = n.id
    where o.id is null or (o.provider_id, o.dept_id, o.date, o.shift_id) is distinct from (n.provider, n.dept, n.date, n.shift));
  insert into _touched select distinct dept, date from (
      select n.dept, n.date from _na n left join assignments o on o.workspace_id = p_ws and o.id = n.id
        where o.id is null or (o.provider_id, o.dept_id, o.date, o.shift_id, o.note) is distinct from (n.provider, n.dept, n.date, n.shift, n.note)
      union all
      select o.dept_id, o.date from assignments o left join _na n on n.id = o.id
        where o.workspace_id = p_ws and (n.id is null or (o.provider_id, o.dept_id, o.date, o.shift_id, o.note) is distinct from (n.provider, n.dept, n.date, n.shift, n.note))
    ) d;

  config_changed := (old->'providers') is distinct from (p_state->'providers')
    or (old->'shiftTypes') is distinct from (p_state->'shiftTypes')
    or (old->'rules') is distinct from (p_state->'rules')
    or (old->'requests') is distinct from (p_state->'requests')
    or (has_rot and (old->'rotations') is distinct from (p_state->'rotations'));

  if p_mode = 'edit' then
    -- published schedules (legacy months and rotations, stored or submitted) are locked
    select t.dept, t.date into x from _touched t
      where cs_is_locked(p_ws, t.dept, t.date)
         or exists (select 1 from _ne where dept = t.dept and month = to_char(t.date, 'YYYY-MM') and status = 'Published')
         or exists (select 1 from _nrot where dept = t.dept and status = 'Published' and t.date between start_date and end_date)
      limit 1;
    if found then
      perform cs_fail('The ' || coalesce((select name from departments where workspace_id = p_ws and id = x.dept), x.dept) || ' schedule for '
        || coalesce((select name from rotations where workspace_id = p_ws and dept_id = x.dept and x.date between start_date and end_date limit 1),
                    (select name from _nrot where dept = x.dept and x.date between start_date and end_date limit 1),
                    to_char(x.date, 'YYYY-MM'))
        || ' is published. Reopen it as a draft to edit.');
    end if;
    -- published rotations keep their dates and holidays until reopened
    for x in select o.* , n.id new_id, n.status new_status, n.start_date new_start, n.end_date new_end, n.dept new_dept
             from rotations o left join _nrot n on n.id = o.id where o.workspace_id = p_ws and o.status = 'Published' loop
      if x.new_id is null then perform cs_fail('Reopen ' || x.name || ' before deleting it.'); end if;
      if x.new_status = 'Published' and ((x.start_date, x.end_date, x.dept_id) is distinct from (x.new_start, x.new_end, x.new_dept)
         or coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'date', h.date, 'coverage', h.coverage) order by h.id)
                      from rotation_holidays h where h.workspace_id = p_ws and h.rotation_id = x.id), '[]')
            is distinct from coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'date', h.date, 'coverage', h.coverage) order by h.id)
                      from _nhol h where h.rotation_id = x.id), '[]')) then
        perform cs_fail('Reopen ' || x.name || ' before changing its dates or holidays.');
      end if;
    end loop;
    -- shift-type edits that would rewrite published schedules
    if (exists (select 1 from periods where workspace_id = p_ws and status = 'Published') or exists (select 1 from rotations where workspace_id = p_ws and status = 'Published'))
       and exists (
         select 1 from shift_types o full join _nt n on n.id = o.id and o.workspace_id = p_ws
         where (o.workspace_id = p_ws or o.workspace_id is null)
           and coalesce(case when o.active then o.coverage end, 0) is distinct from coalesce(case when n.active then n.coverage end, 0)) then
      perform cs_fail('Reopen affected published schedules before changing required coverage or assigned shift hours/category.');
    end if;
    if exists (select 1 from shift_types o join _nt n on n.id = o.id
               where o.workspace_id = p_ws and (o.start_time, o.end_time, o.night) is distinct from (n.start_time, n.end_time, n.night)
                 and exists (select 1 from assignments a where a.workspace_id = p_ws and a.shift_id = o.id and cs_is_locked(p_ws, a.dept_id, a.date))) then
      perform cs_fail('Reopen affected published schedules before changing required coverage or assigned shift hours/category.');
    end if;
    if config_changed then before_pub := cs_published_violations(p_ws); end if;
  end if;

  begin
    update workspaces set rules = p_state->'rules',
      rotation_defaults = case when has_rd then p_state->'rotationDefaults' else rotation_defaults end where id = p_ws;
    delete from assignments a where a.workspace_id = p_ws and not exists (select 1 from _na n where n.id = a.id);
    delete from requests q where q.workspace_id = p_ws and not exists (select 1 from _nr n where n.id = q.id);
    insert into shift_types(workspace_id, id, name, start_time, end_time, color, coverage, night, active, sort)
      select p_ws, id, name, start_time, end_time, color, coverage, night, active, sort from _nt
      on conflict (workspace_id, id) do update set name = excluded.name, start_time = excluded.start_time, end_time = excluded.end_time,
        color = excluded.color, coverage = excluded.coverage, night = excluded.night, active = excluded.active, sort = excluded.sort;
    insert into providers(workspace_id, id, name, role, target, max, rotation_target, rotation_max, nights, sort)
      select p_ws, id, name, role, target, max, rotation_target, rotation_max, nights, sort from _np
      on conflict (workspace_id, id) do update set name = excluded.name, role = excluded.role, target = excluded.target,
        max = excluded.max, rotation_target = excluded.rotation_target, rotation_max = excluded.rotation_max, nights = excluded.nights, sort = excluded.sort;
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
    -- rotations: dates/names now; status and publication handled below
    set constraints public.rotations_no_overlap deferred;
    delete from rotations ro where ro.workspace_id = p_ws and not exists (select 1 from _nrot n where n.id = ro.id);
    insert into rotations(workspace_id, id, dept_id, name, start_date, end_date, status, sort)
      select p_ws, id, dept, name, start_date, end_date, 'Draft', sort from _nrot
      on conflict (workspace_id, id) do update set dept_id = excluded.dept_id, name = excluded.name, start_date = excluded.start_date,
        end_date = excluded.end_date, sort = excluded.sort;
    set constraints public.rotations_no_overlap immediate;
    delete from rotation_holidays where workspace_id = p_ws;
    insert into rotation_holidays(workspace_id, rotation_id, id, name, date, coverage, sort)
      select p_ws, rotation_id, id, name, date, coverage, sort from _nhol;
    if has_hh then
      delete from holiday_history where workspace_id = p_ws;
      insert into holiday_history(workspace_id, id, provider_id, holiday, year, sort) select p_ws, id, provider, holiday, year, sort from _nhh;
    end if;
    delete from providers p where p.workspace_id = p_ws and not exists (select 1 from _np n where n.id = p.id);
    delete from shift_types t where t.workspace_id = p_ws and not exists (select 1 from _nt n where n.id = t.id);
  exception
    when exclusion_violation then
      perform cs_fail('Two rotations for the same team overlap. Adjust their dates so they do not share any day.');
    when foreign_key_violation then
      perform cs_fail('Invalid workspace data: a record refers to a provider, department, or shift type that does not exist (or one still in use was removed).');
    when check_violation or not_null_violation or unique_violation or string_data_right_truncation then
      perform cs_fail('Invalid workspace data: ' || sqlerrm);
  end;

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

    foreach msg in array changed loop
      v := cs_violations(p_ws, msg);
      if cardinality(v) > 0 then
        select to_char(date, 'YYYY-MM-DD') || ' ' || coalesce((select name from shift_types t where t.workspace_id = p_ws and t.id = a.shift_id), a.shift_id)
          || ' · ' || coalesce((select name from providers p where p.workspace_id = p_ws and p.id = a.provider_id), a.provider_id)
          into msg from assignments a where a.workspace_id = p_ws and a.id = msg;
        perform cs_fail('Blocked: ' || array_to_string(v, ' · ') || ' (' || msg || ')');
      end if;
    end loop;
  end if;

  -- legacy month periods: publication / reopen (unchanged behavior)
  for x in select n.*, o.status old_status, o.published_at old_at, o.snapshot old_snapshot
           from _ne n left join periods o on o.workspace_id = p_ws and o.dept_id = n.dept and o.month = n.month loop
    if not exists (select 1 from departments where workspace_id = p_ws and id = x.dept) then
      perform cs_fail('Invalid schedule period: unknown department ' || x.dept);
    end if;
    if x.status = 'Published' and x.old_status is distinct from 'Published' and p_mode = 'edit' then
      n_missing := cs_coverage_missing(p_ws, x.dept, x.month);
      n_conf := cs_range_conflicts(p_ws, x.dept, to_date(x.month, 'YYYY-MM'), (to_date(x.month, 'YYYY-MM') + interval '1 month' - interval '1 day')::date);
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
      insert into periods(workspace_id, dept_id, month, status, published_at, snapshot)
        values (p_ws, x.dept, x.month, x.status, x.old_at, x.old_snapshot)
        on conflict (workspace_id, dept_id, month) do update set status = excluded.status;
    end if;
  end loop;
  delete from periods pe where pe.workspace_id = p_ws and not exists (select 1 from _ne n where n.dept = pe.dept_id and n.month = pe.month)
    and (p_mode = 'import' or pe.status = 'Draft');
  update periods pe set status = 'Draft' where pe.workspace_id = p_ws and pe.status = 'Published'
    and not exists (select 1 from _ne n where n.dept = pe.dept_id and n.month = pe.month);

  -- rotations: publication / reopen
  for x in select n.*, o.status old_status, o.published_at old_at, o.snapshot old_snapshot
           from _nrot n left join (select ro.id, ro2.status, ro2.published_at, ro2.snapshot from jsonb_to_recordset(old->'rotations') as ro(id text)
                                   join rotations ro2 on ro2.workspace_id = p_ws and ro2.id = ro.id) o on o.id = n.id loop
    if x.status = 'Published' and x.old_status is distinct from 'Published' and p_mode = 'edit' then
      n_missing := cs_coverage_missing_range(p_ws, x.dept, x.start_date, x.end_date);
      n_conf := cs_range_conflicts(p_ws, x.dept, x.start_date, x.end_date);
      if n_missing > 0 or n_conf > 0 then
        perform cs_fail('Cannot publish ' || x.name || ': ' || n_missing || ' open shifts · ' || n_conf || ' rule conflicts.');
      end if;
      update rotations set status = 'Published', published_at = now(),
        snapshot = (select coalesce(jsonb_agg(cs_assignment_json(a) order by a.sort, a.date, a.id), '[]') from assignments a
                    where a.workspace_id = p_ws and a.dept_id = x.dept and a.date between x.start_date and x.end_date)
        where workspace_id = p_ws and id = x.id;
      insert into publications(workspace_id, dept_id, rotation_id, published_by, snapshot)
        select p_ws, x.dept, x.id, uid, snapshot from rotations where workspace_id = p_ws and id = x.id;
    elsif p_mode = 'import' then
      update rotations set status = x.status, published_at = x.at, snapshot = x.snapshot where workspace_id = p_ws and id = x.id;
      if x.status = 'Published' and x.snapshot is not null and not exists (
           select 1 from publications where workspace_id = p_ws and rotation_id = x.id and snapshot = x.snapshot) then
        insert into publications(workspace_id, dept_id, rotation_id, published_at, published_by, snapshot)
          values (p_ws, x.dept, x.id, coalesce(x.at, now()), uid, x.snapshot);
      end if;
    else
      update rotations set status = x.status, published_at = x.old_at, snapshot = x.old_snapshot where workspace_id = p_ws and id = x.id;
    end if;
  end loop;

  if p_mode = 'edit' and config_changed then
    after_pub := cs_published_violations(p_ws);
    if exists (select unnest(after_pub) except select unnest(before_pub)) then
      perform cs_fail('This change would conflict with a published schedule. Reopen the affected schedule first.');
    end if;
  end if;

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
  return jsonb_build_object('version', new_version, 'audit', cs_audit_json(p_ws), 'periods', cs_export(p_ws)->'periods',
    'rotations', cs_export(p_ws)->'rotations');
end $$;

create or replace function public.list_publications(p_ws text, p_dept text, p_month text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not cs_is_member(p_ws) then raise exception 'You do not have access to this workspace.' using errcode = 'PT403'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'at', cs_iso(p.published_at), 'rotation', p.rotation_id, 'month', p.month,
           'by', (select email from auth.users u where u.id = p.published_by), 'assignments', jsonb_array_length(p.snapshot)) order by p.id desc)
         from publications p where p.workspace_id = p_ws and p.dept_id = p_dept and (p.month = p_month or p.rotation_id = p_month)), '[]');
end $$;

-- new helper functions are internal; only the existing RPC grants apply
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.get_state(text), public.get_version(text), public.my_workspaces(),
  public.save_state(text, bigint, jsonb, text[], text), public.list_snapshots(text), public.get_snapshot(text, bigint),
  public.list_publications(text, text, text), public.list_members(text), public.invite_member(text, text, text),
  public.revoke_invitation(text, text), public.set_member_role(text, uuid, text), public.remove_member(text, uuid),
  public.cs_role(text), public.cs_is_member(text) to authenticated;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
