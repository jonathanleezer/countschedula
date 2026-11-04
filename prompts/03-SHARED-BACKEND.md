Move CountSchedula toward a genuinely shared application. Read CLAUDE.md and docs/. Keep the current app running and preserve its visual design and functionality.

First produce a concrete recommended architecture and migration plan covering: framework/runtime, database, authentication, workspace/organization/department/provider/affiliation model, least-privilege roles, global availability conflict checks without leaking other organizations' private details, transactional assignment validation, optimistic concurrency, immutable publication versions, retained audit records, backups, and import of browser-local data. Separate confirmed requirements from decisions. Present exact hosting costs only after verifying current official sources.

Before a material framework rewrite, paid service, or production deployment, resolve the concrete architecture choices with me. Meanwhile implement stack-independent domain/schema tests and migration validation locally where useful.

After architecture is agreed, implement in runnable vertical slices:
1. Local database + migrations + idempotent synthetic seed; preserve stable provider/department IDs.
2. Server-side CRUD and authoritative cross-organization validation with transaction/concurrency tests.
3. Authentication and workspace/organization roles; prove isolation and least-privilege access.
4. One-time, previewable JSON import preserving assignments, affiliations, PTO, shift types, period snapshots, and audit; avoid duplicate imports and offer rollback.
5. Wire existing UI to shared state, including conflict feedback and stale-edit handling.
6. Durable publication/version history, backup/restore, operational checks, and release documentation.

Do not claim hospital-grade readiness based solely on CRUD or a green unit-test suite. Do not deploy or change public access until explicitly requested.
