# TASK_019 — Epic: M9.2 — GitHubProjectBackend in claude-roadmap-tools

**Sub-task of [TASK_002 / M9](TASK_002_m9-github-projects-backend.md).** Implement a third `RoadmapBackend` (`listTasks`/`getTask`/`addTask`/`moveTask`/`appendHistoryEntry`/`isAvailable`) against **GitHub Projects v2** (GraphQL, custom Status field), mirroring `LinearBackend`. Auth via a **GitHub MCP** (OAuth), not `gh` (confirm the hosted-MCP endpoint, analogous to `claude mcp add … https://mcp.linear.app/mcp`).

> **Where the work lands.** This task entry is *tracked* here in atelier-dev, but the *deliverable* lives in a different repo: **`claude-roadmap-tools`** (`/Users/mike/Work/work-setup/claude-roadmap-tools`), a 100%-markdown Claude Code plugin with **no compiled code** — "implementation" means prose instructions in skill / command / docs markdown files. Every sub-task PR below opens against `claude-roadmap-tools`, **not** atelier-dev. The whole epic is `blocked_by:#18` (M9.1, the backend-aware provider keystone, in progress); each sub-task carries that block plus the intra-epic ordering.

> **Open question (record before starting).** The exact hosted **GitHub-MCP endpoint (OAuth)** is not yet confirmed. The Linear analogue is `claude mcp add --transport http linear-server https://mcp.linear.app/mcp`. The GitHub equivalent must be confirmed before #19a/#19c are implemented and **must NOT fall back to the `gh` CLI** — auth is MCP/OAuth only, mirroring Linear.

**Why this split.** The deliverable mirrors the existing `LinearBackend` file-by-file, so the natural seams are the same files Linear touches: the contract doc, the SKILL Operations section, the two commands + routing, and the offline mirror. The SKILL `## Operations (LinearBackend)` block alone is ~128 lines, so its GitHubProjectBackend mirror (#19b) must be its own PR; the command setup procedures (~37 + ~68 lines of Linear analogue) plus routing fill a second near-budget PR (#19c); the contract doc and the mirror parity are each comfortably their own slice. Each slice is independently shippable as one reviewable PR under atelier-dev's 200-line / 10-file budget (line count is the binding constraint for prose PRs).

**Acceptance (epic-level, covered across the sub-tasks):** a repo can be set to the `github-project` backend; tasks list / move / append-history via the Project; `.roadmap.json` records `backend: github-project`. Built on the 9.1 abstraction (second consumer, not a one-off).

---

## #19a — Contract groundwork: docs/RoadmapBackend.md + GitHub MCP isAvailable pattern

`blocked_by:#18` · pins down the design the later slices implement.

**Scope (in `claude-roadmap-tools`):**
- `GitHubProjectBackend`: Projects v2 GraphQL; Status field ↔ the three buckets via `stateMap` (like Linear); `#id`/type/estimate as custom fields; `[ready]` as a dedicated `Ready` field; `blocked_by` as text (§16.3).

**Files:** `docs/RoadmapBackend.md`.

**Acceptance:** the contract doc gains a `GitHubProjectBackend` Identity-table row, a `GitHubProjectBackend` column in the Buckets table, and a new `### GitHubProjectBackend` per-backend-notes subsection (mirroring the `### LinearBackend` notes) covering: the Projects v2 GraphQL surface, the Status-field `stateMap`, custom fields for `#id`/type/estimate, the dedicated `Ready` field, `blocked_by`-as-text, the GitHub-MCP (OAuth) auth requirement, and the `isAvailable()` MCP-registration check pattern (host/name match, no API call — analogous to LinearBackend's `mcp.linear.app` check). Records the open question on the exact GitHub-MCP endpoint.

## #19b — Core operations: Operations (GitHubProjectBackend) section in SKILL.md

`blocked_by:#19a` · the 6-operation contract realized against Projects v2.

**Scope (in `claude-roadmap-tools`):**
- A new `## Operations (GitHubProjectBackend)` section in `skills/roadmap-tracking-flow/SKILL.md` mirroring `## Operations (LinearBackend)`: `listTasks` / `getTask` / `addTask` / `moveTask` / `appendHistoryEntry` / `isAvailable`, each against Projects v2 GraphQL with the snake_case-bucket ↔ camelCase-`stateMap`-key translation the contract mandates.

**Files:** `skills/roadmap-tracking-flow/SKILL.md`.

**Acceptance:** all six operations are documented for the GitHubProjectBackend with the same Inputs / Returns / Side effects / Errors / per-backend-notes shape as the LinearBackend section, including atomicity notes for `moveTask` / `appendHistoryEntry` and the stable error names. No routing/activation edits here — those are #19c.

## #19c — Command extensions + routing: /create-roadmap + /migrate-roadmap + activation

`blocked_by:#19b` · wires the new backend into setup, migration, and skill activation.

**Scope (in `claude-roadmap-tools`):**
- Extend `/create-roadmap --backend github-project` and `/migrate-roadmap --to github-project` (setup procedure + GitHub-MCP registration pattern + the `github-project` `.roadmap.json` template, mirroring the `linear` blocks).
- Teach `roadmap-tracking-flow` SKILL.md activation/routing to detect `backend: github-project` and route to the new `## Operations (GitHubProjectBackend)` section.

**Files:** `commands/create-roadmap.md`, `commands/migrate-roadmap.md`, `skills/roadmap-tracking-flow/SKILL.md` (activation/routing + direction matrix only).

**Acceptance:** `/create-roadmap --backend github-project` writes `backend: github-project` into `.roadmap.json` and registers the GitHub MCP (OAuth, never `gh`); `/migrate-roadmap --to github-project` is added to the direction matrix and pushes tasks to a Project; the SKILL activation section routes a `github-project` repo to the GitHubProjectBackend operations.

## #19d — Optional offline mirror + backend/backendId frontmatter parity

`blocked_by:#19b` · brings the GitHub backend to mirror parity with Linear.

**Scope (in `claude-roadmap-tools`):**
- Optional offline mirror + `backend`/`backendId` frontmatter for `github-project`, mirroring Linear: mirror auto-refresh on activation, `offlineMirror` toggle, and coherence-by-`backendId`.

**Files:** `skills/roadmap-tracking-flow/SKILL.md` (mirror auto-refresh), `docs/RoadmapBackend.md` (mirror notes in the `### GitHubProjectBackend` subsection), `commands/*` (mirror toggle wiring as needed).

**Acceptance:** with `offlineMirror: true` and `backend: github-project`, the skill maintains local `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` / `roadmap/` as a read-only mirror refreshed on activation; task files carry `backend: github-project` + `backendId: <project-item-id>` frontmatter, with the same coherence-by-`backendId` guarantees Linear has.

> **Note on this sub-task.** Marked "Optional" in the original scope — it can ship after #19c if the epic needs to close earlier, but it shares no merge dependency with #19c (both depend only on #19b), so it can also land in parallel with #19c.
