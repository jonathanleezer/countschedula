# Architecture and source map

## Runtime

Buildless HTML/CSS/JavaScript. `index.html` loads `app.js` as a classic script. State and functions share the page's lexical/global environment, and HTML uses inline event handlers. CSS imports Google Fonts; system fonts provide fallback offline. No application API requests or third-party model calls occur.

Local persistence key: `countschedula-pilot-v1`. New browsers seed sample providers and generate the initial November 2026 Jones Team schedule. The date cursor is hardcoded to that month. Organization display selection, current view, filters, and undo history are memory-only.

## Data

- `depts`: code constants, not persisted CRUD. `willow` = Jones Team / Labor & Delivery; `river` = Boehm Team / Birth Center. Organization identity is derived from these constants and their organization names. One department per organization currently.
- `providers`: id, name, role, monthly target/max, night eligibility, affiliations (department IDs).
- `shiftTypes`: id, name, start/end `HH:mm`, hex color, required daily coverage, night flag, active flag. Global across departments.
- `assignments`: id, provider ID, department ID, date, shift type ID, optional note.
- `requests`: id, provider ID, inclusive start/end dates, status, optional reason.
- `rules`: rest hours, max consecutive assignment dates; old backups may retain legacy dayCoverage/nightCoverage.
- `periods`: keyed `department:YYYY-MM`; Draft/Published state, publication time, snapshot.
- `audit`: local text/time records, capped at 300.

`migrate()` adds default types to older states and updates old organization names in audit text. Internal legacy IDs are deliberately unchanged. Source does not contain saved browser data.

## Principal functions

| Concern | Functions |
|---|---|
| Views | render, navigate, schedule, calendarCells, providersPage, shiftTypesPage, requestsPage, rulesPage, reportsPage, settingsPage |
| Organization display | organizations, organizationFor, displayOrganizations, displayDepartments, organizationPicker, toggleOrganization |
| Constraints | interval, violations, validateAll, coverageMissing, canEdit, isPublished |
| Editing | assignmentDialog, updateAssignmentProviders, saveAssignment, deleteAssignment, bindDnD |
| Generation/publication | generateDialog, generate, publishDialog, publish, reopen |
| Configuration | providerDialog/saveProvider, shiftTypeDialog/saveShiftType, saveRules |
| Persistence | persist, migrate, checkpoint, undo, backup, restore |
| Export | exportCSV, csvCell, download |

## Generator

Iterates missing slots in date/type order. Ranks affiliated providers by monthly count / target, adds penalties for night and weekend counts, then chooses the first candidate passing `violations()`. Ties use provider name. No backtracking, search, proof of infeasibility, minimum workload guarantee, or global optimality. Each generation targets one department; validation and provider workload counts are global.

## Tests

The three original `check*.cjs` files evaluate the application in Node's VM with mocked DOM/localStorage and suppress render/toast. They exercise domain logic and some generated HTML, not real browser interactions. They depend on the app's current initialization marker. Refactoring should preserve or deliberately migrate these checks. Browser tests should be added for drag/drop, touch, keyboard, forms, persistence, and mobile layout.

## Shared backend (Supabase) — added 2026-11-04

The same static UI runs in two modes, chosen by `config.js`:

- **Browser-local pilot** (default for `npm start` without `SUPABASE_URL`): unchanged behavior, data in
  localStorage key `countschedula-pilot-v1`.
- **Shared workspace** (production): `scripts/build.cjs` writes `dist/config.js` with the Supabase URL,
  publishable key and workspace id. `dist/cloud.js` handles magic-link sign-in, loads the workspace with
  `get_state`, and sends every committed change to `save_state`. `npm start` also serves this mode when
  `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` are set in the environment.

### How a change is saved

`app.js` still validates and mutates its in-memory `state`, then calls `persist()`. In shared mode
`persist()` hands a copy of the whole state, the audit notes collected by `audit()`, and the version the
client loaded to `save_state`. The server, in one transaction:

1. checks the caller's role and the workspace version (`PT409` if someone else saved first; the client
   reloads and asks the user to redo the change);
2. validates payload shape and limits;
3. computes which assignments are new or changed and which department-months they touch;
4. refuses edits inside published periods, coverage/hour changes that would rewrite published
   schedules, and PTO approvals that overlap assignments;
5. applies the rows, then runs `cs_violations()` (a port of `violations()`) on every new or changed
   assignment against all organizations; configuration changes may not add conflicts to published
   periods;
