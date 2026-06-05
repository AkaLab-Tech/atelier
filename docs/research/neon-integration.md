# Neon integration — research + decision (M4.28)

Status: completed 2026-06-05, delivered with the M4.28 implementation. Same
shape as the Coolify spike ([coolify-integration.md](coolify-integration.md)).

## 1. Ecosystem inventory

| Option | Type | Maintenance | Fit |
| --- | --- | --- | --- |
| Neon CLI (`neonctl`) | First-party CLI | Actively maintained | Complete for management: me, projects, branches, databases, roles, operations, connection-string. API-key auth via `NEON_API_KEY`. **Chosen.** |
| Neon MCP (`mcp.neon.tech` / npm) | First-party MCP | Maintained | Strong for in-session SQL; hosted-MCP OAuth + permission wildcard. Fallback, especially if running SQL from the agent becomes a need. |
| Neon REST API (`console.neon.tech/api/v2`) | First-party HTTP | Maintained | Reinvents the CLI. Rejected. |

## 2. CLI surface mapping (verified against `neonctl --help`)

| Use case | `neonctl` command | atelier-neon |
| --- | --- | --- |
| Current user | `me` | `me` |
| List projects / branches / dbs / roles | `projects/branches/databases/roles list` | `projects` / `branches` / `databases` / `roles` |
| Recent operations | `operations list` | `operations` |
| Connection string | `connection-string [branch]` | `connstr` |
| Create branch | `branches create` | `branch-create` |
| Delete branch | `branches delete` | `branch-delete` (gated) |
| Create / delete project | `projects create/delete` | `project-create` / `project-delete` (gated) |

Scoping: when `NEON_PROJECT_ID` is set, `atelier-neon` injects `--project-id`
into scoped commands automatically.

## 3. Auth

Per-project `.env`: `NEON_API_KEY` (required), optional `NEON_PROJECT_ID` to
scope to one project. `atelier-neon` loads only these keys (gitignored), real
env wins, unrelated vars never leak.

## 4. Recommendation (implemented)

Wrap the official CLI in a thin `atelier-neon`, shipped as the separate optional
plugin [`neon-integration`](https://github.com/AkaLab-Tech/neon-integration).
Read-only ops + `branch-create` are allowlisted; destructive ops
(`branch-delete`, `project-create`, `project-delete`) are gated. Permissions
merge into atelier's user-level settings, never the per-task template. The CLI
uses an installed `neonctl` or falls back to `pnpm dlx neonctl@latest`.

**Branch-per-task** is the natural fit: create a Neon branch for a task's work,
get its connection string, run migrations/tests against it, delete on merge.

**Auto-merge guardrail:** Neon actions are CLI side effects, not in-repo
changes; `connection-string` output (live DB credentials) must never be written
to a tracked file — only to the gitignored `.env`. No new tracked paths, so the
never-auto-merge list is unchanged.
