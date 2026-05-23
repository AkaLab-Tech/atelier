# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M4.17 — `docker-env` skill + `docker-runner` agent (on-demand local containers)

Sonnet agent + skill for on-demand Docker container management during task execution. The agent scaffolds `Dockerfile`/`docker-compose.yml`; the skill drives lifecycle (`up`/`down`/`logs`/`ps`) scoped to the task worktree. Daily-work productivity tool — useful when a task needs to test against Postgres, Redis, or a similar service without contaminating the operator's machine.

- [ ] **`docker-runner` agent (Sonnet)** — authors `Dockerfile` and `docker-compose.yml`, pins base image tags, declares services / env / ports / healthchecks. Image choices follow [PLAN.md §4](PLAN.md) dep-install rules (justify in commit, prefer official images, avoid <7-day-old tags).
- [ ] **`docker-env` skill** — compose project name = `<task-id>-<slug>` so parallel tasks isolate networks/volumes; lifecycle commands `up`, `down`, `logs <service>`, `ps`. Auto-discovered and invoked by `implementer` when the task needs services.
- [ ] **Runtime detection** — probe `docker info` at first use; fail with a clear actionable message if no daemon is running. `install.sh` does **not** install Colima or Docker Desktop — the operator chooses and installs a runtime; the skill works against whichever daemon is reachable.
- [ ] **Permissions delta in `settings.template.json`** — `Edit(<worktree>/**/Dockerfile)` and `Edit(<worktree>/**/docker-compose*)` auto-allowed inside the task worktree; [PLAN.md §3](PLAN.md) "ask" remains for any path outside the worktree. [PLAN.md §6](PLAN.md) auto-merge block for Dockerfile / docker-compose* stays in force — PRs touching these files still fall back to human review.
- [ ] **`Stop` hook** — tears down the task's containers and removes named volumes prefixed with `<task-id>` on session end, so no orphans accumulate.

**Acceptance:** in a toy repo with no Docker config, a task that requires Postgres ends with the agent having generated `docker-compose.yml`, the skill having started the service, tests passing against it, and the `Stop` hook cleaning everything up — leaving no orphan containers, networks, or volumes. A PR touching `docker-compose.yml` still falls back to human review per PLAN.md §6.

**Trigger to revisit:** the first time a task needs to test against a containerized service and the operator would otherwise write Docker config by hand. Captured 2026-05-22 as a daily-work productivity tool that complements (not blocks) the core agent flow.

**Progress notes:** worktree `task/m4.17-docker-env` created 2026-05-23 from `7b8ef09` (post-#65 merge). MINOR bump (`0.2.0` → `0.3.0`) per PLAN.md §14.2 (new agent + new skill + new hook).
