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
- **Locks:** `isPublished(dept, day)` is true inside a published rotation of that team or a published
  legacy month. Legacy month publications remain valid.
- **Coverage:** `required(dept, day, type)` returns a holiday's override for that type, else the type's daily
  coverage. Used by open slots, coverage gaps, generation and publish checks.
- **Workload:** inside a rotation of the assignment's team, `rotationMax` counts the provider's shifts on all
  teams during that rotation's dates; outside rotations the monthly `max` applies. `migrate()` set
  `rotationTarget/rotationMax` to 2× the monthly values once.
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
