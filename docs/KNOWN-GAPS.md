# Known gaps and review findings

These are source-review findings and implementation limits, not a list of proven production incidents.

## Persistence and access

- Single browser localStorage only. No authentication, tenant separation, server authorization, shared sync, concurrency control, or durable immutable audit.
- “Published” prevents some UI edits but can be bypassed by modifying local data; it is not a security control.
- Current undo can restore earlier publication states. There is no audited role/approval model.
- JSON backup restore replaces state and uses only partial shape validation. Further validation is needed for request dates/status/provider IDs, assignment IDs, actual calendar dates, periods/snapshots, rule upper bounds, payload size, and malformed stored state. Some strings/IDs restored from JSON flow into inline handlers. Treat imports as untrusted and eliminate injection paths rather than relying on sample data.
- localStorage quota/access failures are not handled gracefully.

## Scheduling semantics

- `max consecutive` counts consecutive assignment start dates, not every date touched by an overnight shift; define intended rule before changing.
- Minimum rest is enforced even between same-day partial shifts. Splitting Clinic AM/PM therefore cannot work for one provider with the default 12h rest. Define same-duty-session rules rather than silently bypassing rest.
- Monthly maximum counts assignments, not hours/FTE, regardless of duration. Target is a soft count, not a contractual minimum.
- Shift hours are configured globally; changes affect historical assignments and reported duration. Published references block some changes, but full effective-dated templates/snapshots are missing.
- Coverage is a single per-type count applied every day to both departments; no weekdays/date overrides or department-specific coverage.
- No maximum coverage/capacity guard against overstaffing. Extra assignments are permitted.
- Inactive shift types stop new selection but existing assignments remain. Published-template deactivation/history semantics need careful review.
- No timezone per organization; interval logic uses browser-local time. DST and cross-zone behavior need explicit design/tests.
- Greedy generation may leave gaps when a feasible solution exists. Distinguish 'not filled by this algorithm' from 'proven infeasible'.
- Existing conflicts are flagged, but manual edits check primarily the edited assignment. Revalidate affected neighboring assignments and boundary dates after any change, especially consecutive-run extension.

## UI and reporting

- Month/week use full-month summary counts. Provider filter changes visible assignments but does not scope coverage metrics. Explain or align scopes deliberately.
- Reports show global provider totals while department summaries/export use their own scope; make scope clear.
- Multi-organization display and edit/generate/publish target are separate. A target can remain selected while hidden; labels are explicit but the workflow can be improved.
- Native HTML drag/drop lacks a complete mobile/touch experience. Keyboard editing exists via form; test accessibility thoroughly.
- Assignment modal Save availability is initialized against a period's publication status; changing dates may need to refresh it. Domain `canEdit()` remains a final gate.
- Schedule initial cursor is November 2026, not current month. Original user work should not disappear when that is changed.
- Inline handlers/large one-line functions make maintenance harder. Refactor incrementally with regression coverage.

## Roadmap, not implemented

Multiuser backend, roles, invitations, configurable organizations/departments, affiliation-level rules, time-off self-service security, swaps, exception approvals, credentials/privileges, holiday rules, notifications, schedule archive/version comparison, secure integrations, robust optimizer. Production readiness requires more than styling or passing the current checks.
