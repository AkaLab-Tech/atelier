# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

- `feat` M9.5c End-to-end validation on a real `github-project`-backed member + mixed-backend workspace `#22c` `~3h` `blocked_by:#22b` — [detail](roadmap/TASK_022_m9-5-workspaces-e2e.md) — branch `task/22c-e2e-workspaces-backends`
  - **Closes M9** (epic `#22`, final slice). Docs-only deliverable: a manual-e2e runbook + a validation findings log (results marked "pending live run" — the live OAuth/MCP pass is the operator's). The closing-of-M9 bookkeeping (epic `#22` → `HISTORY.md`) lands in this same PR.
