-- CountSchedula: provider shift preferences.
-- providers.preferences = {"weekly": {"<shift type>:<weekday 0-6>": "prefer" | "avoid"}}.
-- Soft rules used by the client's generator; the server stores and validates them but never blocks on them.
-- Payloads that omit a provider's preferences (older cached clients) keep the stored value.

alter table public.providers add column preferences jsonb check (preferences is null or jsonb_typeof(preferences) = 'object');

create or replace function public.cs_valid_preferences(p jsonb) returns boolean
language sql immutable as $$
  select p is null or jsonb_typeof(p) = 'null' or (jsonb_typeof(p) = 'object'
    and (not (p ? 'weekly') or jsonb_typeof(p->'weekly') = 'null' or (jsonb_typeof(p->'weekly') = 'object'
      and (select count(*) from jsonb_object_keys(p->'weekly')) <= 420
      and not exists (select 1 from jsonb_each(p->'weekly') e(k, v)
                      where k !~ '^[a-z0-9-]{1,64}:[0-6]$' or v not in ('"prefer"'::jsonb, '"avoid"'::jsonb)))))
$$;

create or replace function public.cs_export(p_ws text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'providers', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'role', p.role,
        'target', p.target, 'max', p.max, 'rotationTarget', p.rotation_target, 'rotationMax', p.rotation_max, 'nights', p.nights,
        'affiliations', coalesce((select jsonb_agg(f.dept_id order by d.sort, f.dept_id) from affiliations f
                                  join departments d on d.workspace_id = f.workspace_id and d.id = f.dept_id
                                  where f.workspace_id = p.workspace_id and f.provider_id = p.id), '[]'))
        || case when p.preferences is null then '{}'::jsonb else jsonb_build_object('preferences', p.preferences) end
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
        'at', cs_iso(r.published_at), 'snapshot', r.snapshot, 'pattern', r.pattern)) || jsonb_build_object('dateShifts', r.date_shifts) || jsonb_build_object('holidays',
          coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', h.id, 'name', h.name, 'date', to_char(h.date, 'YYYY-MM-DD'), 'coverage', h.coverage, 'team', h.team_holiday_id)) order by h.sort, h.date)
                    from rotation_holidays h where h.workspace_id = r.workspace_id and h.rotation_id = r.id), '[]'))
        order by r.sort, r.start_date, r.id) from rotations r where r.workspace_id = p_ws), '[]'),
    'rotationDefaults', (select rotation_defaults from workspaces where id = p_ws),
    'teamHolidays', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', t.id, 'dept', t.dept_id, 'name', t.name, 'kind', t.kind,
        'month', t.month, 'day', t.day, 'weekday', t.weekday, 'nth', t.nth, 'date', to_char(t.date, 'YYYY-MM-DD'))) || jsonb_build_object('coverage', t.coverage)
        order by t.sort, t.id) from team_holidays t where t.workspace_id = p_ws), '[]'),
    'holidayHistory', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'provider', x.provider_id, 'holiday', x.holiday, 'year', x.year)
        order by x.sort, x.id) from holiday_history x where x.workspace_id = p_ws), '[]'),
    'audit', cs_audit_json(p_ws))
$$;

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
      if not cs_valid_pattern(x->'pattern') then
        perform cs_fail(x->>'name' || ': each scheduled shift type needs days of the week and 1–10 providers');
      end if;
      if not cs_valid_date_shifts(x->'dateShifts') then
        perform cs_fail(x->>'name' || ': date-specific shifts need a date, a shift type and 0–10 providers');
      end if;
      for h in select * from jsonb_array_elements(coalesce(x->'holidays', '[]')) loop
        if jsonb_typeof(h) <> 'object' or jsonb_typeof(h->'id') <> 'string' or jsonb_typeof(h->'name') <> 'string'
           or coalesce(h->>'date', '') !~ '^\d{4}-\d{2}-\d{2}$' or jsonb_typeof(coalesce(h->'coverage', '{}')) <> 'object'
           or (h ? 'team' and jsonb_typeof(h->'team') <> 'string') then
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
      if not cs_valid_pattern(v->'pattern') then
        perform cs_fail('Default rotation: each scheduled shift type needs days of the week and 1–10 providers');
      end if;
      if coalesce(v->>'start', '') <> '' then perform (v->>'start')::date; end if;
    end loop;
  end if;
  if st ? 'teamHolidays' then
    if jsonb_typeof(st->'teamHolidays') <> 'array' or jsonb_array_length(st->'teamHolidays') > 500 then perform cs_fail('Invalid team holidays.'); end if;
    for x in select * from jsonb_array_elements(st->'teamHolidays') loop
      if jsonb_typeof(x) <> 'object' or jsonb_typeof(x->'id') <> 'string' or jsonb_typeof(x->'dept') <> 'string' or jsonb_typeof(x->'name') <> 'string'
         or coalesce(x->>'kind', '') not in ('fixed', 'nth', 'once') or jsonb_typeof(coalesce(x->'coverage', '{}')) <> 'object'
         or (x ? 'date' and coalesce(x->>'date', '') !~ '^\d{4}-\d{2}-\d{2}$')
         or exists (select 1 from unnest(array['month','day','weekday','nth']) f where x ? f and (jsonb_typeof(x->f) <> 'number' or (x->>f)::numeric <> trunc((x->>f)::numeric))) then
        perform cs_fail('Invalid team holiday: ' || left(coalesce(x->>'name', x->>'id', '?'), 60));
      end if;
      for k, v in select * from jsonb_each(coalesce(x->'coverage', '{}')) loop
        if k !~ '^[a-z0-9-]{1,64}$' or jsonb_typeof(v) <> 'number' or v::text::numeric <> trunc(v::text::numeric) or v::text::numeric < 0 or v::text::numeric > 10 then
          perform cs_fail(x->>'name' || ': holiday coverage must be whole numbers from 0 to 10');
        end if;
      end loop;
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
    if (x ? 'rotationTarget' and jsonb_typeof(x->'rotationTarget') <> 'number') or (x ? 'rotationMax' and jsonb_typeof(x->'rotationMax') <> 'number')
       or (x ? 'preferences' and not cs_valid_preferences(x->'preferences')) then
      perform cs_fail('Invalid provider record: ' || left(coalesce(x->>'name', x->>'id', '?'), 60));
    end if;
  end loop;