6. on Draft→Published, re-checks coverage and conflicts, stores the server-built snapshot in `periods`
   and appends to `publications`;
7. appends to `audit_log` (actor email, notes, change counts), bumps the version.

Any rejection rolls back the whole save; the client reloads server state and shows the reason.
Whole-state saves keep the existing UI intact; they are simple and fine at this team size (≈100 KB per
year of schedules) but should become per-entity RPCs if workspaces grow large.

### Tables

`workspaces` (rules jsonb, timezone, version) · `departments` · `members` · `invitations` ·
`providers` · `affiliations` · `shift_types` · `assignments` · `requests` · `periods` ·
`publications` (append-only) · `audit_log` (append-only) · `state_snapshots`.
Every table is keyed by `workspace_id`; legacy ids are kept verbatim. RLS lets members read their own
workspace; there are no write policies — writes only happen through `SECURITY DEFINER` functions that
check the role. API roles cannot execute any function except the listed RPCs.

### Time

Shift instants are computed in the workspace time zone (`America/Chicago`) on the server, and in the
browser's local zone on the client. If a user's browser is in a different zone, or on a DST change
night, client and server may disagree about an interval by up to an hour; the server's answer wins.

### Tests

- `npm test` — original Node VM domain checks, `check-rotations.cjs`, and syntax checks.
- `npm run test:db` — applies the migrations to a throwaway local PostgreSQL with a stub of Supabase's
  `auth` schema and runs `supabase/tests/domain.test.sql` (rules, RLS isolation, roles, concurrency,
  publication, immutability, import round-trip, sign-up hook).
- `npm run test:browser` — Playwright acceptance checks of the local mode (desktop and phone).

## Rotations and holidays — added 2026-11-05

- **Rotation** = a team's scheduling period (default 8 weeks), stored in `state.rotations` as
  `{id, dept, name, start, end, status, at?, snapshot?, holidays:[{id, name, date, coverage:{shiftTypeId:n}}]}`.
  Each team (department) has its own non-overlapping rotations. `state.rotationDefaults[dept]` holds
  `{start, length, unit}` (days/weeks/months) used by "Add next rotation".
- **Period abstraction:** `period(dept)` is the selected rotation (toolbar choice → rotation containing the
  cursor → next upcoming → last) or, when a team has no rotation there, the calendar month. Generate,
  publish, reopen, reports and the "Edit / generate / publish" target use `period()`. Stats and CSV on the
  Schedule page use `visibleRange()` (the dates shown: rotation, month, or week).
- **Rotation-first views** (2026-11-05): the Schedule opens in Rotation view whenever the target team has
  rotations; Month and Week stay available (`setMode`). For a team with rotations, `period()` is always a
  rotation — in Month/Week it is the rotation covering the viewed dates (`anchorDay()`: mid-month / mid-week),
  unless one was picked in the toolbar — and there is no calendar-month fallback; `required()` is 0 on days
  outside that team's rotations, so no open shifts appear there. Teams without rotations keep month periods and
  see a "Set up rotations" notice; their Rotation view shows a set-up panel (prefilled from the team's rotation
  defaults) that creates rotations in one step and opens the first one. Reports follow the same Rotation/Month/Week scope (`reportScope()`) and add a
  rotation-by-rotation provider table; the Rotations page shows publication dates and a published-version view
  (snapshot vs. current, history in shared mode via `list_publications`); Requests show the rotations they
  touch; CSV has a Rotation column. The local pilot sample seeds 8-week rotations and standard holidays for both
  teams (`seedRotations()`).
- **Weekly shifts and date-specific shifts** (2026-11-05): `rotation.pattern` =
  `{shiftTypeId: {days:[0–6], count}}` chooses which shift types run on which weekdays; teams set a default
  pattern in `rotationDefaults[dept].pattern`, copied into each new rotation. `rotation.dateShifts` =
  `{date: {shiftTypeId: n}}` sets one shift type's count on one date (0 removes it). `required()` precedence:
  date-specific shift > holiday staffing > weekly pattern > shift type daily default (rotations without a pattern).
  Server: `rotations.pattern/date_shifts`, `cs_required()` with the same precedence, frozen on published rotations
  (migration `20261105000007_rotation_shift_patterns.sql`).
