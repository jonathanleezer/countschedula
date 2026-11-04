-- Minimal stand-in for the Supabase platform objects the migrations depend on.
-- Used only by scripts/test-db.cjs against a throwaway local PostgreSQL cluster.
create role anon nologin;
create role authenticated nologin;
create role supabase_auth_admin nologin;
create schema auth;
create table auth.users (
  id uuid primary key,
  email text unique,
  last_sign_in_at timestamptz
);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
grant usage on schema public to authenticated, anon;
