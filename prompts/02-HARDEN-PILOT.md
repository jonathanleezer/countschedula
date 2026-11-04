Harden the existing CountSchedula pilot while preserving its UI and backup compatibility. Read CLAUDE.md and all docs first; run the baseline tests.

Work through these in order with focused regression tests:
1. Validate stored/imported state completely and show recoverable errors for malformed data and storage failures. Remove unsafe interpolation of imported values into HTML/event handlers; preserve legacy backup migration.
2. Centralize assignment validation so forms, dragging, generation, provider/rule/type edits, and imports apply consistent global constraints. Validate all affected assignments, including adjacent dates/months and overnight PTO.
3. Make calendar filter/report scopes explicit, and keep organization display selection independent of mutation targets. Verify that edits to Boehm never accidentally become Jones edits.
4. Fix proven publication/undo/modal-state bugs without inventing a new exception policy. Preserve published histories and identify domain decisions requiring owner input.
5. Add browser-level tests for multi-organization editing, drag/drop, form alternatives, mobile navigation, persistence, and restoration. Improve touch/keyboard handling where needed.

Keep the working app runnable after each step. Refactor into modules only where it helps the changes and maintain meaningful tests. Do not silently change rest, consecutive-shift, monthly accounting, or timezone policies; document unresolved policy choices. Finish with evidence of checks and a concise list of remaining issues. Do not deploy.
