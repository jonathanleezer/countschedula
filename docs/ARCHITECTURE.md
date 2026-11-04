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
