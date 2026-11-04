# CountSchedula

**Because staff scheduling doesn't have to suck the life out of you!**

Shared scheduling for **Vanderbilt Midwives** — **Jones Team** (default) and **Boehm Team**.

- **Live app:** https://countschedula.vercel.app (invite-only sign-in by email link)
- **Backend:** Supabase project `countschedula` (us-east-1) — see `docs/OPERATIONS.md`
- **Local pilot mode:** `npm start` without Supabase settings runs the original browser-only app.

## Develop

```sh
npm test            # domain checks (Node VM)
npm run test:db     # migrations + server rules on a throwaway local PostgreSQL
npm run test:browser  # Playwright acceptance checks (local mode)
npm start           # http://localhost:3000
```

To run locally against the shared backend: `SUPABASE_URL=https://<ref>.supabase.co SUPABASE_PUBLISHABLE_KEY=sb_publishable_… npm start` (localhost:3000 is an allowed sign-in redirect).

## Original handoff notes

## Start here

1. Extract this entire folder onto your computer.
2. Open a terminal in the extracted `countschedula` folder.
3. With Node.js 22 or later installed, run:

   ```sh
   npm test
   npm start
   ```

4. Open http://localhost:3000 in your browser.
5. Open this folder in Claude Code using your normal workflow. Paste the contents of `prompts/01-TAKEOVER.md` as the first message.

No package installation, API key, cloud account, or database is needed for this pilot. `npm` ships with Node.js. These commands work in PowerShell, Command Prompt, macOS, and Linux terminals. This package does not install Claude Code; use your existing installation/setup.

## What to give Claude Code

Keep the **whole folder** available to it. `CLAUDE.md` supplies project instructions automatically where supported. The prompts directory contains ordered tasks:

- `01-TAKEOVER.md`: run and verify the existing app; preserve behavior.
- `02-HARDEN-PILOT.md`: address actual pilot limitations with regression tests.
- `03-SHARED-BACKEND.md`: plan and build shared persistence, access control, and migration in stages.
- `04-NEXT-FEATURE.md`: reusable feature request template.

Use one prompt at a time. The later prompts are optional next steps, not claims that those features exist.

## Bring your existing data

The hosted app stores data in **your browser**, not the source repository. To transfer it:

1. Open https://countschedula.jonlzr.chatgpt.site in the browser/device where you used it.
2. Go to Settings → Download backup.
3. Start this local app, then Settings → Restore backup and select that JSON file.
4. Verify providers, PTO, shift types, assignments, and publication states before editing.

Restore replaces the local browser's workspace. Export a backup first if that local app already contains work you need. If downloads were saved with browser-added filename suffixes, the JSON contents still work.

A new origin, hostname, port, browser, or profile has a separate localStorage store. The package includes only generated sample data. It does not contain your browser's saved edits, credentials, Git authentication, or hosting bindings. Selection of displayed organizations resets to Jones Team on reload; this is current behavior.

## Folder map

| File | Purpose |
|---|---|
| `dist/index.html` | App shell and Vanderbilt Midwives workspace label |
| `dist/style.css` | Responsive UI, sidebar, calendar, organization lanes |
| `dist/app.js` | State, views, constraints, generation, drag/drop, exports, migrations |
| `check*.cjs` | Existing Node VM regression checks |
| `scripts/serve.cjs` | Dependency-free local static server, loopback only |
| `scripts/test.cjs` | Syntax and regression runner |
| `sample-data/sample-workspace.json` | Synthetic starter state, not user data |
| `docs/REQUIREMENTS.md` | Requirements and decisions |
| `docs/ARCHITECTURE.md` | Data model, source map, execution behavior |
| `docs/KNOWN-GAPS.md` | Limits and code-review findings to investigate |
| `docs/ACCEPTANCE.md` | Manual and automated acceptance checklist |
| `docs/PROVENANCE.md` | Source commit, scope, and verification |
| `docs/OPERATIONS.md` | Hosting, deploys, migrations, invites, email, backups, recovery |
| `dist/cloud.js` | Shared-workspace client: sign-in, load/save, members, snapshots |
| `supabase/migrations/` | Database schema, RLS, server rules, roles |
| `supabase/tests/` | Database tests run by `npm run test:db` |
| `scripts/build.cjs`, `vercel.json` | Production build and security headers |

## Current boundary

The hosted app has shared storage, sign-in, roles, server-enforced rules and publication locks, and append-only history. It has not had an independent security review or clinical validation, runs on free plans without database backups, and the generator is greedy and may leave avoidable gaps. Read `docs/KNOWN-GAPS.md` before relying on it for staffing.

The original hosted app is not changed or removed by this handoff. Deploying this copy elsewhere is a separate step.
