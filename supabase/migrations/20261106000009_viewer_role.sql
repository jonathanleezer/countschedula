-- CountSchedula: the Viewer role (providers seeing their own and shared schedules), self-service time off,
-- provider-linked accounts, team sharing, and Synergy reconciliation.
--
-- Synergy (maintained by Vanderbilt) is the record of fact for schedules and PTO. CountSchedula tracks, for every
-- published rotation and every approved / changed PTO request, whether it has been entered in Synergy, and flags
-- anything changed since ("changed") so schedulers can update Synergy.
--
-- Access model (enforced here, not in the page):
--   admin / scheduler  everything in the workspace (unchanged)
--   viewer             published rotations of visible teams; own PTO in full; others' approved PTO dates only;
--                      can submit, edit (pending), shorten or withdraw (approved) their own requests
--   visible teams      the teams of the viewer's linked provider, teams shared with those teams, and teams
--                      shared with the viewer personally
-- All table access from the API now goes through these functions; direct table reads are revoked.

-- ---------------------------------------------------------------- schema
alter table public.members add column provider_id text,
  add constraint members_provider_fk foreign key (workspace_id, provider_id) references public.providers(workspace_id, id) on delete set null (provider_id);
create unique index members_provider_uq on public.members(workspace_id, provider_id) where provider_id is not null;
alter table public.invitations add column provider_id text;

alter table public.requests drop constraint requests_status_check;
alter table public.requests add constraint requests_status_check check (status in ('Pending','Approved','Declined','Withdrawn')),
  add column submitted_by uuid references auth.users(id) on delete set null,
  add column synergy_at timestamptz, add column synergy_by uuid references auth.users(id) on delete set null, add column synergy_state jsonb;
alter table public.rotations add column synergy_at timestamptz, add column synergy_by uuid references auth.users(id) on delete set null,
  add column synergy_snapshot jsonb;

create table public.team_shares (
  id           bigint generated always as identity primary key,
  workspace_id text not null references public.workspaces(id) on delete cascade,
  dept_id      text not null,                       -- the team whose schedule is shared
  with_dept_id text,                                -- shared with everyone on this team ...
  with_user    uuid references auth.users(id) on delete cascade,   -- ... or with this person
  created_at   timestamptz not null default now(),
  created_by   uuid references auth.users(id) on delete set null,
  foreign key (workspace_id, dept_id) references public.departments(workspace_id, id),
  foreign key (workspace_id, with_dept_id) references public.departments(workspace_id, id),
  check ((with_dept_id is null) <> (with_user is null)),
  check (with_dept_id is distinct from dept_id)
);
create unique index team_shares_uq on public.team_shares(workspace_id, dept_id, coalesce(with_dept_id, ''), coalesce(with_user::text, ''));
alter table public.team_shares enable row level security;

-- RPC-only access: the client never reads tables directly.
revoke all on all tables in schema public from anon, authenticated;

-- ---------------------------------------------------------------- helpers
create or replace function public.cs_my_provider(p_ws text) returns text
language sql stable security definer set search_path = public as $$
  select provider_id from members where workspace_id = p_ws and user_id = auth.uid()
$$;

create or replace function public.cs_visible_depts(p_ws text) returns text[]
language sql stable security definer set search_path = public as $$
  select case when cs_role(p_ws) in ('admin', 'scheduler') then
      (select coalesce(array_agg(id order by sort), '{}') from departments where workspace_id = p_ws)
    when cs_role(p_ws) = 'viewer' then (
      with own as (
        select f.dept_id from members m join affiliations f on f.workspace_id = m.workspace_id and f.provider_id = m.provider_id
        where m.workspace_id = p_ws and m.user_id = auth.uid())
      select coalesce(array_agg(distinct d), '{}') from (
        select dept_id d from own
        union select s.dept_id from team_shares s where s.workspace_id = p_ws and s.with_dept_id in (select dept_id from own)
        union select s.dept_id from team_shares s where s.workspace_id = p_ws and s.with_user = auth.uid()) x)
    else '{}'::text[] end
$$;

create or replace function public.cs_rotation_assignment_set(r public.rotations) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('date', to_char(a.date, 'YYYY-MM-DD'), 'shift', a.shift_id, 'provider', a.provider_id)
           order by a.date, a.shift_id, a.provider_id), '[]')
  from assignments a where a.workspace_id = r.workspace_id and a.dept_id = r.dept_id and a.date between r.start_date and r.end_date