- **Week start** (2026-11-05): weeks begin on the weekday a rotation starts (`weekStartDay()`): Rotation view
  shows whole weeks from the start date with "Week N" labels; Week view and Month view columns follow the
  rotation covering the cursor (the target team's); the weekly-shifts grid uses the same order. Teams without
  rotations use Sunday. Display only: patterns store absolute weekdays, so the server is unaffected.
- **Provider shift preferences** (2026-11-06): `provider.preferences.weekly` = `{"<shiftType>:<weekday>": "prefer"|"avoid"}`,
  edited as a grid in Providers → Edit. Soft only: the generator subtracts `PREF_BONUS` (2) for prefer and adds
  `AVOID_PENALTY` (4) for avoid to a candidate's score (one extra shift ≈ 10/target ≈ 0.5 at target 20), so a
  preferred shift goes to that provider unless they are ~4 shifts ahead, and an avoided one only when nobody else
  can legally take it or others are ~8 shifts heavier. Calendar cards show ♥/✕, the shift editor shows a hint, and
  Reports count preferred / not-preferred shifts. Server stores and validates only
  (migration `20261106000008_provider_preferences.sql`).
- **Viewer role and Synergy** (2026-11-06, migration `20261106000009_viewer_role.sql`):
  - Accounts link to a provider (`members.provider_id`, set at invite or in Settings → Team access).
  - Visible teams (`cs_visible_depts`): the linked provider's teams, teams shared with those teams, and teams shared
    with the person (`team_shares`). Admins and schedulers see everything.
  - `get_state` returns `cs_export_viewer` for viewers: published rotations/periods of visible teams and their
    assignments only; own requests in full; others' approved requests as dates only (no reasons); no scheduler
    settings; own activity only. API roles can no longer read tables directly — all access is through RPCs.
  - Self-service PTO RPCs: `submit_request`, `update_request` (pending: any change; approved: shorten only, applies
    immediately), `withdraw_request` (status `Withdrawn`). Each bumps the version and is audited.
  - Synergy (Vanderbilt's record of fact): `mark_synergy` records that a published rotation or a PTO request was
    entered; the export reports `synergy.status` = `not-entered` / `changed` / `ok` / `none` by comparing the current
    rotation assignments (date, shift, provider) or request (dates, status) with what was marked.
  - Client: viewers get My schedule, a read-only Schedule (own shifts outlined, "Off" markers), Time off, Settings.
    Schedulers see Synergy columns on Requests and Rotations and a to-do notice on Schedule; anyone with a linked
    provider also gets My schedule.
- **Locks:** `isPublished(dept, day)` is true inside a published rotation of that team or a published
  legacy month. Legacy month publications remain valid.
- **Coverage:** `required(dept, day, type)` returns a holiday's override for that type, else the type's daily
  coverage. Used by open slots, coverage gaps, generation and publish checks.
- **Workload:** inside a rotation of the assignment's team, `rotationMax` counts the provider's shifts on all
  teams during that rotation's dates; outside rotations the monthly `max` applies. `migrate()` set
  `rotationTarget/rotationMax` to 2× the monthly values once.
- **Team holiday calendars** (added 2026-11-05): `state.teamHolidays` = `{id, dept, name, kind, …, coverage}` with
  `kind` `fixed` (month/day every year), `nth` (1st–5th or last weekday of a month) or `once` (date).
  `syncTeamHolidays()` copies each team's holidays into that team's **draft** rotations (holiday entries carry
  `team: <definition id>`), on adding rotations, changing a rotation's dates, and editing the team list.
  Rotation-only (one-off) holidays have no `team` and win if they share a date. Published rotations keep the
  holidays they were published with. Server: `team_holidays` table and `rotation_holidays.team_holiday_id`
  (migration `20261105000006_team_holidays.sql`); the date rules are applied in the client.
- **Holiday fairness:** holiday gaps are generated first. Candidates are penalised for holiday shifts already
  in this period, for how often they covered the same holiday (matched by name, case-insensitive) in
  earlier years, and most strongly for covering it recently. History = CountSchedula assignments on that
  team's holiday dates + `state.holidayHistory` entries recorded for years before the app. Soft preference,
  never a hard rule.
- **Server:** migration `20261105000005_rotations.sql` adds `rotations` (exclusion constraint prevents
  overlap per team), `rotation_holidays`, `holiday_history`, `providers.rotation_target/rotation_max`,
  `workspaces.rotation_defaults`, `publications.rotation_id`; `cs_violations`, `cs_required`,
  `cs_is_locked`, coverage and `save_state` mirror the client. Payloads that omit the rotation keys
  (older cached clients) leave rotations unchanged.
