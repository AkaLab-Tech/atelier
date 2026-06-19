# TASK_018 — M9.1 — Wire atelier's task provider to crt's RoadmapBackend (keystone)

**Sub-task of [TASK_002 / M9](TASK_002_m9-github-projects-backend.md).** Today `next-task` / `task-discovery` read the backlog from `origin/<base>:ROADMAP.md` and use open `task/*` PRs as the claim registry — **git/files, hardcoded**, bypassing crt's `RoadmapBackend` contract. Make the provider **backend-aware** so *any* non-files backend (Linear today, GitHub Projects in 9.2) drives the autonomous cycle.

**Scope:**
- Resolve a project's backend from `.roadmap.json` (`backend: files|linear|github-project`; absent ⇒ `files`). Ship a small, testable resolver helper (`atelier-task-backend <project>`).
- Route the backlog read + the `ROADMAP → IN_PROGRESS → HISTORY` moves through the `RoadmapBackend` contract (`listTasks`/`getTask`/`moveTask`/`appendHistoryEntry`) instead of reading the files directly. `files` backend = current behavior (no regression); non-files = consult the backend.
- Keep the claim registry as open `task/*` PRs (§16.4) regardless of backend.
- **Validate with the existing Linear backend** — a Linear-backed project's backlog is discovered + moved via the backend, proving the abstraction before 9.2.

**Acceptance:** a `files` project behaves exactly as today; a `linear`-backed project has its next task discovered and its `ROADMAP→IN_PROGRESS→HISTORY` transitions driven through the backend, not the local files. `atelier-task-backend` resolves the backend per `.roadmap.json` (default `files`); hermetic test.

**First deliverable (this slice):** the `atelier-task-backend` resolver + test; the `next-task.md` / `task-discovery` prose updated to resolve and branch on it (files vs backend). The full Linear-path read logic in the command prose lands as the resolver is consumed.

## Progress
- **2026-06-19:** shipped `scripts/atelier-task-backend` (resolves backend from `.roadmap.json`, default `files`; hermetic test) + the `next-task.md` §2 routing hook (resolve backend → `files` = git-backed flow, non-`files` = drive `RoadmapBackend`). **Remaining:** the non-`files` read/move path in the provider prose, validated against the Linear backend (then 9.2 layers GitHubProjectBackend on top).
