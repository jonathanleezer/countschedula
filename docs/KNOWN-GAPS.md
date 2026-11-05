# Known gaps and review findings

Updated 2026-11-04 after the shared backend (Supabase + Vercel) was added. These are source-review
findings and implementation limits, not a list of proven production incidents. CountSchedula is a
working shared scheduling application for a small team; it is not certified for clinical use and has
had no independent security review.

## Resolved in this round

- Shared storage, sign-in (email magic link, invite-only), workspace roles (admin / scheduler / viewer),
  and tenant isolation by row-level security. Proven by `npm run test:db`.
- Server-side enforcement of every hard rule on every mutation path (forms, drag/drop, generation,
  undo, provider/type/rule edits, PTO approval, restore). The browser can no longer bypass rules or
  publication locks by editing local data.
- Publication is checked server-side (coverage complete, zero conflicts), snapshots are built by the
  server, and every publish is appended to an immutable `publications` history.
- Append-only audit log with the signed-in actor's email.
- Optimistic concurrency: a stale save is refused and the client reloads instead of overwriting.
- Restore/import: admin only, previewed, snapshotted for rollback, strictly validated on the client and
  server. Injection-shaped IDs from a crafted backup are rejected (regression test in
  `npm run test:browser`).
- localStorage failures in local mode now show a warning instead of failing silently.

## Operational limits (current plan)

- **Email delivery:** Supabase's built-in sender (Free plan) delivers only to members of the Supabase
  organization, a few messages per hour, with an unbranded template. Configure custom SMTP before
  inviting others. See `docs/OPERATIONS.md`.
- **Backups:** the Free plan has no daily database backups or point-in-time recovery. In-app rollback
  snapshots and JSON downloads are the recovery path. Free projects also pause after about a week of
  inactivity.
- **Deploys** are manual until the Vercel project is connected to the GitHub repository.
- No uptime monitoring, error reporting, or alerting is configured.

## Security notes

- The UI still uses inline event handlers, so the Content-Security-Policy must allow `'unsafe-inline'`
  scripts. Imported IDs are now validated and names are escaped, but a full move to event delegation
  would let the CSP drop `'unsafe-inline'`.
- Sessions are stored in the browser's localStorage (supabase-js default). Sign out on shared computers.
- Everyone in the workspace can read the whole workspace (both organizations, all providers, PTO
  reasons). There are no per-organization information boundaries yet.
- Membership changes take effect on the next request; there is no forced sign-out of removed users'
  existing sessions beyond losing access to data.

## Scheduling semantics (unchanged policy questions)

- `max consecutive` counts consecutive assignment start dates, not every date touched by an overnight shift.
- Minimum rest applies between same-day partial shifts, so Clinic AM + PM for one provider fails with 12h rest.
- Monthly maximum counts assignments, not hours/FTE. Target is a soft count.
- Shift hours are global; there are no effective-dated templates. Published schedules block changes that would rewrite them.
- Coverage is one per-type daily count for both departments; no weekday/date overrides or overstaffing cap.
- Inactive shift types keep existing assignments.
- **Time zones:** the server evaluates intervals in the workspace zone (`America/Chicago`); the browser uses
  its own local zone for its pre-checks. Users in other zones or on DST change nights may see the client
  allow something the server rejects (or the reverse); the server decides.
- Greedy generation may leave gaps when a feasible solution exists; it does not prove infeasibility.
- Server validation checks each new or changed assignment against all others; it does not re-flag
  pre-existing conflicts in draft periods created by later configuration changes (they are still shown
  as conflicts and block publishing).

## Rotations and holidays — open policy questions

- A shift counts as a holiday shift when its **start date** is the holiday (a Christmas Eve night shift
  that runs into Christmas morning counts as Christmas Eve). Confirm the practice's rule.
- The rotation maximum is the same number for every rotation, regardless of the rotation's length. Custom
  4- or 12-week rotations are not prorated.
- Holidays are matched across years by name ("Christmas Day"); renaming a holiday starts a new history.
- Year-over-year holiday rotation is a generator preference, not a hard rule; manual assignments can give
  someone the same holiday two years running (the Reports page flags it with ⚠).
- Holiday history only counts holidays that were defined in a rotation (or recorded in "Holiday coverage
  before CountSchedula"). Assignments made before rotations were set up do not count.
- Team holiday rules cover fixed dates, nth/last weekday of a month, and single dates. Movable feasts (e.g.
  Easter) and "observed" weekday shifts (Jul 4 on a Saturday observed Friday) need a single-date entry per year.
- The server stores team holidays but does not re-derive rotation holiday dates from the rules; the client keeps
  draft rotations in step.
- Standard US holidays offered: New Year's Day, Memorial Day, Independence Day, Labor Day, Thanksgiving,
  Christmas Eve, Christmas Day, New Year's Eve. Edit per rotation as needed.
- Teams with rotations have no coverage requirement (and no open shifts) outside their rotations; this is a client
  rule. The server's month-publication check still uses daily coverage, but month publishing is no longer offered
  to teams with rotations.
- Teams without any rotations still use calendar-month periods and monthly limits. Old published months stay locked.
- Publication history in the published-version view lists dates, who published, and assignment counts; only the
  latest published snapshot can be opened or downloaded.

## UI and reporting

- Month/week stats use full-month counts; the provider filter does not scope coverage metrics.
- Reports show global provider totals while department summaries/export use their own scope.
- Display selection and edit/generate/publish target are separate; a target can remain selected while hidden.
- Native HTML drag/drop has no complete touch experience; keyboard editing exists via the form.
- The assignment modal's Save button is not refreshed when the date moves into a published month (save is still refused).
- The schedule's initial month is fixed to November 2026.
- Viewers see editing controls; edits are refused with a read-only message instead of being hidden.
- Whole-state saves are simple and fine at this size, but each save sends the full workspace; move to
  per-entity RPCs if workspaces grow to many years of data.

## Roadmap, not implemented

Provider self-service PTO, swaps, exception approvals, credentials/privileges, holiday rules,
notifications, schedule version comparison UI (history is stored), configurable organizations and
departments, affiliation-specific rules, a robust optimizer, monitoring, and a formal security review.
