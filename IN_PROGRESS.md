# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

<!-- Single-file layout: paste the task block from ROADMAP.md here. -->
<!-- Indexed layout: link to roadmap/TASK_NNN_<slug>.md and write progress notes inside that file, not here. -->

### M7.1.F26 — `/atelier:setup-project` silently preserves a non-atelier-managed `settings.json` — 2026-05-26
**PR:** _pending_

Discovered during M7.1 dogfood-4 on the operator's `storefront` project. The operator ran `/atelier:setup-project /Users/mike/Work/storefront`; the script reported success and registered the project in `$ATELIER_CONFIG_DIR/projects.json`, but the project's existing `.claude/settings.json` (dated 30-Apr, pre-atelier) was never touched. Net effect from inside an atelier-managed worktree: Claude Code prompted the operator for permission on **every** Bash command (pnpm, git, gh, …), every Edit/Write, and every Read — none of which would have prompted had the template's `defaultMode: "acceptEdits"` plus the worktree-scoped allowlist landed on disk.

Root cause: `scripts/atelier-setup-project` step 3 (`step_settings_json`) returned early as `preserved` whenever the target `.claude/settings.json` existed and `$RECONFIGURE` was false (the typical first-run case for any project not yet registered in `projects.json`). The branch logged a single `sublog` line — easy to miss next to step 4's roadmap-scaffolding noise — and never compared the file against the atelier template, so legacy / hand-rolled / pre-atelier `settings.json` files passed through unmodified.

**Delivered:**

- **`scripts/atelier-setup-project` — new helpers**:
  - `is_atelier_managed_settings <file>`: returns 0 iff the JSON has `.permissions.defaultMode == "acceptEdits"` AND `.permissions.deny` contains `"Bash(git push --force*)"` (a distinctive template marker no operator would write by hand). Robust against operator edits to `.permissions.allow` — those don't touch either signal.
  - `backup_with_timestamp <file>`: copies `<file>` to `<file>.bak.<utc-iso8601>` (e.g. `.bak.2026-05-27T13-56-56Z`) and echoes the backup path on stdout, so callers can log it. Never destructive — `cp`, not `mv`.
- **`scripts/atelier-setup-project` — `step_settings_json` refactored** into three explicit branches:
  - **No target file** → write the instantiated template, `SETTINGS_STATUS=created`.
  - **Target exists, atelier-managed** → preserve silently with `sublog` showing "(atelier-managed)" so operators can see why the file was left alone. `SETTINGS_STATUS=preserved`.
  - **Target exists, NOT atelier-managed** → emit a 3-line `warn` block, then prompt interactively: `Overwrite with current atelier template (existing file will be backed up)? [y/N]`. On `y`: backup with timestamp + overwrite (`SETTINGS_STATUS=updated`). On anything else: preserve (`SETTINGS_STATUS=preserved`). Under `--yes` / `$ATELIER_AUTO`: skip the prompt and preserve with a warning telling the operator to re-run interactively to overwrite — same "never weaken without confirmation" rule as the rest of the script.
- **Reconfigure path** (`[ -f $target ] && $RECONFIGURE`) now also runs `backup_with_timestamp` before `mv "$tmp" "$target"`. Previously it overwrote operator customizations silently on `y` — minor improvement, same protection model.

**Decisions captured:**

- **Heuristic over schema marker.** Considered adding a `_atelier: { version }` top-level field instead. Rejected for v1: (a) it would re-label every existing atelier-managed `settings.json` as "not managed" until the operator re-runs `setup-project`, breaking the very upgrade path this fix enables; (b) Claude Code's tolerance for unknown top-level keys across versions is not guaranteed. The `defaultMode == "acceptEdits"` + `deny` marker heuristic is simple, backward-compatible, and matches what every atelier-instantiated `settings.json` since M4.7 has had on disk. The marker can be added later if a richer signal is ever needed.
- **`Bash(git push --force*)` as the deny-list signal** specifically. Other candidates were `mcp__plugin_atelier_playwright__browser_run_code_unsafe` (newer, M3.4-only — would miss older atelier-managed files) and `Bash(sudo *)` (too common in operator-written denies). The git-push-force entry has been in the template since M2.4, is atelier-specific (operators rarely hand-write it), and is unlikely to be removed in future template revisions.
- **Operator-facing message phrasing.** The prompt explicitly says "existing file will be backed up". Operators won't reflexively answer `y` without that reassurance; removing the fear of data loss is the whole point of the timestamped backup.
- **Backup path next to the original**, not under `/tmp` or `$ATELIER_CONFIG_DIR`. Two reasons: (a) backups stay alongside the file they belong to, so operators looking to restore them by hand find them with `ls .claude/`; (b) `.bak.*` is part of common `.gitignore` patterns most projects already have, so backups don't leak into commits.
- **No automatic removal of `.bak.*` files.** They are operator-recoverable evidence — the script never knows whether they're still useful. Trade-off: long-running atelier projects might accumulate them on each reconfigure. Acceptable until proven friction.

**Plugin scope:** no — `scripts/atelier-setup-project` is a host-OS-layer script symlinked into `~/.local/bin` by `install.sh` (Phase C.1, line ~1203), not plugin-shipped content. `plugin.json` is **not** bumped. Distribution path for the fix: operators re-run `install.sh` (or `git pull` their atelier checkout if installed from a clone) to pick up the new script.

**Spawned follow-up:** none in atelier itself. The dogfood-4 operator's `storefront/.claude/settings.local.json` (accumulated ~168 hand-approved entries pre-fix) is preserved as-is — the fix only addresses `settings.json`, not `settings.local.json`. After this lands, the operator re-runs `/atelier:setup-project` on `storefront`, answers `y` at the new prompt, and the legacy `settings.json` is backed up while the template-instantiated one takes over.
