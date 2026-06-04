# Coolify VPS integration — research spike (M4.22)

Status: completed 2026-06-04. Informs and is delivered alongside the M4.23
implementation. Auth and packaging decisions below were taken with the operator
during the M4.23 build.

> **Note on method.** The ecosystem inventory reflects known options as of the
> research date; it is not an exhaustive live crawl of every community
> marketplace. The API surface is documented from Coolify v4's published REST
> API. Exact endpoint shapes (notably `/deploy` and env bulk-update) should be
> validated against a live instance during first real use — see the open item
> at the end.

## 1. Ecosystem inventory

| Option | Type | Maintenance | Fit / gaps |
| --- | --- | --- | --- |
| Coolify v4 REST API (`/api/v1`) | First-party HTTP API | Maintained (core product) | Covers deploy, apps, status, logs, env CRUD, app provisioning, servers, projects, databases. The authoritative surface. |
| Community Coolify MCP servers | Third-party MCP | Young, varying maintenance | Typed tools, but unvetted; would hand a VPS-scoped token to an external server and expose every tool (incl. destructive) behind one wildcard. Fails atelier's dependency discipline (PLAN.md §4). |
| `coolify-cli` / community CLIs | Third-party CLI | Partial coverage | Extra binary to install + track; no clear advantage over calling the REST API directly. |
| Terraform provider | IaC | N/A | Wrong altitude for per-task deploy/log/env actions. |

**Conclusion:** the first-party REST API is the only complete, maintained, and
trust-appropriate surface. Third-party MCPs/CLIs add dependency and trust cost
without covering the use cases better.

## 2. API surface mapping

Base `https://<instance>/api/v1`; bearer token; JSON. Use cases → endpoints:

| Use case | Endpoint(s) |
| --- | --- |
| List apps + UUIDs | `GET /applications` |
| Status | `GET /applications/{uuid}` |
| Logs | `GET /applications/{uuid}/logs?lines=N` |
| Running deployments | `GET /deployments`, `GET /deployments/{uuid}` |
| Deploy from branch/commit | `GET /deploy?uuid={uuid}&force={bool}` |
| Env vars (CRUD / upsert) | `GET\|POST /applications/{uuid}/envs`, `PATCH /applications/{uuid}/envs/bulk` |
| Provision new app | `POST /applications/public` (also `/dockerfile`, `/private-github-app`) |
| Delete app | `DELETE /applications/{uuid}` |
| Instance health/version | `GET /health`, `GET /version` |
| Servers / projects | `GET /servers`, `GET /projects` |

Idempotency: reads are safe; `deploy` is effectively idempotent per commit
(re-deploying the same HEAD is a no-op build unless `force=true`); env bulk-patch
is upsert. Rate limits are not aggressive for an interactive operator cadence.

## 3. Auth flow design

**Decision: per-project `.env`** (not global). `COOLIFY_API_TOKEN` +
`COOLIFY_BASE_URL` live in each project's `.env`, kept out of version control by
atelier's `.env*` guardrail. The client reads only those two keys (real env
values win; unrelated vars never leak).

Rationale: supports one operator deploying multiple projects to different
Coolify instances — the multi-instance requirement settled in M4.23. A global
macOS-Keychain token was considered and rejected because it collapses to one
instance. Token scope: `read` + `deploy` + `write`; avoid `root`.

## 4. Recommendation

**Build a native thin client over the REST API, shipped as a separate optional
plugin** — `coolify-integration` ([AkaLab-Tech/coolify-integration](https://github.com/AkaLab-Tech/coolify-integration)),
listed in the `akalab-tech` catalog. Not bundled into atelier core, so atelier's
PLAN.md §11 "no deployment in core" boundary holds.

- **Surface:** a `coolify` skill + an `atelier-coolify` CLI (`curl`/`jq`).
  Commands split by risk: read-only + `deploy`/`set-env` are allowlisted;
  `create-app-public`/`delete-app` are gated (operator confirmation).
- **Permissions:** merged into atelier's user-level `settings.json`, never the
  per-task template — keeps the two plugins decoupled.
- **atelier touchpoints (M4.23):** an opt-in `install.sh` prompt and
  `/atelier:setup-coolify` (+ `atelier-setup-coolify`) install + configure it;
  `atelier-doctor` reports its status when installed.
- **Fallback option:** if a well-maintained first-party Coolify MCP appears
  later, revisit adopting it behind the same skill.

**Auto-merge guardrail:** Coolify actions are CLI side effects, not in-repo
changes, and auth lives in a gitignored `.env`; no new tracked deployment-config
paths are introduced, so the never-auto-merge list (PLAN.md §6) needs no new
entry. Revisit if a future use case commits Coolify config into a project repo.

## Open item

Validate `GET /deploy?uuid=...` and `PATCH /applications/{uuid}/envs/bulk`
against a live Coolify v4 instance on first real use; adjust paths in
`coolify-integration/scripts/atelier-coolify` if they differ.