$$;

-- status: none (nothing to enter) | not-entered | changed (differs from what was entered) | ok
create or replace function public.cs_rotation_synergy(r public.rotations) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object('at', cs_iso(r.synergy_at), 'by', (select email from auth.users where id = r.synergy_by),
    'status', case when r.synergy_at is null then case when r.status = 'Published' then 'not-entered' else 'none' end
                   when r.synergy_snapshot is distinct from cs_rotation_assignment_set(r) then 'changed' else 'ok' end))
$$;

create or replace function public.cs_request_synergy(r public.requests) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object('at', cs_iso(r.synergy_at), 'by', (select email from auth.users where id = r.synergy_by),
    'status', case when r.synergy_at is null then case when r.status = 'Approved' then 'not-entered' else 'none' end
                   when r.synergy_state is distinct from jsonb_build_object('start', to_char(r.start_date, 'YYYY-MM-DD'), 'end', to_char(r.end_date, 'YYYY-MM-DD'), 'status', r.status)
                     then 'changed' else 'ok' end))
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
        'status', r.status, 'reason', r.reason, 'via', case when r.submitted_by is not null then 'app' end)) || jsonb_build_object('synergy', cs_request_synergy(r)) order by r.sort, r.id) from requests r where r.workspace_id = p_ws), '[]'),
    'rules', (select rules from workspaces where id = p_ws),
    'periods', coalesce((select jsonb_object_agg(pe.dept_id || ':' || pe.month, jsonb_strip_nulls(jsonb_build_object(
        'status', pe.status, 'at', cs_iso(pe.published_at), 'snapshot', pe.snapshot)))
        from periods pe where pe.workspace_id = p_ws), '{}'),
    'rotations', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', r.id, 'dept', r.dept_id, 'name', r.name,
        'start', to_char(r.start_date, 'YYYY-MM-DD'), 'end', to_char(r.end_date, 'YYYY-MM-DD'), 'status', r.status,
        'at', cs_iso(r.published_at), 'snapshot', r.snapshot, 'pattern', r.pattern)) || jsonb_build_object('dateShifts', r.date_shifts, 'synergy', cs_rotation_synergy(r)) || jsonb_build_object('holidays',
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

-- Viewer's filtered state (same shape as cs_export).
create or replace function public.cs_export_viewer(p_ws text) returns jsonb
language sql stable security definer set search_path = public as $$
  with vis as (select unnest(cs_visible_depts(p_ws)) d),
       me as (select cs_my_provider(p_ws) pid),
       vprov as (select distinct p.id from providers p join affiliations f on f.workspace_id = p.workspace_id and f.provider_id = p.id
                 where p.workspace_id = p_ws and f.dept_id in (select d from vis)
                 union select pid from me where pid is not null)
  select jsonb_build_object(
    'providers', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'role', p.role,
        'target', p.target, 'max', p.max, 'rotationTarget', p.rotation_target, 'rotationMax', p.rotation_max, 'nights', p.nights,
        'affiliations', coalesce((select jsonb_agg(f.dept_id order by d.sort, f.dept_id) from affiliations f
                                  join departments d on d.workspace_id = f.workspace_id and d.id = f.dept_id
                                  where f.workspace_id = p.workspace_id and f.provider_id = p.id), '[]'))
        || case when p.id = (select pid from me) and p.preferences is not null then jsonb_build_object('preferences', p.preferences) else '{}'::jsonb end
        order by p.sort, p.id) from providers p where p.workspace_id = p_ws and p.id in (select id from vprov)), '[]'),
    'shiftTypes', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name,
        'start', to_char(t.start_time, 'HH24:MI'), 'end', to_char(t.end_time, 'HH24:MI'), 'color', t.color,
        'coverage', t.coverage, 'night', t.night, 'active', t.active) order by t.sort, t.id)
        from shift_types t where t.workspace_id = p_ws), '[]'),
    'assignments', coalesce((select jsonb_agg(cs_assignment_json(a) order by a.sort, a.date, a.id) from assignments a
        where a.workspace_id = p_ws and a.dept_id in (select d from vis) and cs_is_locked(p_ws, a.dept_id, a.date)), '[]'),
    'requests', coalesce((select jsonb_agg(case when r.provider_id = (select pid from me)
          then jsonb_strip_nulls(jsonb_build_object('id', r.id, 'provider', r.provider_id, 'start', to_char(r.start_date, 'YYYY-MM-DD'),
               'end', to_char(r.end_date, 'YYYY-MM-DD'), 'status', r.status, 'reason', r.reason, 'mine', true))
          else jsonb_build_object('id', r.id, 'provider', r.provider_id, 'start', to_char(r.start_date, 'YYYY-MM-DD'),
               'end', to_char(r.end_date, 'YYYY-MM-DD'), 'status', r.status) end order by r.sort, r.id)
        from requests r where r.workspace_id = p_ws
          and (r.provider_id = (select pid from me) or (r.status = 'Approved' and r.provider_id in (select id from vprov)))), '[]'),
    'rules', (select rules from workspaces where id = p_ws),
    'periods', coalesce((select jsonb_object_agg(pe.dept_id || ':' || pe.month, jsonb_build_object('status', pe.status))
        from periods pe where pe.workspace_id = p_ws and pe.status = 'Published' and pe.dept_id in (select d from vis)), '{}'),
    'rotations', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', r.id, 'dept', r.dept_id, 'name', r.name,
        'start', to_char(r.start_date, 'YYYY-MM-DD'), 'end', to_char(r.end_date, 'YYYY-MM-DD'), 'status', r.status,
        'at', cs_iso(r.published_at), 'pattern', r.pattern)) || jsonb_build_object('dateShifts', r.date_shifts, 'holidays',
          coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', h.id, 'name', h.name, 'date', to_char(h.date, 'YYYY-MM-DD'), 'coverage', h.coverage, 'team', h.team_holiday_id)) order by h.sort, h.date)
                    from rotation_holidays h where h.workspace_id = r.workspace_id and h.rotation_id = r.id), '[]'))
        order by r.sort, r.start_date, r.id) from rotations r where r.workspace_id = p_ws and r.status = 'Published' and r.dept_id in (select d from vis)), '[]'),
    'rotationDefaults', '{}'::jsonb,
    'teamHolidays', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', t.id, 'dept', t.dept_id, 'name', t.name, 'kind', t.kind,
        'month', t.month, 'day', t.day, 'weekday', t.weekday, 'nth', t.nth, 'date', to_char(t.date, 'YYYY-MM-DD'))) || jsonb_build_object('coverage', t.coverage)
        order by t.sort, t.id) from team_holidays t where t.workspace_id = p_ws and t.dept_id in (select d from vis)), '[]'),
    'holidayHistory', '[]'::jsonb,
    'audit', coalesce((select jsonb_agg(jsonb_build_object('text', text, 'time', cs_iso(at), 'by', actor_email) order by id desc)
        from (select * from audit_log where workspace_id = p_ws and actor = auth.uid() order by id desc limit 100) x), '[]'))
