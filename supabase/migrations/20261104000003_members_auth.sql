-- CountSchedula shared backend: membership, invitations, sign-up gate, bootstrap, grants.
-- Roles: admin (everything incl. members, restore/import, rollback), scheduler (edit schedules,
-- providers, shift types, rules, PTO review, publish/reopen), viewer (read only).

-- New auth users receive any pending invitations as memberships.
create or replace function public.cs_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into members(workspace_id, user_id, role)
    select i.workspace_id, new.id, i.role from invitations i where i.email = new.email::citext and i.accepted_at is null
    on conflict (workspace_id, user_id) do nothing;
  update invitations set accepted_at = now() where email = new.email::citext and accepted_at is null;
  return new;
end $$;

drop trigger if exists cs_on_auth_user_created on auth.users;
create trigger cs_on_auth_user_created after insert on auth.users
  for each row execute function public.cs_handle_new_user();

-- Supabase Auth "before user created" hook: only invited email addresses may create an account.
create or replace function public.hook_before_user_created(event jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from invitations where email = (event->'user'->>'email')::citext) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object('http_code', 403,
    'message', 'This email has not been invited to a CountSchedula workspace. Ask your workspace administrator for an invitation.'));
end $$;

create or replace function public.list_members(p_ws text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  return jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'email', u.email, 'role', m.role,
                 'since', cs_iso(m.created_at), 'last_sign_in', cs_iso(u.last_sign_in_at)) order by u.email)
               from members m join auth.users u on u.id = m.user_id where m.workspace_id = p_ws), '[]'),
    'invitations', coalesce((select jsonb_agg(jsonb_build_object('email', i.email, 'role', i.role, 'at', cs_iso(i.created_at)) order by i.email)
               from invitations i where i.workspace_id = p_ws and i.accepted_at is null), '[]'));
end $$;

create or replace function public.cs_member_audit(p_ws text, p_text text) returns void
language sql security definer set search_path = public as $$
  insert into audit_log(workspace_id, actor, actor_email, kind, text)
  values (p_ws, auth.uid(), (select email from auth.users where id = auth.uid()), 'members', p_text);
  update workspaces set version = version + 1 where id = p_ws;
$$;

