# Acceptance checklist

## Baseline automated

Run `npm test`. Expected: syntax checks and all three original domain regression scripts pass. They cover initial 60-slot generation, no configured conflicts, global overlap/rest/PTO, affiliation/monthly limits, six types/duration/overnight rollover, legacy migration, custom generation/coverage, organization filters, labels, aggregate coverage, selected export, nonempty organization selection, and independent locks.

These checks do not certify complete clinical correctness.

## Browser smoke checks

1. `npm start`; load http://localhost:3000. Confirm CountSchedula / Vanderbilt Midwives and Jones Team selected.
2. Display organizations: Jones only, both, Boehm only; prevent zero selected. Confirm labels/colored lanes and shared-provider assignments are clear.
3. Change display without generating/publishing. Confirm no assignment changes occur.
4. Open a Boehm slot while the action target remains Jones. Confirm editor defaults to Boehm, shows only affiliated providers, and saves to Boehm.
5. Drag an assignment to another date and another organization's slot. Check affiliation, rest, overlap, PTO, and published-state enforcement. Invalid moves must explain why and leave state unchanged.
6. Add/edit a type; set custom duration/overnight times/color/coverage. Confirm calendar, missing slots, generator, CSV, and hours update.
7. Submit PTO overlapping an assignment; approval blocks. Resolve assignment, approve, then verify generation avoids it.
8. Fill target schedule, publish, verify its lock independently of the other organization's schedule, then reopen.
9. Export CSV for selected organizations. Inspect org, department, provider, date, shift, times, and next-day end date.
10. Backup, restore in another clean browser origin, and compare provider IDs, assignments, shift types, PTO, and period status.
11. Mobile sidebar closes on navigation, close button, outside click, Escape. Tab/Enter can open assignment editor. Test real touch separately.
12. Reload: saved workspace remains. Session-only filters/undo reset as documented.

## Shared backend

- `npm run test:db`: rules, RLS isolation, roles, stale versions, publication, append-only history, import round-trip, sign-up hook, workspace deletion.
- Live check (2026-11-04, QA workspace, since deleted): sign-in gate, magic link, previewed import, server rejection of client-bypassed rule breaks, form/drag/undo saves, publish lock, stale-tab refusal, invites, snapshots, viewer read-only, mobile nav, sign-out.

## Rotations

- `npm test` (`check-rotations.cjs`), `npm run test:db` (rotation section), `npm run test:browser` (rotation section):
  defaults, consecutive 8-week rotations, standard holidays, overlap refusal, holiday coverage overrides,
  Rotation view, generation inside the rotation, year-over-year holiday preference, per-rotation maximum,
  publish/lock per team and rotation, older-client safety, reports and CSV holiday column.
- Live check (2026-11-05, QA workspace, since deleted): defaults and rotations saved, holiday override saved and
  honored by generation, server-confirmed full coverage with no conflicts, rotation publish with snapshot and
  history, server refusal of edits inside / re-dating of a published rotation and of overlapping rotations.
- Live check (2026-11-05, QA workspace, since deleted): per-team holiday calendars saved on the server, each team's
  rotations carry only its own linked holidays, team staffing shapes the calendar, deleting a team holiday updates
  drafts while the published rotation keeps its holidays, reload persists.

## Before wider release

Add tenant-isolation, permission, concurrency, publication/version, transaction, migration, import/schema, solver, DST, accessibility, and browser integration tests. Confirm no real provider information is sent to external services without explicit configuration and authorization.
