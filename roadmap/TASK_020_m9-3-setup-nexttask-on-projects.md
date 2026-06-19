# TASK_020 — M9.3 — setup-project backend selection + next-task + planning gate on Projects

**Sub-task of [TASK_002 / M9](TASK_002_m9-github-projects-backend.md).**

**Scope:**
- **`/atelier:setup-project`**: offer the backend choice during setup (today only writes the `files` layout), delegating to `/create-roadmap --backend …`.
- **`/atelier:next-task`** + **planning gate** operate on the Project for a `github-project` repo: `Ready` field is the `[ready]` marker; `.plan/<id>.md` stays a tracked repo file (§16.5); approval interactive-only.

**Acceptance:** set up a `github-project`-backed project end-to-end; `next-task` claims the next `Ready` item from the Project; `/atelier:plan-task` sets the Project `Ready` field; the `ROADMAP→IN_PROGRESS→HISTORY` equivalent runs against the Project.