exception when invalid_datetime_format or datetime_field_overflow then
  perform cs_fail('Invalid workspace data: ' || sqlerrm);
end $$;

create or replace function public.save_state(p_ws text, p_base_version bigint, p_state jsonb,
  p_notes text[] default '{}', p_mode text default 'edit') returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r text; w record; old jsonb; uid uuid := auth.uid(); email text;
  changed text[]; v text[]; msg text; n_missing int; n_conf int;
  before_pub text[]; after_pub text[]; config_changed boolean; new_version bigint; x record; cnt jsonb;
  has_rot boolean := p_state ? 'rotations'; has_rd boolean := p_state ? 'rotationDefaults'; has_hh boolean := p_state ? 'holidayHistory'; has_th boolean := p_state ? 'teamHolidays';
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
  create temp table if not exists _np (id text, name text, role text, target numeric, max numeric, rotation_target numeric, rotation_max numeric, nights boolean, affiliations jsonb, sort int, preferences jsonb) on commit drop;
  create temp table if not exists _nt (id text, name text, start_time time, end_time time, color text, coverage int, night boolean, active boolean, sort int) on commit drop;
  create temp table if not exists _nr (id text, provider text, start_date date, end_date date, status text, reason text, sort int) on commit drop;
  create temp table if not exists _ne (dept text, month text, status text, at timestamptz, snapshot jsonb) on commit drop;
  create temp table if not exists _nrot (id text, dept text, name text, start_date date, end_date date, status text, at timestamptz, snapshot jsonb, holidays jsonb, sort int, pattern jsonb, date_shifts jsonb) on commit drop;
  create temp table if not exists _nhol (rotation_id text, id text, name text, date date, coverage jsonb, team text, sort int) on commit drop;
  create temp table if not exists _nth (id text, dept text, name text, kind text, month int, day int, weekday int, nth int, date date, coverage jsonb, sort int) on commit drop;
  create temp table if not exists _nhh (id text, provider text, holiday text, year int, sort int) on commit drop;
  create temp table if not exists _touched (dept text, date date) on commit drop;
  truncate _na, _np, _nt, _nr, _ne, _nrot, _nhol, _nhh, _nth, _touched;

  begin
    insert into _na select e->>'id', e->>'provider', e->>'dept', (e->>'date')::date, e->>'shift', nullif(e->>'note', ''), (o - 1)::int
      from jsonb_array_elements(p_state->'assignments') with ordinality j(e, o);
    insert into _np select e->>'id', btrim(e->>'name'), coalesce(e->>'role', ''), (e->>'target')::numeric, (e->>'max')::numeric,
      coalesce((e->>'rotationTarget')::numeric, op.rotation_target, (e->>'target')::numeric * 2),
      coalesce((e->>'rotationMax')::numeric, op.rotation_max, (e->>'max')::numeric * 2),
      coalesce((e->>'nights')::boolean, true), e->'affiliations', (o - 1)::int,
      case when e ? 'preferences' then nullif(e->'preferences', 'null'::jsonb) else op.preferences end
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
        case when e->>'at' ~ '^\d{4}-' then (e->>'at')::timestamptz end, e->'snapshot', coalesce(e->'holidays', '[]'), (o - 1)::int,
        case when jsonb_typeof(e->'pattern') = 'object' then e->'pattern' end, coalesce(e->'dateShifts', '{}')
        from jsonb_array_elements(p_state->'rotations') with ordinality j(e, o);
    else
      insert into _nrot select r2.id, r2.dept_id, r2.name, r2.start_date, r2.end_date, r2.status, r2.published_at, r2.snapshot,
        coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'date', h.date, 'coverage', h.coverage, 'team', h.team_holiday_id) order by h.sort)
                  from rotation_holidays h where h.workspace_id = p_ws and h.rotation_id = r2.id), '[]'), r2.sort, r2.pattern, r2.date_shifts
        from rotations r2 where r2.workspace_id = p_ws;
    end if;
    insert into _nhol select n.id, h->>'id', btrim(h->>'name'), (h->>'date')::date, coalesce(h->'coverage', '{}'), h->>'team', (o - 1)::int
      from _nrot n cross join jsonb_array_elements(n.holidays) with ordinality j(h, o);
    if has_th then
      insert into _nth select e->>'id', e->>'dept', btrim(e->>'name'), e->>'kind', (e->>'month')::int, (e->>'day')::int, (e->>'weekday')::int, (e->>'nth')::int,
        (e->>'date')::date, coalesce(e->'coverage', '{}'), (o - 1)::int
        from jsonb_array_elements(p_state->'teamHolidays') with ordinality j(e, o);
    end if;
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
     or exists (select 1 from _nhh group by id having count(*) > 1) or exists (select 1 from _nth group by id having count(*) > 1) then
    perform cs_fail('Invalid workspace data: duplicate record IDs.');
  end if;
  if exists (select 1 from _na where date < date '2000-01-01' or date > date '2100-12-31') then
    perform cs_fail('Invalid workspace data: assignment dates must be between 2000 and 2100.');
  end if;
  if exists (select 1 from _nrot n cross join jsonb_object_keys(n.date_shifts) d where d::date not between n.start_date and n.end_date) then
    perform cs_fail((select n.name || ': date-specific shifts must fall within the rotation dates' from _nrot n cross join jsonb_object_keys(n.date_shifts) d
                     where d::date not between n.start_date and n.end_date limit 1));
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
    or (has_rot and (old->'rotations') is distinct from (p_state->'rotations'))
    or (has_th and (old->'teamHolidays') is distinct from (p_state->'teamHolidays'));

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
    for x in select o.* , n.id new_id, n.status new_status, n.start_date new_start, n.end_date new_end, n.dept new_dept, n.pattern new_pattern, n.date_shifts new_date_shifts
             from rotations o left join _nrot n on n.id = o.id where o.workspace_id = p_ws and o.status = 'Published' loop
      if x.new_id is null then perform cs_fail('Reopen ' || x.name || ' before deleting it.'); end if;
      if x.new_status = 'Published' and ((x.start_date, x.end_date, x.dept_id) is distinct from (x.new_start, x.new_end, x.new_dept)
         or (x.pattern, x.date_shifts) is distinct from (x.new_pattern, x.new_date_shifts)
         or coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'date', h.date, 'coverage', h.coverage) order by h.id)
                      from rotation_holidays h where h.workspace_id = p_ws and h.rotation_id = x.id), '[]')
            is distinct from coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'date', h.date, 'coverage', h.coverage) order by h.id)
                      from _nhol h where h.rotation_id = x.id), '[]')) then
        perform cs_fail('Reopen ' || x.name || ' before changing its dates, weekly shifts or holidays.');
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
    insert into providers(workspace_id, id, name, role, target, max, rotation_target, rotation_max, nights, sort, preferences)
      select p_ws, id, name, role, target, max, rotation_target, rotation_max, nights, sort, preferences from _np
      on conflict (workspace_id, id) do update set name = excluded.name, role = excluded.role, target = excluded.target,
        max = excluded.max, rotation_target = excluded.rotation_target, rotation_max = excluded.rotation_max, nights = excluded.nights, sort = excluded.sort, preferences = excluded.preferences;
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
    insert into rotations(workspace_id, id, dept_id, name, start_date, end_date, status, sort, pattern, date_shifts)
      select p_ws, id, dept, name, start_date, end_date, 'Draft', sort, pattern, date_shifts from _nrot
      on conflict (workspace_id, id) do update set dept_id = excluded.dept_id, name = excluded.name, start_date = excluded.start_date,
        end_date = excluded.end_date, sort = excluded.sort, pattern = excluded.pattern, date_shifts = excluded.date_shifts;
    set constraints public.rotations_no_overlap immediate;
    delete from rotation_holidays where workspace_id = p_ws;
    insert into rotation_holidays(workspace_id, rotation_id, id, name, date, coverage, team_holiday_id, sort)
      select p_ws, rotation_id, id, name, date, coverage, team, sort from _nhol;
    if has_th then
      delete from team_holidays where workspace_id = p_ws;
      insert into team_holidays(workspace_id, id, dept_id, name, kind, month, day, weekday, nth, date, coverage, sort)
        select p_ws, id, dept, name, kind, month, day, weekday, nth, date, coverage, sort from _nth;
    end if;
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

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.get_state(text), public.get_version(text), public.my_workspaces(),
  public.save_state(text, bigint, jsonb, text[], text), public.list_snapshots(text), public.get_snapshot(text, bigint),
  public.list_publications(text, text, text), public.list_members(text), public.invite_member(text, text, text),
  public.revoke_invitation(text, text), public.set_member_role(text, uuid, text), public.remove_member(text, uuid),
  public.cs_role(text), public.cs_is_member(text) to authenticated;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
