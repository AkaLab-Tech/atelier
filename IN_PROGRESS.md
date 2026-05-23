# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M4.19 — `/setup-project` auto-generates root `CLAUDE.md` (interview or codebase scan)

`/setup-project` today writes a placeholder `.claude/CLAUDE.md` from a generic template and leaves the **root** `CLAUDE.md` entirely up to the operator. Result: agents start every task with effectively zero project context.

This task makes `/setup-project` populate the root `CLAUDE.md` automatically, branching on whether the project is **new** or **existing**.

- **Detection** — heuristic on tracked-file count + manifest presence; `--mode=new|existing` override.
- **`new` branch** — slash command asks one open question (free-form) and dispatches `project-profiler` in `new` mode to draft `CLAUDE.md` from the answer.
- **`existing` branch** — slash command dispatches `project-profiler` (Sonnet, Read/Glob/Grep only) which scans manifests + dir layout + CI configs and drafts `CLAUDE.md` with detected stack, marking unknowns as `TBD`.

**Acceptance:**

- `/setup-project` on empty repo (0 commits): interview + draft.
- `/setup-project` on populated repo (`package.json` + `src/`): scan + draft.
- `--mode=new` override forces interview path on populated repo.
- Re-run preserves existing root `CLAUDE.md` (idempotent).

**Progress notes:** worktree `task/m4.19-auto-claude-md` created 2026-05-23 from `f840677` (post-#66 merge). MINOR bump (`0.3.0` → `0.4.0`) per PLAN.md §14.2 (new agent + new template + new helper subcommand + new slash command step).

**Design note:** the bash script (`scripts/atelier-setup-project`) handles **detection only** — emits the detected mode to its caller via the output summary. The slash command (`commands/setup-project.md`) handles the AI-driven branches (interview / scan) by dispatching `project-profiler` agent. Bash cannot invoke an LLM inline; the slash command is the natural place for the AI work.