$$;

create or replace function public.get_state(p_ws text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r text; w record; vis text[];
begin
  r := cs_role(p_ws);
  if r is null then raise exception 'You do not have access to this workspace.' using errcode = 'PT403'; end if;
  select * into w from workspaces where id = p_ws;
  vis := cs_visible_depts(p_ws);
  return jsonb_build_object('version', w.version, 'role', r,
    'workspace', jsonb_build_object('id', w.id, 'name', w.name, 'timezone', w.timezone),
    'departments', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'org', org_name) order by sort, id), '[]')
                    from departments where workspace_id = p_ws and id = any(vis)),
    'visibleDepartments', to_jsonb(vis),
    'me', jsonb_strip_nulls(jsonb_build_object('provider', cs_my_provider(p_ws))),
    'state', case when r = 'viewer' then cs_export_viewer(p_ws) else cs_export(p_ws) end);
end $$;

-- ---------------------------------------------------------------- self-service time off (any member with a linked provider)
create or replace function public.cs_bump(p_ws text, p_kind text, p_text text, p_detail jsonb default null) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare v bigint;
begin
  insert into audit_log(workspace_id, actor, actor_email, kind, text, detail)
    values (p_ws, auth.uid(), (select email from auth.users where id = auth.uid()), p_kind, left(p_text, 500), p_detail);
  update workspaces set version = version + 1 where id = p_ws returning version into v;
  return v;
end $$;

