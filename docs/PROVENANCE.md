# Source provenance

Prepared 2026-11-04 from the current CountSchedula Sites repository.

- Latest published Site version observed: 5.
- Verified source commit: `fabc1ba86604e5bbef66cc824fcf82f822a514b6`.
- Hosted reference: https://countschedula.jonlzr.chatgpt.site
- `dist/` and original `check*.cjs` are copied from that commit without app behavior changes.
- Handoff documentation, sample JSON, package scripts, local server, and test runner are portable additions.
- `.git`, repository authentication, `.openai` hosting configuration, deployment archives, credentials, and unrelated user information are excluded.
- Existing browser edits are not accessible from repository source and are not represented by sample JSON. Export them separately through the hosted app's Settings.

The original hosted app remains unchanged. This package does not transfer domain ownership, hosting access, or account credentials. Its files can run on an ordinary static host once a deployment target is chosen.

## 2026-11-04 shared backend

Imported into GitHub `jonathanleezer/countschedula` (commit `e4489c4`, unmodified handoff). Later commits add the Supabase backend, `dist/cloud.js`, restore hardening, tests, and Vercel config. `dist/vendor/supabase-2.117.3.js` is the unmodified UMD build of `@supabase/supabase-js` 2.117.3 (MIT, license alongside), sha256 `d6a5c4414a5d4ce646d9c1de223aa7067d3ff664c15394ffeb7fcffc763354a3`. `MANIFEST.sha256.json` describes the original handoff only.
