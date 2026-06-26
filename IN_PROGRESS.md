# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

- [ ] `feat` `/setup-project` detects a missing branch-protection rule (no required approving reviews → empty `reviewDecision` → auto-merge guardrail #2 holds forever) and offers an atelier-executable autonomous fix `#31` `~3h` — [detail](roadmap/TASK_031_setup-detect-branch-protection.md)