create or replace function public.cs_check_request_dates(p_start date, p_end date, p_reason text) returns void
language plpgsql immutable as $$
begin
  if p_start is null or p_end is null or p_end < p_start then perform cs_fail('The last day must be on or after the first day.'); end if;
  if p_end - p_start > 366 then perform cs_fail('A time-off request can be at most one year long.'); end if;
  if p_start < date '2000-01-01' or p_end > date '2100-12-31' then perform cs_fail('Choose dates between 2000 and 2100.'); end if;
  if length(coalesce(p_reason, '')) > 160 then perform cs_fail('Keep the reason to 160 characters.'); end if;
end $$;

create or replace function public.submit_request(p_ws text, p_start date, p_end date, p_reason text default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare pid text := cs_my_provider(p_ws); rid text := 'req-' || replace(gen_random_uuid()::text, '-', ''); nm text;
begin
  if cs_role(p_ws) is null then raise exception 'You do not have access to this workspace.' using errcode = 'PT403'; end if;
  if pid is null then perform cs_fail('Your account is not linked to a provider yet. Ask a workspace administrator to link it.'); end if;
  perform 1 from workspaces where id = p_ws for update;
  perform cs_check_request_dates(p_start, p_end, p_reason);
  select name into nm from providers where workspace_id = p_ws and id = pid;
  insert into requests(workspace_id, id, provider_id, start_date, end_date, status, reason, sort, submitted_by)
    values (p_ws, rid, pid, p_start, p_end, 'Pending', nullif(btrim(coalesce(p_reason, '')), ''),
            coalesce((select max(sort) + 1 from requests where workspace_id = p_ws), 0), auth.uid());
  return jsonb_build_object('id', rid, 'version', cs_bump(p_ws, 'pto', 'Requested PTO · ' || nm || ' · ' || p_start || ' – ' || p_end));
end $$;

-- Pending: any change. Approved: shorten only (applies immediately, flagged for Synergy). Others: no changes.
create or replace function public.update_request(p_ws text, p_id text, p_start date, p_end date, p_reason text default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare pid text := cs_my_provider(p_ws); r record; nm text;
begin
  if cs_role(p_ws) is null then raise exception 'You do not have access to this workspace.' using errcode = 'PT403'; end if;
  perform 1 from workspaces where id = p_ws for update;
  select * into r from requests where workspace_id = p_ws and id = p_id for update;
  if not found or pid is null or r.provider_id is distinct from pid then raise exception 'You can only change your own time-off requests.' using errcode = 'PT403'; end if;
  perform cs_check_request_dates(p_start, p_end, p_reason);
  select name into nm from providers where workspace_id = p_ws and id = pid;
  if r.status = 'Pending' then
    update requests set start_date = p_start, end_date = p_end, reason = nullif(btrim(coalesce(p_reason, '')), '') where workspace_id = p_ws and id = p_id;
    return jsonb_build_object('version', cs_bump(p_ws, 'pto', 'Changed pending PTO · ' || nm || ' · ' || p_start || ' – ' || p_end));
  elsif r.status = 'Approved' then
    if p_start < r.start_date or p_end > r.end_date then
      perform cs_fail('Approved time off can only be shortened here. Submit a new request for extra days.');
    end if;
    update requests set start_date = p_start, end_date = p_end, reason = nullif(btrim(coalesce(p_reason, '')), '') where workspace_id = p_ws and id = p_id;
    return jsonb_build_object('version', cs_bump(p_ws, 'pto', 'Shortened approved PTO · ' || nm || ' · now ' || p_start || ' – ' || p_end || ' (was ' || r.start_date || ' – ' || r.end_date || ') · update Synergy'));
  end if;
  perform cs_fail('Only pending or approved requests can be changed.');
end $$;

create or replace function public.withdraw_request(p_ws text, p_id text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare pid text := cs_my_provider(p_ws); r record; nm text;
begin
  if cs_role(p_ws) is null then raise exception 'You do not have access to this workspace.' using errcode = 'PT403'; end if;
  perform 1 from workspaces where id = p_ws for update;
  select * into r from requests where workspace_id = p_ws and id = p_id for update;
  if not found or pid is null or r.provider_id is distinct from pid then raise exception 'You can only withdraw your own time-off requests.' using errcode = 'PT403'; end if;
  if r.status not in ('Pending', 'Approved') then perform cs_fail('Only pending or approved requests can be withdrawn.'); end if;
  select name into nm from providers where workspace_id = p_ws and id = pid;
  update requests set status = 'Withdrawn' where workspace_id = p_ws and id = p_id;
  return jsonb_build_object('version', cs_bump(p_ws, 'pto', 'Withdrew ' || lower(r.status) || ' PTO · ' || nm || ' · ' || r.start_date || ' – ' || r.end_date
    || case when r.status = 'Approved' then ' · update Synergy' else '' end));
end $$;

-- ---------------------------------------------------------------- Synergy reconciliation (schedulers)
create or replace function public.mark_synergy(p_ws text, p_kind text, p_id text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r public.rotations; q public.requests;
begin
  if cs_role(p_ws) not in ('admin', 'scheduler') then raise exception 'Only schedulers can record Synergy entries.' using errcode = 'PT403'; end if;
  perform 1 from workspaces where id = p_ws for update;
  if p_kind = 'rotation' then
    select * into r from rotations where workspace_id = p_ws and id = p_id;
    if not found then perform cs_fail('Unknown rotation.'); end if;
    update rotations set synergy_at = now(), synergy_by = auth.uid(), synergy_snapshot = cs_rotation_assignment_set(r) where workspace_id = p_ws and id = p_id;
    return jsonb_build_object('version', cs_bump(p_ws, 'synergy', 'Entered in Synergy · ' || r.name));
  elsif p_kind = 'request' then
    select * into q from requests where workspace_id = p_ws and id = p_id;
    if not found then perform cs_fail('Unknown request.'); end if;
    update requests set synergy_at = now(), synergy_by = auth.uid(),
      synergy_state = jsonb_build_object('start', to_char(q.start_date, 'YYYY-MM-DD'), 'end', to_char(q.end_date, 'YYYY-MM-DD'), 'status', q.status)
      where workspace_id = p_ws and id = p_id;
    return jsonb_build_object('version', cs_bump(p_ws, 'synergy', 'Entered in Synergy · PTO ' || (select name from providers where workspace_id = p_ws and id = q.provider_id)
      || ' · ' || q.start_date || ' – ' || q.end_date || ' · ' || q.status));
  end if;
  perform cs_fail('Unknown Synergy item.');
end $$;

-- ---------------------------------------------------------------- members: provider links and sharing (admins)
create or replace function public.cs_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into members(workspace_id, user_id, role, provider_id)
    select i.workspace_id, new.id, i.role,
           case when not exists (select 1 from members m where m.workspace_id = i.workspace_id and m.provider_id = i.provider_id) then i.provider_id end
    from invitations i where i.email = new.email::citext and i.accepted_at is null
    on conflict (workspace_id, user_id) do nothing;
  update invitations set accepted_at = now() where email = new.email::citext and accepted_at is null;
  return new;
end $$;

create or replace function public.list_members(p_ws text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('user_id', m.user_id, 'email', u.email, 'role', m.role, 'provider', m.provider_id,
                 'since', cs_iso(m.created_at), 'last_sign_in', cs_iso(u.last_sign_in_at))) order by u.email)
               from members m join auth.users u on u.id = m.user_id where m.workspace_id = p_ws), '[]'),
    'invitations', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('email', i.email, 'role', i.role, 'provider', i.provider_id, 'at', cs_iso(i.created_at))) order by i.email)
               from invitations i where i.workspace_id = p_ws and i.accepted_at is null), '[]'),
    'shares', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', s.id, 'dept', s.dept_id, 'withDept', s.with_dept_id,
                 'withUser', s.with_user, 'withEmail', (select email from auth.users where id = s.with_user))) order by s.dept_id, s.id)
               from team_shares s where s.workspace_id = p_ws), '[]'));
