-- CountSchedula shared backend: core schema.
-- Legacy stable IDs are preserved: department ids 'willow' (Jones Team) and 'river' (Boehm Team),
-- provider ids such as 'p0', shift type ids such as 'day'/'night'.
-- All writes go through SECURITY DEFINER functions (see later migrations); clients get read-only
-- row-level access to the workspaces they belong to.

create extension if not exists citext;

-- ---------------------------------------------------------------- tables

create table public.workspaces (
  id          text primary key check (id ~ '^[a-z0-9-]{1,64}$'),
  name        text not null check (length(name) between 1 and 120),
  timezone    text not null default 'America/Chicago',
  rules       jsonb not null default '{"rest":12,"consecutive":3}'::jsonb,
  version     bigint not null default 0,
  created_at  timestamptz not null default now()
);

create table public.departments (
  workspace_id text not null references public.workspaces(id) on delete cascade,
  id           text not null check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  name         text not null,
  org_name     text not null,
  sort         int  not null default 0,
  primary key (workspace_id, id)
);

create table public.members (
  workspace_id text not null references public.workspaces(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         text not null check (role in ('admin','scheduler','viewer')),
  created_at   timestamptz not null default now(),
  primary key (workspace_id, user_id)
);
create index members_user_idx on public.members(user_id);

create table public.invitations (
  workspace_id text not null references public.workspaces(id) on delete cascade,
  email        citext not null check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  role         text not null check (role in ('admin','scheduler','viewer')),
  invited_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  accepted_at  timestamptz,
  primary key (workspace_id, email)
);

create table public.providers (
  workspace_id text not null references public.workspaces(id) on delete cascade,
  id           text not null check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  name         text not null check (length(name) between 1 and 120),
  role         text not null default '' check (length(role) <= 60),
  target       numeric not null check (target >= 0),
  max          numeric not null check (max >= 1),
  nights       boolean not null default true,
  sort         int not null default 0,
  primary key (workspace_id, id),
  check (target <= max)
);

create table public.affiliations (
  workspace_id text not null,
  provider_id  text not null,
  dept_id      text not null,
  primary key (workspace_id, provider_id, dept_id),
  foreign key (workspace_id, provider_id) references public.providers(workspace_id, id) on delete cascade,
  foreign key (workspace_id, dept_id) references public.departments(workspace_id, id)
);

create table public.shift_types (
  workspace_id text not null references public.workspaces(id) on delete cascade,
  id           text not null check (id ~ '^[a-z0-9-]{1,64}$'),
  name         text not null check (length(btrim(name)) between 1 and 40),
  start_time   time not null,
  end_time     time not null,
  color        text not null check (color ~* '^#[0-9a-f]{6}$'),
  coverage     int  not null check (coverage between 0 and 10),
  night        boolean not null default false,
  active       boolean not null default true,
  sort         int not null default 0,
  primary key (workspace_id, id),
  check (start_time <> end_time)
);
create unique index shift_types_name_uq on public.shift_types(workspace_id, lower(btrim(name)));

create table public.assignments (
  workspace_id text not null,
  id           text not null check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  provider_id  text not null,
  dept_id      text not null,
  date         date not null,
  shift_id     text not null,
  note         text check (length(note) <= 500),
  sort         int not null default 0,
  primary key (workspace_id, id),
  foreign key (workspace_id, provider_id) references public.providers(workspace_id, id),
  foreign key (workspace_id, dept_id) references public.departments(workspace_id, id),
  foreign key (workspace_id, shift_id) references public.shift_types(workspace_id, id)
);
create index assignments_provider_date_idx on public.assignments(workspace_id, provider_id, date);
create index assignments_dept_date_idx on public.assignments(workspace_id, dept_id, date);

create table public.requests (
  workspace_id text not null,
  id           text not null check (id ~ '^[A-Za-z0-9_-]{1,64}$'),
  provider_id  text not null,
  start_date   date not null,
  end_date     date not null,
  status       text not null check (status in ('Pending','Approved','Declined')),
  reason       text check (length(reason) <= 160),
  sort         int not null default 0,
  primary key (workspace_id, id),
  foreign key (workspace_id, provider_id) references public.providers(workspace_id, id),
  check (end_date >= start_date)
);

-- Current publication state per department-month (client key "dept:YYYY-MM").
create table public.periods (
  workspace_id text not null,
  dept_id      text not null,
  month        text not null check (month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  status       text not null check (status in ('Draft','Published')),
  published_at timestamptz,
  snapshot     jsonb,
  primary key (workspace_id, dept_id, month),
  foreign key (workspace_id, dept_id) references public.departments(workspace_id, id)
);

-- Immutable history: one row per publish event, never updated or deleted.
create table public.publications (
  id           bigint generated always as identity primary key,
  workspace_id text not null references public.workspaces(id) on delete cascade,
  dept_id      text not null,
  month        text not null,
  published_at timestamptz not null default now(),
  published_by uuid,
  snapshot     jsonb not null
);
create index publications_lookup_idx on public.publications(workspace_id, dept_id, month, published_at desc);

-- Append-only audit trail.
create table public.audit_log (
  id           bigint generated always as identity primary key,
  workspace_id text not null references public.workspaces(id) on delete cascade,
  at           timestamptz not null default now(),
  actor        uuid,
  actor_email  text,
  kind         text not null,
  text         text not null,
  detail       jsonb
);
create index audit_log_ws_idx on public.audit_log(workspace_id, id desc);

-- Whole-workspace snapshots for rollback (taken before imports/restores and at most daily on save).
create table public.state_snapshots (
  id           bigint generated always as identity primary key,
  workspace_id text not null references public.workspaces(id) on delete cascade,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  reason       text not null,
  version      bigint not null,
  state        jsonb not null
);
create index state_snapshots_ws_idx on public.state_snapshots(workspace_id, id desc);

-- Append-only enforcement (applies to every role, including the definer functions).
create or replace function public.cs_forbid_change() returns trigger language plpgsql as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = 'PT403';
end $$;
create trigger audit_log_append_only before update or delete on public.audit_log
  for each row execute function public.cs_forbid_change();
create trigger publications_append_only before update or delete on public.publications
  for each row execute function public.cs_forbid_change();

-- ---------------------------------------------------------------- access helpers

create or replace function public.cs_role(p_ws text) returns text
language sql stable security definer set search_path = public as $$
  select role from public.members where workspace_id = p_ws and user_id = auth.uid()
$$;

create or replace function public.cs_is_member(p_ws text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where workspace_id = p_ws and user_id = auth.uid())
$$;

-- ---------------------------------------------------------------- row level security
-- Members can read their workspace. There are deliberately no INSERT/UPDATE/DELETE policies:
-- every mutation must pass through the validating RPCs.

alter table public.workspaces      enable row level security;
alter table public.departments     enable row level security;
alter table public.members         enable row level security;
alter table public.invitations     enable row level security;
alter table public.providers       enable row level security;
alter table public.affiliations    enable row level security;
alter table public.shift_types     enable row level security;
alter table public.assignments     enable row level security;
alter table public.requests        enable row level security;
alter table public.periods         enable row level security;
alter table public.publications    enable row level security;
alter table public.audit_log       enable row level security;
alter table public.state_snapshots enable row level security;

create policy ws_read  on public.workspaces   for select to authenticated using (public.cs_is_member(id));
create policy dep_read on public.departments  for select to authenticated using (public.cs_is_member(workspace_id));
create policy mem_read on public.members      for select to authenticated using (user_id = auth.uid());
create policy pro_read on public.providers    for select to authenticated using (public.cs_is_member(workspace_id));
create policy aff_read on public.affiliations for select to authenticated using (public.cs_is_member(workspace_id));
create policy st_read  on public.shift_types  for select to authenticated using (public.cs_is_member(workspace_id));
create policy asg_read on public.assignments  for select to authenticated using (public.cs_is_member(workspace_id));
create policy req_read on public.requests     for select to authenticated using (public.cs_is_member(workspace_id));
create policy per_read on public.periods      for select to authenticated using (public.cs_is_member(workspace_id));
create policy pub_read on public.publications for select to authenticated using (public.cs_is_member(workspace_id));
create policy aud_read on public.audit_log    for select to authenticated using (public.cs_is_member(workspace_id));
-- invitations and state_snapshots: no policies (admin RPCs only).

revoke all on all tables in schema public from anon, authenticated;
grant select on public.workspaces, public.departments, public.members, public.providers, public.affiliations,
  public.shift_types, public.assignments, public.requests, public.periods, public.publications, public.audit_log
  to authenticated;
