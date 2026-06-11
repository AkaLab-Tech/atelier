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
- 🔧 **F63 — `atelier-setup-project` aborts headlessly + no headless settings override (fixed, this PR).** Two issues surfaced running setup on the existing repos: (1) every interactive prompt uses `read`, so a non-TTY / piped invocation hits EOF and dies with exit 1 under `set -e` instead of taking the safe default — this aborted setup on all 3 repos; (2) a pre-atelier `.claude/settings.json` (deminut-api had a large hand-grown allowlist) could only be overwritten interactively — `--yes` preserves it (F26-safe) and `--reconfigure` only targets already-registered projects, so there was no headless overwrite path for a new project. Fix: non-TTY stdin now implies non-interactive (mirrors git-wt), and a new `--override` flag overwrites a non-atelier-managed settings.json with a timestamped backup, headless, including first-time setup. `setup-workspace.md` documents forwarding `--override` (operator-confirmed) when cascading to a member with legacy settings.
- 🐛 **F64 — `is_atelier_managed_settings` stale marker (fixed, this PR).** It keyed off `.permissions.defaultMode == "acceptEdits"`, but the per-project template intentionally omits `defaultMode` (auto-mode is a session-level setting written by `install.sh` as `defaultMode="auto"` into `$ATELIER_CONFIG_DIR/settings.json`, verified by `atelier-doctor`). So the check always failed: every atelier-managed project was misclassified as legacy, F38 drift-resync never fired, and the F26 warning fired on every project. Now detects on the template's distinctive `deny` guardrails. **Behavior change:** re-running `setup-project` on a drifted atelier project now auto-resyncs settings to the current template (with backup) as F38 always intended.
- ⏭️ **Reviewer access — operator-handled.** The independent `AtelierReviewer` identity lacks access to the private `Deminut-com` repos; in `--yes` mode the helper warns and continues (correct), but auto-merge review will fail until access is granted. Operator is adding `AtelierReviewer` as a read collaborator manually.