end $$;

drop function public.invite_member(text, text, text);
create or replace function public.invite_member(p_ws text, p_email text, p_role text, p_provider text default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid; e citext := lower(btrim(p_email));
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  if p_role not in ('admin', 'scheduler', 'viewer') then perform cs_fail('Role must be admin, scheduler, or viewer.'); end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then perform cs_fail('Enter a valid email address.'); end if;
  if p_provider is not null and not exists (select 1 from providers where workspace_id = p_ws and id = p_provider) then perform cs_fail('Unknown provider.'); end if;
  if p_provider is not null and exists (select 1 from members m join auth.users u on u.id = m.user_id where m.workspace_id = p_ws and m.provider_id = p_provider and u.email::citext <> e) then
    perform cs_fail('That provider is already linked to another account.');
  end if;
  select id into uid from auth.users where email::citext = e;
  if uid is not null then
    insert into members(workspace_id, user_id, role, provider_id) values (p_ws, uid, p_role, p_provider)
      on conflict (workspace_id, user_id) do update set role = excluded.role, provider_id = coalesce(excluded.provider_id, members.provider_id);
    insert into invitations(workspace_id, email, role, invited_by, accepted_at, provider_id) values (p_ws, e, p_role, auth.uid(), now(), p_provider)
      on conflict (workspace_id, email) do update set role = excluded.role, accepted_at = now(), provider_id = excluded.provider_id;
  else
    insert into invitations(workspace_id, email, role, invited_by, provider_id) values (p_ws, e, p_role, auth.uid(), p_provider)
      on conflict (workspace_id, email) do update set role = excluded.role, accepted_at = null, provider_id = excluded.provider_id;
  end if;
  perform cs_member_audit(p_ws, 'Invited ' || e || ' as ' || p_role);
  return list_members(p_ws);
end $$;

create or replace function public.set_member_provider(p_ws text, p_user uuid, p_provider text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  if p_provider is not null and not exists (select 1 from providers where workspace_id = p_ws and id = p_provider) then perform cs_fail('Unknown provider.'); end if;
  begin
    update members set provider_id = p_provider where workspace_id = p_ws and user_id = p_user;
  exception when unique_violation then perform cs_fail('That provider is already linked to another account.');
  end;
  perform cs_member_audit(p_ws, 'Linked ' || coalesce((select email from auth.users where id = p_user), '?') || ' to '
    || coalesce((select name from providers where workspace_id = p_ws and id = p_provider), 'no provider'));
  return list_members(p_ws);
end $$;

create or replace function public.share_team(p_ws text, p_dept text, p_with_dept text default null, p_with_user uuid default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  if (p_with_dept is null) = (p_with_user is null) then perform cs_fail('Share with either a team or a person.'); end if;
  if p_with_user is not null and not exists (select 1 from members where workspace_id = p_ws and user_id = p_with_user) then perform cs_fail('That person is not a member of this workspace.'); end if;
  begin
    insert into team_shares(workspace_id, dept_id, with_dept_id, with_user, created_by) values (p_ws, p_dept, p_with_dept, p_with_user, auth.uid());
  exception when unique_violation then null;
            when check_violation or foreign_key_violation then perform cs_fail('Choose a team to share and a different team or a person to share it with.');
  end;
  perform cs_member_audit(p_ws, 'Shared ' || coalesce((select org_name from departments where workspace_id = p_ws and id = p_dept), p_dept) || ' schedule with '
    || coalesce((select org_name from departments where workspace_id = p_ws and id = p_with_dept), (select email from auth.users where id = p_with_user), '?'));
  return list_members(p_ws);
end $$;

create or replace function public.remove_share(p_ws text, p_id bigint) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  delete from team_shares where workspace_id = p_ws and id = p_id;
  perform cs_member_audit(p_ws, 'Removed a schedule share');
  return list_members(p_ws);
end $$;

-- publication history only for teams the caller can see
create or replace function public.list_publications(p_ws text, p_dept text, p_month text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (p_dept = any(cs_visible_depts(p_ws))) then raise exception 'You do not have access to this team.' using errcode = 'PT403'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'at', cs_iso(p.published_at), 'rotation', p.rotation_id, 'month', p.month,
           'by', (select email from auth.users u where u.id = p.published_by), 'assignments', jsonb_array_length(p.snapshot)) order by p.id desc)
         from publications p where p.workspace_id = p_ws and p.dept_id = p_dept and (p.month = p_month or p.rotation_id = p_month)), '[]');
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.get_state(text), public.get_version(text), public.my_workspaces(),
  public.save_state(text, bigint, jsonb, text[], text), public.list_snapshots(text), public.get_snapshot(text, bigint),
  public.list_publications(text, text, text), public.list_members(text), public.invite_member(text, text, text, text),
  public.revoke_invitation(text, text), public.set_member_role(text, uuid, text), public.remove_member(text, uuid),
  public.set_member_provider(text, uuid, text), public.share_team(text, text, text, uuid), public.remove_share(text, bigint),
  public.submit_request(text, date, date, text), public.update_request(text, text, date, date, text), public.withdraw_request(text, text),
  public.mark_synergy(text, text, text), public.cs_role(text), public.cs_is_member(text) to authenticated;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
