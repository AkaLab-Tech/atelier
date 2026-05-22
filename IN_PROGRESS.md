# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M5.0.3 — `atelier-uninstall` with chat-session preservation

Today there is no clean way to uninstall atelier. To remove atelier, the operator has to manually:

1. Edit `~/.zshrc` to remove the atelier hooks block (between sentinel comments).
2. `rm ~/.local/bin/atelier-setup-project`.
3. `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR claude plugin uninstall atelier@akalab-tech` and `claude-roadmap-tools@akalab-tech`.
4. Decide what to do with `$ATELIER_CONFIG_DIR` — which contains chat history (`history.jsonl`), session state (`projects/`), plans (`plans/`), backups — without a clear convention.

M5.0.3 ships a single command — `scripts/atelier-uninstall` — that automates steps 1–3 and gives the operator a clear default for step 4 (preserve), with an explicit opt-in for destructive wipe.

**Default mode (conservative):**

- Remove the atelier hooks block from `~/.zshrc` and/or `~/.bashrc` (via `sed` against the existing sentinel comments — same comments used at install time).
- Remove the `~/.local/bin/atelier-setup-project` symlink and the new `~/.local/bin/atelier-uninstall` symlink.
- Uninstall `atelier@akalab-tech` and `claude-roadmap-tools@akalab-tech` plugins under `$ATELIER_CONFIG_DIR`.
- **NOT removed:** `$ATELIER_CONFIG_DIR` itself. The operator's chat history, sessions, plans, backups all remain in place. They can still `CLAUDE_CONFIG_DIR=~/.claude-work claude` (or whatever the chosen path was) later to access archived sessions, even though atelier is no longer "installed" on their system.

**Purge mode (`--purge` flag):**

- All of the above, plus `rm -rf "$ATELIER_CONFIG_DIR"`.
- Requires explicit confirmation prompt: *"This will permanently delete all chat history, sessions, plans, and backups under `<path>`. Type 'PURGE' (uppercase) to confirm."*.
- Non-interactive `--purge --yes` is allowed, but the operator must explicitly opt in to both flags.

**Acceptance:** `atelier-uninstall` from any shell removes atelier's shellrc footprint, symlinks, and plugin install — without touching the operator's chat sessions by default. `atelier-uninstall --purge` (with confirmation) wipes everything. After a default uninstall, re-installing atelier via `install.sh` picks up the same `$ATELIER_CONFIG_DIR` and does NOT require re-authenticating to Claude (auth tokens persist in `$ATELIER_CONFIG_DIR/.claude.json`).

**Trigger to revisit:** when an operator (including the maintainer) needs to decommission atelier without losing chat history. Captured post-M5.0 alongside M5.0.2 as the natural pair of install-side and uninstall-side hardening.

**Progress notes:** worktree `task/m5.0.3-atelier-uninstall` created 2026-05-22 from `6ff17e4` (post-#62 merge).
