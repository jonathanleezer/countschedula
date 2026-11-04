# Operations runbook

How the hosted CountSchedula is put together and how to run it day to day. Account-specific values
(project ref, team) are listed so an operator can find things; no secrets belong in this file.

## Where things live

| Piece | Where | Notes |
|---|---|---|
| Source | GitHub `jonathanleezer/countschedula` (private) | `main` is what is deployed |
| Web app | Vercel project `countschedula` (team `team-leezer`) → https://countschedula.vercel.app | Static files from `dist/`, built by `npm run build` |
| Database + auth | Supabase project `countschedula`, ref `mdznbifeuxhfhekpsguj`, region us-east-1, Free plan | Postgres 17 |
| Workspace | id `vanderbilt-midwives`, time zone `America/Chicago` | Departments `willow` (Jones Team) and `river` (Boehm Team) |

Vercel environment variables (all environments): `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`
(the public client key), `COUNTSCHEDULA_WORKSPACE`. The build refuses to deploy without
`SUPABASE_URL` and refuses secret/service-role keys.

## Deploying

The Vercel project is not linked to GitHub yet (Vercel's GitHub app is not installed on the repo), so
pushes do not deploy automatically. Either:

- **Connect Git (recommended):** Vercel → project `countschedula` → Settings → Git → connect
  `jonathanleezer/countschedula`. Every push to `main` then deploys to production and pull requests get
  preview URLs.
- **Manual:** from a checkout with the Vercel CLI: `npx vercel --prod`.

Run `npm test`, `npm run test:db` and `npm run test:browser` before deploying.

## Database migrations

Migrations are plain SQL in `supabase/migrations/`, applied in filename order. They were applied with
the Supabase Management API and recorded in `supabase_migrations.schema_migrations`, so the Supabase
CLI (`supabase link --project-ref mdznbifeuxhfhekpsguj`, then `supabase db push`) treats them as done.

For a change: add a new timestamped file (never edit an applied one), run `npm run test:db`, then
`supabase db push` (or paste the file into the Supabase SQL editor). Keep legacy IDs stable.

## People and access

- Roles: **admin** (everything, including members, restore and rollback), **scheduler** (all schedule,
  provider, shift type, rule and PTO changes; publish/reopen), **viewer** (read only).
- Admins invite people in the app: Settings → Team access → Invite. The person then opens the site and
  requests a sign-in link with that email. Sign-up is invite-only (Supabase "before user created" hook
  `public.hook_before_user_created`).
- The first admin invitation (jonathan.leezer@gmail.com) was created by `cs_bootstrap_workspace`.

### Email delivery (action needed before inviting others)

The project uses Supabase's built-in email sender. On the Free plan it only delivers to members of the
Supabase organization and only a few messages per hour, and the email templates cannot be customized.
Before inviting the team, configure custom SMTP (for example Resend, Postmark or Amazon SES):
Supabase dashboard → Authentication → Emails → SMTP settings. Then raise the email rate limit
(Authentication → Rate limits) and, optionally, brand the magic-link template.

## Backups and recovery

- **In-app rollback snapshots:** taken before every restore/import and at most once a day while people
  save. Kept 45 days (newest 10 always kept). Admins can download or roll back from Settings.
- **JSON backup:** Settings → Download backup (any member). Restore is admin-only, shows a preview, and
  takes a snapshot first.
- **Database backups:** the Supabase Free plan has no downloadable daily backups or point-in-time
  recovery. For anything you cannot afford to lose, download a JSON backup regularly or move to Pro
  (daily backups) — check current pricing first.
- **Pausing:** Free projects pause after about a week without activity. Restore from the Supabase
  dashboard if the app reports it cannot reach the server.

## Database password

The database password was randomly generated at project creation and not stored. Reset it in the
Supabase dashboard (Project Settings → Database) if you need direct `psql`/`pg_dump` access.

## Removing a test workspace

Audit and publication tables are append-only by trigger. To delete a whole workspace (for example a QA
workspace), as the `postgres` role in the SQL editor:

```sql
begin;
alter table audit_log disable trigger audit_log_append_only;
alter table publications disable trigger publications_append_only;
delete from workspaces where id = '<workspace-id>';
alter table audit_log enable trigger audit_log_append_only;
alter table publications enable trigger publications_append_only;
commit;
```

## Credentials used to build this

Supabase and Vercel access tokens were stored as network secrets on the Claude Code cloud environment
`countschedula`, not in the repository. Revoke them when no longer needed:
Supabase → Account → Access Tokens; Vercel → Account Settings → Tokens.
