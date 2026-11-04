# CountSchedula — Claude Code handoff

**Because staff scheduling doesn't have to suck the life out of you!**

This is the working application source, not screenshots or a rebuild brief. It runs independently of ChatGPT Sites. Current workspace: **Vanderbilt Midwives**, with **Jones Team** (default) and **Boehm Team**.

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

## Current boundary

This is a functioning **single-browser pilot**, not a production clinical scheduling service. No backend, user authentication, multiuser sync, permission enforcement, server audit retention, or globally optimal solver exists yet. “Published” locks are UI/local-data controls. The generation algorithm is deterministic greedy selection and may leave avoidable gaps. See the known-gaps document before real operational use.

The original hosted app is not changed or removed by this handoff. Deploying this copy elsewhere is a separate step.
