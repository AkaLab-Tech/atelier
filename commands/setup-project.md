---
description: Initialise a project so the operator can run atelier tasks in it — writes `.claude/settings.json` (from the plugin template), creates a starter `ROADMAP.md`, writes `.npmrc` supply-chain guardrails, adds `.gitignore` entries, and records the setup in `~/.claude/.atelier-config.json`. Idempotent — re-running offers a reconfigure flow.
argument-hint: "[project-path]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(mkdir:*), Bash(sed:*), Bash(jq:*), Bash(test:*), Bash(ls:*), Bash(date:*)
---

You are running the `/setup-project` slash command. Bootstrap a directory so atelier can manage tasks in it.

User input: `$ARGUMENTS` (optional — absolute or relative path to the project root). If empty, default to the current working directory (`.`).

## Idempotence — check first, ask before overwriting

### 1. Resolve the project path

Take `$ARGUMENTS` (or `.` if empty). Resolve to an absolute path. **Refuse** if the path:
- Does not exist (offer to create it after explicit confirmation — `mkdir -p` only, never `rm`-style cleanup).
- Is `$HOME`, `/`, or any system directory (`/etc`, `/usr`, `/var`, `/opt`, `/Applications`).
- Is the atelier plugin's own directory (`$CLAUDE_PLUGIN_ROOT`). The plugin is not a project.

### 2. Read `~/.claude/.atelier-config.json`

If the file exists, parse it as JSON and look for an entry with `"path": "<resolved-absolute-path>"`. The entry shape is:

```json
{
  "projects": {
    "/abs/path/to/project": {
      "setupCompleted": "2026-05-18T14:32:11Z",
      "setupVersion": "0.1.0"
    }
  }
}
```

If the project is **already configured**:

- **Default action: skip the wizard.** Report `✓ <path> already configured (setupCompleted: <ISO>, setupVersion: <version>) — nothing to do.`
- **Offer reconfigure.** Ask the operator: *"Re-run setup? This will rewrite `.claude/settings.json` from the latest template, regenerate `.npmrc`, and re-record the setup timestamp. Project files like `ROADMAP.md` and `.claude/CLAUDE.md` will be preserved unless missing."* Wait for an explicit yes/no.

If the project is **not yet configured**, proceed to the setup steps directly (no reconfirm needed for first-time setup — the command is the confirmation).

## Setup steps

### 3. `<path>/.claude/settings.json`

`mkdir -p <path>/.claude`. Then instantiate the plugin's template:

```bash
sed "s|<worktree>|<resolved-project-path>|g" \
    "$CLAUDE_PLUGIN_ROOT/templates/settings.template.json" \
    > <path>/.claude/settings.json
```

Confirm the result parses with `jq empty`. If the file already exists and you are in reconfigure mode, **diff** it against the new content and ask before overwriting if there are local edits.

### 4. `<path>/ROADMAP.md`

If `ROADMAP.md` does not already exist at `<path>`, create it from the operator-facing template (PLAN.md §5):

```markdown
# Roadmap — <project-name>

## 🔥 P0 — Blockers

(Items here are non-negotiable. Format: `- [ ] <type> <title> [#id] [~estimate] [blocked_by:...]`.)

## 🎯 P1 — Next

## 💭 P2 — Backlog
```

If `ROADMAP.md` already exists, **leave it alone** — the operator owns its content. In reconfigure mode, surface that it was preserved.

Also ensure `IN_PROGRESS.md` and `HISTORY.md` exist alongside `ROADMAP.md` per the `roadmap-tracking-flow` convention. Create them only if missing, with their standard headers.

### 5. `<path>/.claude/CLAUDE.md`

If the file does not exist, create a starter that points at the global rules:

```markdown
# CLAUDE.md — <project-name>

This project is managed by atelier (https://github.com/AkaLab-Tech/atelier).

The operator-facing rules (dependency installs, push/PR/merge gates, failure recovery, agent chain) are loaded into every session by atelier's `SessionStart` hook from `operator-rules.md` at the plugin root. Do not duplicate them here.

## Project-specific guidance

(Add anything specific to this project that an atelier agent should know — stack, conventions, deploy targets, etc. Keep it short and verifiable.)
```

Leave it alone if it already exists.

### 6. `<path>/.npmrc` — pnpm supply-chain guardrails (PLAN.md §4)

The three required lines:

```ini
ignore-scripts=true
minimum-release-age=10080
audit-level=moderate
```

Behaviour:

- **No `.npmrc` exists** → create it with exactly those three lines plus a leading comment `# atelier supply-chain guardrails (PLAN.md §4) — managed by /setup-project`.
- **`.npmrc` exists, all three lines present** → report `✓` and leave it.
- **`.npmrc` exists, some/all guardrails missing or weaker** (e.g., `audit-level=high`) → ask the operator. The default offer: **append** the missing ones at the bottom under a clearly-marked atelier section. Do **not** rewrite existing operator-authored lines.

### 7. `<path>/.gitignore`

Ensure these entries are present (append if missing, never duplicate):

```text
.task-log/
.claude/settings.local.json
.DS_Store
```

`.env*` is already in the operator's **global** gitignore (set up by `install.sh` Phase C.1), so it does not need a project-local entry — but if no global excludes are configured (rare), surface that as a `/atelier:doctor` follow-up.

### 8. Record the setup

Update `~/.claude/.atelier-config.json` (create the file if missing). Add or replace the entry for `<path>`:

```json
{
  "path": "<resolved-absolute-path>",
  "setupCompleted": "<current-ISO-timestamp>",
  "setupVersion": "<atelier-plugin-version-from-plugin.json>"
}
```

Use `jq` for the JSON merge to avoid corrupting any other entries.

## Output

End with a summary:

```text
✓ <path> set up for atelier
  .claude/settings.json:   <created|updated|preserved>
  ROADMAP.md:              <created|preserved>
  IN_PROGRESS.md:          <created|preserved>
  HISTORY.md:              <created|preserved>
  .claude/CLAUDE.md:       <created|preserved>
  .npmrc:                  <created|appended|preserved>
  .gitignore:              <created|appended|preserved>
  ~/.claude/.atelier-config.json: <created|updated>
  setupCompleted:          <ISO-timestamp>
  setupVersion:            <version>

  Next: cd <path> && run /next-task to claim the first ROADMAP.md item.
```

## Hard refusals

- **Never** overwrite `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` if they already have content (only create when missing).
- **Never** weaken `.npmrc` (e.g., raise `audit-level` from `moderate` to `high`, lower `minimum-release-age`).
- **Never** delete or rename existing files in the project (`.gitignore` edits append; `.npmrc` edits append; everything else either creates fresh or preserves).
- **Never** run `git init` or any other git write — `/setup-project` is for atelier scaffolding, not for git bootstrap.
