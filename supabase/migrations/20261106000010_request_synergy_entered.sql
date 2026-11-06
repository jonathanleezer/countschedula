-- Include what was last entered in Synergy (dates and status) with each request, so the client can show the
-- Synergy status straight after a scheduler edits a request (approve, decline, reopen) without a reload.
create or replace function public.cs_request_synergy(r public.requests) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_strip_nulls(jsonb_build_object('at', cs_iso(r.synergy_at), 'by', (select email from auth.users where id = r.synergy_by),
    'entered', r.synergy_state,
    'status', case when r.synergy_at is null then case when r.status = 'Approved' then 'not-entered' else 'none' end
                   when r.synergy_state is distinct from jsonb_build_object('start', to_char(r.start_date, 'YYYY-MM-DD'), 'end', to_char(r.end_date, 'YYYY-MM-DD'), 'status', r.status)
                     then 'changed' else 'ok' end))
$$;
revoke execute on function public.cs_request_synergy(public.requests) from public, anon, authenticated;
