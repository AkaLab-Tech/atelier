# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M5.1 + M5.2 + M5.3 — Multi-project foundation

`[feat]` · Source: PLAN.md §12 Phase 5; audit during M2.5→M7.1.F14 ship-path sweep (2026-05-26)

Audit during the ship-path sweep found M5.1 (project registry at `$ATELIER_CONFIG_DIR/projects.json`) and M5.2 (`/setup-project` writing the per-project layer: `.claude/settings.json`, `ROADMAP.md`, `.claude/CLAUDE.md`, `.npmrc`, `.gitignore`) were **already implemented incrementally** through earlier milestones (M2.3, M4.16, M4.19) but never formally closed in HISTORY. M5.3 (`task` alias resolves project from cwd) is the only deliverable that requires net-new code.

**Scope:**

- [ ] **G1 — schema** (M5.1): `step_record_setup` in `atelier-setup-project` writes a `name` field (basename of the project path) alongside the existing `setupCompleted` + `setupVersion`. Defer `lastTask` timestamp to a follow-up — no consumer needs it in v1.
- [ ] **G2 — cwd resolution + picker** (M5.3): new `scripts/atelier-task-resolve` binary. Algorithm: (1) if cwd is inside any registered project (longest-prefix match), print that path and exit 0; (2) else if there are registered projects, launch an `fzf` picker sorted by `setupCompleted` desc; (3) else surface a clear error pointing at `/atelier:setup-project`. Symlinked from `install.sh` like the other helpers. `task()` shell function in the install.sh heredoc rewritten to call this resolver before `cd`-ing into the project and invoking `claude /next-task`. Bump `current_version` (M7.1.F7c) so existing operators get the new `task()` on next `install.sh` re-run.
- [ ] **G3 — HISTORY** (M5.1 + M5.2 + M5.3): three entries documenting what was already in place + what landed here.

**Acceptance:**

- `jq '.projects | to_entries[] | .value | has("name")' $ATELIER_CONFIG_DIR/projects.json` returns `true` for every entry written by post-PR `atelier-setup-project`.
- Running `task` from inside a registered project's tree invokes `claude /next-task` against that project, regardless of which subdirectory the operator is in.
- Running `task` from a directory NOT inside any registered project launches an `fzf` picker with sorted entries; selecting one opens a Claude session for it; pressing Esc exits cleanly without invoking Claude.
- `bash -n scripts/atelier-task-resolve` and `bash -n install.sh` pass.

**Out of scope:**

- `lastTask` timestamp on registry entries — no consumer in v1; revisit when the picker needs to sort by recency rather than setupCompleted.
- A non-fzf fallback picker — install.sh installs fzf in Phase A, so absence is anomalous (the resolver surfaces a clear error rather than silently degrading).
