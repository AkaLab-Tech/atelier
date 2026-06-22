# TASK_020 — Epic: M9.3 — setup-project backend selection + next-task + planning gate on Projects

**Sub-task of [TASK_002 / M9](TASK_002_m9-github-projects-backend.md).** Extend the three atelier-side integration surfaces — setup, claim, and planning gate — so a `github-project`-backed repo is driven through `claude-roadmap-tools`' `RoadmapBackend` instead of local files. This **extends** the #18 keystone (backend-aware provider, M9.1) and the #19 deliverable (GitHubProjectBackend + `/create-roadmap --backend github-project`, M9.2); it does **not** rebuild them.

> **Where the work lands.** Unlike #19 (which lands in `claude-roadmap-tools`), this whole epic is **native to atelier-dev** — every sub-task PR opens against this repo. The deliverable is prose in atelier's command / script / skill markdown. The whole epic is `blocked_by:#18` (M9.1 keystone); each sub-task carries that block plus the intra-epic ordering.

**Why this split.** The three surfaces are independent commands/skills with no shared symbol: setup writes the backend choice, next-task reads/claims against it, plan-task gates on it. Splitting file-by-command keeps each PR one reviewable slice under atelier-dev's 200-line / 10-file budget, mirroring the #19 epic's file-by-file seams. #20b and #20c each only consume #20a's backend selection (the `.roadmap.json` `backend: github-project` state), so both depend on #20a but not on each other — they can land in parallel after it.

**Acceptance (epic-level, covered across the sub-tasks):** set up a `github-project`-backed project end-to-end; `next-task` claims the next `Ready` item from the Project; `/atelier:plan-task` sets the Project `Ready` field; the `ROADMAP→IN_PROGRESS→HISTORY` equivalent runs against the Project.

---

## #20a — setup-project backend selection

`blocked_by:#18` · introduces the backend choice the later slices read.

**Scope (in atelier-dev):**
- **`/atelier:setup-project`**: offer the backend choice during setup (today only writes the `files` layout), delegating to `/create-roadmap --backend <files|linear|github-project>`. **Never** re-implement the `.roadmap.json` write or the GitHub MCP registration — that logic is sovereign in `claude-roadmap-tools` (#19c). Headless keeps `files` as the safe default; a remote backend requires an interactive pick or an explicit flag (OAuth can't auto-resolve). Emit a new `atelier-backend=` marker line. Per PLAN.md §16.4.

**Files:** `commands/setup-project.md`, `scripts/atelier-setup-project`.

**Acceptance:** running `/atelier:setup-project` interactively offers `files | linear | github-project`; choosing a non-`files` backend delegates to `/create-roadmap --backend <choice>` (no inline `.roadmap.json` write, no inline MCP registration); a headless / non-interactive run defaults to `files` unless an explicit backend flag is passed; the helper emits an `atelier-backend=<choice>` marker line that the command surfaces.

## #20b — next-task / task-discovery read + claim against the Project

`blocked_by:#18,#20a` · drives discovery + claim through the Project backend.

**Scope (in atelier-dev):**
- **`/atelier:next-task`** operates on the Project for a `github-project` repo: confirm and tighten the already-merged backend routing (`commands/next-task.md` §2/§3/§6 + `skills/task-discovery/SKILL.md` "Backend-aware backlog source") so a `github-project` repo concretely drives `listTasks` / `getTask` / `moveTask` through `claude-roadmap-tools`' `RoadmapBackend`. The claim registry stays the open `task/*` PRs regardless of backend (§16.4).

**Files:** `commands/next-task.md`, `skills/task-discovery/SKILL.md`.

**Acceptance:** for a `github-project` repo, `/atelier:next-task` obtains the backlog via `listTasks("roadmap")`, selects with the same P0→P1→P2 / `blocked_by` / `[ready]` rules, enriches via `getTask(id)`, and records the claim via `moveTask(id, "roadmap", "in_progress")` — never editing local `ROADMAP.md` / `IN_PROGRESS.md`; the claim registry remains the open `task/*` PRs.

## #20c — plan-task planning gate: Project Ready field

`blocked_by:#18,#20a` · makes the planning gate backend-aware.

**Scope (in atelier-dev):**
- **`/atelier:plan-task`** + **planning gate** operate on the Project for a `github-project` repo: `commands/plan-task.md` is files-only today (flips `[ready]` by editing a `ROADMAP.md` line). Make it backend-aware: for `github-project`, flip the Project's `Ready` field via the backend on approval instead of editing a line, while `.plan/<id>.md` stays a committed tracked repo file (§16.5). The gate is satisfied iff `Ready` is set **and** `.plan/<id>.md` is committed. Approval stays interactive-only (OAuth can't auto-resolve; never auto-flip `[ready]`).

**Files:** `commands/plan-task.md`.

**Acceptance:** for a `github-project` repo, approving a plan in `/atelier:plan-task` sets the Project's `Ready` field via the `RoadmapBackend` instead of editing a `ROADMAP.md` line; `.plan/<id>.md` is still committed as a tracked repo file; the gate is satisfied only when both `Ready` is set and `.plan/<id>.md` is committed; the human-approval gate is unchanged (no auto-flip in headless / `--yes` / `ATELIER_AUTO`).
