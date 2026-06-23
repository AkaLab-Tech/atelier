# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

- [ ] [ready] `feat` M9.5b Mixed-backend workspace status aggregation in `atelier-workspace-status` `#22b` `~2h` `blocked_by:#22a` — [detail](roadmap/TASK_022_m9-5-workspaces-e2e.md)
  - Ensure member rows + the cross-repo-blocked section render correctly when members mix backends (it calls `atelier-resolve-dep` per blocker, which #22a makes backend-aware). Verify the open-count / in-progress / roadmap-format columns degrade sanely for non-`files` members and document the mixed-backend behaviour. Covers the "aggregates status" half of the parent acceptance. Per PLAN.md §16.7.
