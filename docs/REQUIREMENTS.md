# Requirements and decisions

## Product purpose

Reduce the burden of scheduling inpatient OB providers, initially Certified Nurse Midwives, while respecting coverage, eligibility, availability, workload, rest, and fairness. A provider is one person with multiple department/organization affiliations; their commitments must be evaluated globally.

## Confirmed user direction

- SaaS ambition; current runnable deliverable is a browser-local pilot.
- Initial inpatient OB target: departments of roughly 15 or fewer providers; early examples included larger teams, so do not turn this into a hard database limit.
- Original V1 scope: 24/7, fixed 12-hour Day/Night shifts, no call shifts.
- **Later user change supersedes the fixed shift-type limitation:** shift types are configurable. Six sample types exist: Day, Night, Clinic AM, Clinic PM, Triage, Flex. New types can be added.
- Workspace name: **Vanderbilt Midwives**.
- Organizations: **Jones Team** and **Boehm Team**, replacing Willow and Riverside respectively. Jones Team is default.
- Simple ChatGPT/Claude-inspired left navigation.
- Calendar-style draggable assignments and provider cards; form editing as an alternative.
- Sidebar closes after mobile navigation.
- Schedule can display any nonempty combination of organizations. Labels and visual lanes distinguish assignments by organization.
- Providers may work across departments and organizations in V1.

## Implemented pilot

- Month/week calendars (week is a seven-day grid, not an hourly agenda).
- Provider filter, multiselect organization display, distinct organization lanes/assignment labels.
- Explicit department target for generation and publication.
- Provider add/edit; name, role, affiliations, night eligibility, monthly target and maximum.
- Shift type add/edit; name, times, color, daily coverage, night category, active flag. Day 07:00–19:00 and Night 19:00–07:00 default to one required provider/day/department. Clinic AM 08:00–12:00, Clinic PM 13:00–17:00, Triage 09:00–21:00, Flex 11:00–19:00 default to zero (optional).
- Assignment add/edit/remove; drag across dates and organization/shift drop zones; validates affiliation and conflicts.
- Hard checks: overlap, minimum global rest, approved PTO overlap, department affiliation, night availability, monthly maximum shift count, maximum consecutive assignment dates.
- Monthly targets guide generation; they are not enforced minimums. Night/weekend totals are soft goals, not configurable hard quotas.
- Deterministic greedy fill-open-shifts generator; keeps existing assignments.
- PTO request/approve/decline/reopen. Approval is blocked until existing conflicting shifts are resolved.
- Publish when required coverage is complete and configured rule conflicts are absent; reopen draft; per-department/month state and stored snapshot.
- Monthly reports (provider workload across affiliations), selected-organization calendar CSV export, JSON backup/restore, local activity trail, session undo.

## Implemented shared backend (2026-11-04)

- Supabase Postgres with row-level security; Vercel static hosting at https://countschedula.vercel.app.
- Email magic-link sign-in, invite-only; roles admin, scheduler, viewer.
- Server-side validation of all hard rules and publication locks on every save; optimistic concurrency.
- Immutable publication history and audit log; rollback snapshots; previewed admin-only restore.

## Rotations (2026-11-05)

Confirmed by the user:
- Each practice schedules in rotations; default length 8 weeks. Rotations replace calendar months as the unit
  that is generated, published and locked.
- Defaults are customizable per team (start date, duration in days/weeks/months); each rotation can have
  its own dates and its own holidays.
- Jones Team and Boehm Team each have their own rotation calendar.
- Provider targets and maximums are counted per rotation (converted once from monthly ×2).
- Holidays: mark holiday dates, holiday-specific coverage per shift type, fair sharing, and holiday
  coverage rotated from provider to provider year to year.
- Rotations are the default Schedule view and the center of publishing and reports; Month and Week views remain.
- Shift types are assigned to days of the week per rotation (team default pattern at rotation creation), with
  optional date-specific shift assignments inside the rotation.
- Holidays are defined per team (each team keeps its own holiday calendar and staffing), with optional
  one-off holidays on a single rotation.

Implemented as described in `docs/ARCHITECTURE.md` (Rotations and holidays).

## Proposed / not implemented

Department-lead and provider roles; provider preview; swaps; conditional approval exceptions; affiliation-specific contracts and quotas; holiday fairness; credential/privilege validation; organization and department CRUD; notifications; archived schedule workflow; explainable optimization solver; shared secure storage and real authentication.

Hard / conditional / soft taxonomy is the intended design. The pilot blocks hard violations and has no approved-exception workflow. Safety and coverage outrank contractual/site rules, fairness, then preferences; infeasibility must be surfaced, not hidden.

## Out of scope for initial product

Payroll, EMR integration, full messaging system, and call scheduling. Revisit only if explicitly requested.

## Unresolved decisions

Pricing/plan upgrades, SMTP provider, exact rule values/calculation periods, per-affiliation rule precedence, holiday/weekend definitions, time zones and DST, shift-count versus hours/FTE accounting, organization information-sharing boundaries, multiuser publication/versioning, exception permissions, solver objectives, release criteria.
