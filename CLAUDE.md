# CountSchedula project instructions

Read `README.md`, `docs/REQUIREMENTS.md`, `docs/ARCHITECTURE.md`, `docs/KNOWN-GAPS.md`, and `docs/ACCEPTANCE.md` before changing functionality.

## Product and scope

CountSchedula is a constraint-aware inpatient OB provider scheduling SaaS in development. Primary users are CNMs, schedulers, and department leads. Providers may work across organizations and departments. Current implementation is a browser-local pilot.

Brand: CountSchedula. Tagline: “Because staff scheduling doesn't have to suck the life out of you!” Workspace: Vanderbilt Midwives. Organizations: Jones Team and Boehm Team. Jones Team is the initial display selection. Do not restore the former Willow/Riverside labels in user-facing UI.

## Work rules

- Start from the working code; do not replace it with a new mockup or rewrite just for style.
- Run `npm test` before and after a change. Start locally with `npm start`.
- Preserve existing browser data and backup compatibility. Add versioned migrations for data changes.
- Internal IDs `willow` and `river` are legacy stable IDs. They now identify Jones Team and Boehm Team. Renaming IDs without a full migration would lose affiliations, assignments, selections, and period locks.
- Keep organization display selection distinct from the target of generation and publication.
- Validate assignments across all organizations even when an organization is hidden.
- Validate every mutation path, including drag/drop, forms, generation, restoration, provider edits, and rule/type edits. Ultimately enforce these checks server-side.
- Never silently relax hard constraints or invent staffing to make coverage look complete. Explain conflicts and unfilled shifts.
- Use real shift start/end times and overnight dates; do not assume every shift lasts 12 hours.
- Preserve responsive sidebar auto-close after navigation, outside-click dismissal, close button, and Escape.
- Retain keyboard alternatives to drag/drop; improve touch support as needed.
- Distinguish implemented behavior from roadmap items. Do not describe the pilot as hospital-grade or production-ready.
- Keep credentials out of source and commits. Do not deploy or change public access unless requested.
- Make focused changes and report the behavior changed, checks run, and remaining limitations.

No production stack has been selected. Discuss material framework/backend/deployment decisions before committing to a rewrite or paid service. Local reversible improvements within a requested task do not need repeated approval.
