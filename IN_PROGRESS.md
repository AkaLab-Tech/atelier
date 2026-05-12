# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M1.1 — Repo skeleton

Create the directory layout the rest of the plan assumes: `.claude-plugin/`, `agents/`, `skills/`, `commands/`, `hooks/`, `templates/`, `scripts/`. Empty `.gitkeep` is fine where there is no content yet.

- [x] Create the seven directories.
- [x] Add a one-line `README` inside each that names its purpose.

**Acceptance:** `ls` shows the seven directories at repo root and each is committed.
