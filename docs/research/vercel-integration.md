# Vercel integration — research + decision (M4.27)

Status: completed 2026-06-05, delivered with the M4.27 implementation. Same
shape as the Coolify spike ([coolify-integration.md](coolify-integration.md)):
a brief ecosystem/surface assessment that informs the build.

## 1. Ecosystem inventory

| Option | Type | Maintenance | Fit |
| --- | --- | --- | --- |
| Vercel CLI (`vercel`) | First-party CLI | Actively maintained | Complete: deploy (preview/prod), ls, inspect, logs, env, link, redeploy, rollback, promote, rm. Token auth via `VERCEL_TOKEN`. **Chosen.** |
| Vercel MCP (`mcp.vercel.com`) | First-party MCP | Maintained | Typed tools, but hosted-MCP OAuth + a permission wildcard to deny-list. Heavier than wrapping the CLI for the per-project `.env` model. Fallback. |
| Vercel REST API (`api.vercel.com`) | First-party HTTP | Maintained | Full control but reinvents what the CLI already does. Rejected. |

Unlike Coolify (community MCPs were young), Vercel ships mature first-party
tooling, so per atelier's dependency discipline we wrap rather than hand-roll.

## 2. CLI surface mapping (verified against `vercel --help`)

| Use case | `vercel` command | atelier-vercel |
| --- | --- | --- |
| Preview deploy | `deploy [path]` | `deploy` |
| Production deploy | `deploy --prod` | `deploy-prod` |
| List deployments | `ls [app]` | `list` |
| Deployment details | `inspect <id>` | `inspect` |
| Logs | `logs <url>` | `logs` |
| Env vars | `env ls/add/rm` | `env-ls` / `env-add` / `env-rm` (gated) |
| Link project | `link` | `link` |
| Redeploy / rollback / promote | `redeploy` / `rollback` / `promote` | same |
| Delete deployment / project | `rm` / `project rm` | `remove` / `project-rm` (gated) |

## 3. Auth

Per-project `.env`: `VERCEL_TOKEN` (required), optional `VERCEL_ORG_ID` /
`VERCEL_PROJECT_ID` for a fixed non-interactive scope. The CLI reads these from
the environment; `atelier-vercel` loads only these keys from `.env` (gitignored
by atelier's `.env*` guardrail), real env wins, unrelated vars never leak.

## 4. Recommendation (implemented)

Wrap the official CLI in a thin `atelier-vercel`, shipped as the separate
optional plugin [`vercel-integration`](https://github.com/AkaLab-Tech/vercel-integration).
Read-only + safe writes (`deploy`, `deploy-prod`, `env-add`, `redeploy`,
`rollback`, `promote`, `link`, `pull`) are allowlisted; destructive ops
(`remove`, `env-rm`, `project-rm`) are gated. Permissions merge into atelier's
user-level settings, never the per-task template. The CLI uses an installed
`vercel` or falls back to `pnpm dlx vercel@latest` (no mandatory global install).

**Auto-merge guardrail:** Vercel actions are CLI side effects, not in-repo
changes; no new tracked deployment-config paths, so the never-auto-merge list is
unchanged.