create or replace function public.invite_member(p_ws text, p_email text, p_role text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare uid uuid; e citext := lower(btrim(p_email));
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  if p_role not in ('admin', 'scheduler', 'viewer') then perform cs_fail('Role must be admin, scheduler, or viewer.'); end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then perform cs_fail('Enter a valid email address.'); end if;
  select id into uid from auth.users where email::citext = e;
  if uid is not null then
    insert into members(workspace_id, user_id, role) values (p_ws, uid, p_role)
      on conflict (workspace_id, user_id) do update set role = excluded.role;
    insert into invitations(workspace_id, email, role, invited_by, accepted_at) values (p_ws, e, p_role, auth.uid(), now())
      on conflict (workspace_id, email) do update set role = excluded.role, accepted_at = now();
  else
    insert into invitations(workspace_id, email, role, invited_by) values (p_ws, e, p_role, auth.uid())
      on conflict (workspace_id, email) do update set role = excluded.role, accepted_at = null;
  end if;
  perform cs_member_audit(p_ws, 'Invited ' || e || ' as ' || p_role);
  return list_members(p_ws);
end $$;

create or replace function public.revoke_invitation(p_ws text, p_email text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  delete from invitations where workspace_id = p_ws and email = lower(btrim(p_email))::citext and accepted_at is null;
  perform cs_member_audit(p_ws, 'Revoked invitation for ' || lower(btrim(p_email)));
  return list_members(p_ws);
end $$;

create or replace function public.set_member_role(p_ws text, p_user uuid, p_role text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  if p_role not in ('admin', 'scheduler', 'viewer') then perform cs_fail('Role must be admin, scheduler, or viewer.'); end if;
  perform 1 from workspaces where id = p_ws for update;
  update members set role = p_role where workspace_id = p_ws and user_id = p_user;
  if not exists (select 1 from members where workspace_id = p_ws and role = 'admin') then
    perform cs_fail('A workspace needs at least one administrator.');
  end if;
  perform cs_member_audit(p_ws, 'Changed ' || coalesce((select email from auth.users where id = p_user), p_user::text) || ' to ' || p_role);
  return list_members(p_ws);
end $$;

create or replace function public.remove_member(p_ws text, p_user uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare e text := (select email from auth.users where id = p_user);
begin
  if cs_role(p_ws) is distinct from 'admin' then raise exception 'Administrators only.' using errcode = 'PT403'; end if;
  perform 1 from workspaces where id = p_ws for update;
  delete from members where workspace_id = p_ws and user_id = p_user;
  delete from invitations where workspace_id = p_ws and email = e::citext;
  if not exists (select 1 from members where workspace_id = p_ws and role = 'admin') then
    perform cs_fail('A workspace needs at least one administrator.');
  end if;
  perform cs_member_audit(p_ws, 'Removed ' || coalesce(e, p_user::text));
  return list_members(p_ws);
end $$;

-- Operator-only: create a workspace with its departments, default shift types and first admin invitation.
-- Not granted to any API role; run from the SQL editor / Management API.
create or replace function public.cs_bootstrap_workspace(p_id text, p_name text, p_admin_email text, p_timezone text default 'America/Chicago')
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into workspaces(id, name, timezone) values (p_id, p_name, p_timezone) on conflict (id) do nothing;
  insert into departments(workspace_id, id, name, org_name, sort) values
    (p_id, 'willow', 'Jones Team · Labor & Delivery', 'Jones Team', 0),
    (p_id, 'river',  'Boehm Team · Birth Center',     'Boehm Team', 1)
    on conflict do nothing;
  insert into shift_types(workspace_id, id, name, start_time, end_time, color, coverage, night, active, sort) values
    (p_id, 'day',       'Day',       '07:00', '19:00', '#6b9b69', 1, false, true, 0),
    (p_id, 'night',     'Night',     '19:00', '07:00', '#8a79b2', 1, true,  true, 1),
    (p_id, 'clinic-am', 'Clinic AM', '08:00', '12:00', '#5c9db0', 0, false, true, 2),
    (p_id, 'clinic-pm', 'Clinic PM', '13:00', '17:00', '#b28e56', 0, false, true, 3),
    (p_id, 'triage',    'Triage',    '09:00', '21:00', '#b47783', 0, false, true, 4),
    (p_id, 'flex',      'Flex',      '11:00', '19:00', '#728caf', 0, false, true, 5)
    on conflict do nothing;
  insert into invitations(workspace_id, email, role) values (p_id, lower(btrim(p_admin_email)), 'admin')
    on conflict (workspace_id, email) do update set role = 'admin';
  -- if that user already exists, make them a member now
  insert into members(workspace_id, user_id, role)
    select p_id, u.id, 'admin' from auth.users u where u.email::citext = lower(btrim(p_admin_email))::citext
    on conflict (workspace_id, user_id) do update set role = 'admin';
end $$;

-- ---------------------------------------------------------------- function privileges

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.get_state(text), public.get_version(text), public.my_workspaces(),
  public.save_state(text, bigint, jsonb, text[], text),
  public.list_snapshots(text), public.get_snapshot(text, bigint), public.list_publications(text, text, text),
  public.list_members(text), public.invite_member(text, text, text), public.revoke_invitation(text, text),
  public.set_member_role(text, uuid, text), public.remove_member(text, uuid),
  public.cs_role(text), public.cs_is_member(text)
  to authenticated;
-- cs_is_member is used inside RLS policies, which run as the querying role.

grant usage on schema public to supabase_auth_admin;
grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;

-- Functions created later must not be callable by API roles until explicitly granted.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
