# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M7.1 — Dogfood on a real (non-toy) project

Run a full task cycle on an actual project. Capture friction.

**Target:** `~/Work/deminut` — multi-repo project (Phase 8 workspace candidate). Active repos: `deminut-api`, `deminut-printer-bridge`, `deminut-spa`.

**Progress:**
- 2026-06-11 — Cleaned up the project dir before setup: moved 4 inactive repos (`deminut-landing-new`, `deminut-landing-web`, `printer-client`, `printer-updater`), non-git assets (`branding`, `demos`, `fuentes`), and 2 stale `.code-workspace` files to `~/Work/deminut-archive/` (moved, not deleted). Active dir now holds only the 3 workspace repos + their worktrees.

**Friction captured:**
- ✅ **SSH remotes vs atelier HTTPS-only constraint (resolved 2026-06-11).** All 3 active repos used `git@github.com:Deminut-com/*.git` remotes; atelier's hard constraint (PLAN.md §2 step 5) is HTTPS-only. Re-pointed each `origin` to `https://github.com/Deminut-com/*.git` and verified HTTPS access works for the `Deminut-com` org. **Open question for atelier:** `/setup-workspace` / `/setup-project` should detect SSH remotes and offer to convert (or reject), rather than failing later in the flow.
- 📝 Repo name mismatch: `deminut-printer-bridge` local dir maps to remote `deminut-print-bridge` (print, not printer). Harmless but worth knowing if atelier ever infers remote from dir name.
