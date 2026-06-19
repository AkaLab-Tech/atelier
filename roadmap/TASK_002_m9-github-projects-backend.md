# TASK_002 — M9 — External task-manager backends: GitHub Projects (replace local ROADMAP / IN_PROGRESS / HISTORY)

**Requested 2026-06-13.** Let a project track its tasks in an external manager instead of the local `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` files, **starting with GitHub Projects**. The backend is chosen when a project is set up, and the operator can **switch between backends at any time** in either direction.

**This builds on an existing foundation — it does not start from zero:**

- `claude-roadmap-tools` already ships a multi-backend architecture (its `TASK_001`, closed): a `.roadmap.json` (`backend: files|linear`), a `RoadmapBackend` interface (`listTasks` / `getTask` / `addTask` / `moveTask` / `appendHistoryEntry` / `isAvailable` — see `docs/RoadmapBackend.md`), `FilesBackend` + `LinearBackend`, and `/create-roadmap --backend` / `/migrate-roadmap --to`. **GitHub Projects becomes a third backend in that same contract** — the design doc already lists GitHub Issues / Jira / Trello as future backends to add once one is prioritized.
- atelier's `next-task` already frames its backlog source + claim registry as a pluggable **task provider** ([next-task.md](commands/next-task.md) §2), explicitly "Linear-ready".

**Two repos, two layers:**

1. **`claude-roadmap-tools` — the backend.** Implement `GitHubProjectBackend` against the existing `RoadmapBackend` contract; extend `/create-roadmap --backend github-project` and `/migrate-roadmap --to github-project`; teach `roadmap-tracking-flow` to route to it. Mirror the Linear shape (status mapping, optional offline mirror, `backend` + `backendId` frontmatter).
2. **atelier — the integration.**
   - **`setup-project`**: offer the backend choice during setup (today it only writes the `files` layout), delegating to `/create-roadmap --backend …`.
   - **the task provider (the deep part)**: `next-task` / `task-discovery` today read the backlog from `origin/<base>:ROADMAP.md` and use open `task/*` PRs as the claim registry — **git, not the `RoadmapBackend`**. For an external backend to genuinely *replace* the files in the autonomous cycle, the provider must discover the next task, honor the planning gate, and move `ROADMAP → IN_PROGRESS → HISTORY` against the backend. **This is not wired even for the existing Linear backend**, so M9 closes that gap generally, with GitHub Projects as the first remote provider exercised in atelier's cycle.

**Decided (2026-06-13):**

- **Target = GitHub Projects v2** (GraphQL API, custom Status field), not raw Issues + labels. Status maps to the three buckets the way Linear's `stateMap` does.
- **Auth via a GitHub MCP** (OAuth), mirroring the `LinearBackend` pattern — not `gh`. (Confirm the GitHub hosted-MCP endpoint/registration, analogous to `claude mcp add … https://mcp.linear.app/mcp`.)
- **Sequence: wire the abstraction first.** First connect atelier's task provider to crt's `RoadmapBackend` (today bypassed — `next-task`/`task-discovery` read `origin/<base>:ROADMAP.md` directly) so that *any* non-files backend — Linear included — drives the autonomous cycle; **then** land `GitHubProjectBackend` on top. This makes the GitHub work the second consumer of a now-real abstraction rather than a one-off.

**Resolved in planning — full design in [PLAN.md §16](PLAN.md):**

- **Coupling** — atelier aligns to crt's `RoadmapBackend` contract (consumer), not a duplicate provider (§16.1).
- **Field mapping** — Projects v2 Status → buckets via `stateMap`; `#id`/type/estimate as custom fields; `[ready]` as a dedicated `Ready` field; `blocked_by` as text (§16.3).
- **Claim registry** — open `task/*` PRs stay the claim unit; the Project is backlog + state (§16.4).
- **Planning gate** — `.plan/<id>.md` stays a tracked repo file; `[ready]` becomes the Project `Ready` field; approval interactive-only (§16.5).
- **Two-way migration** — `files ↔ github-project` both ways, with a generalized `backend → files` reverse path (also unlocks `linear → files`) (§16.6).
- **Workspaces** — one backend per repo in v1; cross-repo `blocked_by` reads the sibling's state through its backend (§16.7).

**Sub-phases (§16.8):** 9.1 wire the task provider to `RoadmapBackend` (keystone; validates with Linear) → 9.2 `GitHubProjectBackend` in crt → 9.3 `setup-project` selection + `next-task` + planning gate on Projects → 9.4 two-way migration → 9.5 workspaces + e2e.

---

## Sliced into sub-tasks (2026-06-19)

This epic is decomposed into independently-shippable sub-tasks; build in order, 9.1 first (it validates the abstraction with Linear before any GitHub work):

- [TASK_018 — M9.1 wire task provider to RoadmapBackend (keystone)](TASK_018_m9-1-wire-task-provider-backend.md)
- [TASK_019 — M9.2 GitHubProjectBackend in claude-roadmap-tools](TASK_019_m9-2-github-project-backend.md)
- [TASK_020 — M9.3 setup-project selection + next-task + planning gate on Projects](TASK_020_m9-3-setup-nexttask-on-projects.md)
- [TASK_021 — M9.4 two-way migration files ↔ github-project](TASK_021_m9-4-two-way-migration.md)
- [TASK_022 — M9.5 workspaces + e2e](TASK_022_m9-5-workspaces-e2e.md)
