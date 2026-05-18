# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

<!-- Single-file layout: paste the task block from ROADMAP.md here. -->
<!-- Indexed layout: link to roadmap/TASK_NNN_<slug>.md and write progress notes inside that file, not here. -->

### M1.4 — `settings.template.json`

Materialize the full allow / deny / ask matrix from [PLAN.md §3](PLAN.md) at `templates/settings.template.json`. **Static layer only** — content-validation hooks live in M2.4 (see PLAN.md §3 "Defense-in-depth" note added in this same PR). Per-task instantiation (worktree path substitution + `additionalDirectories`) is built in Phase 2 (M2.3 `/setup-project` and `/next-task`).

- [x] `defaultMode: acceptEdits`.
- [x] Allow list: `Read(<worktree>/**)`, `Glob`, `Grep`, `Edit(<worktree>/**)`, `Write(<worktree>/**)`, git read/write, `git push origin task/*` only, `gh` subset, `pnpm` subset, test/lint/type tooling, basic filesystem (ls/mkdir/mv/cp).
- [x] Deny list (absolute): rm -rf, sudo, force-push, push to protected branches, `git reset --hard*`, global git config, `gh auth logout/refresh`, `gh repo delete`, `gh api -X POST/PATCH/DELETE`, publish commands, curl/wget piped to sh, secret-dir reads (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`), shellrc/ssh edits, `.github/workflows/**`, `package.json`, `pnpm-lock.yaml`.
- [x] Ask list: `Edit(./.env*)`, `Edit(./Dockerfile)`, `Edit(./docker-compose*)`, `Bash(gh pr close*)`.
- [x] Doc updates landed alongside the template in this PR: PLAN.md §3 gains a "Defense-in-depth" note that names this matrix as the static layer and M2.4 hooks as the dynamic layer; ROADMAP.md M2.4 expanded with three new content-scanning hooks (`scan-edit-write`, `scan-git-add`, `safe-package-change`) plus a pre-implementation note requiring a threat-model addendum before any matcher code lands.

**Acceptance:** the template parses as valid JSON, every entry from PLAN.md §3 is present, and a sample per-task instantiation (manual for now — `sed s|<worktree>|/some/path|g`) still parses as valid JSON.

**Branch (current sub-PR):** `setup/m1.4-settings-template` — single-sub-PR milestone; closes M1.4 by moving this block to `HISTORY.md` in an atomic follow-up commit on this same branch.
