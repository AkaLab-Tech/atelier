---
description: Initialise a project so the operator can run atelier tasks in it — writes `.claude/settings.json` (from the plugin template), creates a starter `ROADMAP.md`, writes `.npmrc` supply-chain guardrails, adds `.gitignore` entries, and records the setup in `~/.claude/.atelier-config.json`. Idempotent — re-running offers a reconfigure flow.
argument-hint: "[project-path] [--yes|-y]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(mkdir:*), Bash(sed:*), Bash(jq:*), Bash(test:*), Bash(ls:*), Bash(date:*), Bash(env:*)
---

You are running the `/setup-project` slash command. Bootstrap a directory so atelier can manage tasks in it.

User input: `$ARGUMENTS` (optional — absolute or relative path to the project root). If empty, default to the current working directory (`.`). May also carry the `--yes` / `-y` flag described below.

## Interaction mode (read once at the start)

Same contract as `/atelier:next-task` (M4.6). You are **non-interactive** if any of:

- `$ARGUMENTS` contains the literal token `--yes` (whitespace-bounded).
- `$ARGUMENTS` contains the literal token `-y` (whitespace-bounded).
- The environment variable `ATELIER_AUTO` is set to a non-empty value.

Otherwise you are **interactive**. In non-interactive mode, every "ask the operator" step below auto-resolves with the **safe default**, which for `/setup-project` means: **never overwrite, never weaken, never widen**. When the safe default is "do not overwrite", the command continues and reports what was preserved. When the safe default is "do not proceed" (e.g., reconfigure of a configured project), the command stops with a clear error and instructs the operator to re-run interactively. Strip `--yes` / `-y` from `$ARGUMENTS` before parsing the project path.

## Idempotence — check first, ask before overwriting

### 1. Resolve the project path

Take `$ARGUMENTS` (or `.` if empty, after stripping any `--yes` / `-y` flag). Resolve to an absolute path. **Refuse** if the path:
- Does not exist. Interactive: offer to create it after explicit confirmation (`mkdir -p` only, never `rm`-style cleanup). Non-interactive: stop with error — refuse to create a directory under `--yes` / `ATELIER_AUTO` because the operator's intent (which path they really meant) is ambiguous.
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
- **Interactive mode — offer reconfigure.** Ask the operator: *"Re-run setup? This will rewrite `.claude/settings.json` from the latest template, regenerate `.npmrc`, and re-record the setup timestamp. Project files like `ROADMAP.md` and `.claude/CLAUDE.md` will be preserved unless missing."* Wait for an explicit yes/no.
- **Non-interactive mode — refuse reconfigure (safe default).** A re-run on a configured project under `--yes` / `ATELIER_AUTO` would silently overwrite the existing `.claude/settings.json` with whatever the current plugin's template says, which may have changed in subtle ways. Refuse instead, with this error:
  ```text
  ✗ /setup-project: <path> is already configured (since <ISO>, version <version>).
     Reconfigure is not allowed in non-interactive mode because it overwrites
     .claude/settings.json with the current plugin template. Re-run interactively
     (without --yes / ATELIER_AUTO) if you genuinely want to reconfigure.
  ```

If the project is **not yet configured**, proceed to the setup steps directly (no reconfirm needed for first-time setup — the command is the confirmation). This branch is identical in both interaction modes.

## Setup steps

### 3. `<path>/.claude/settings.json`

**Precondition** — `$CLAUDE_PLUGIN_ROOT` must resolve to a real directory containing `templates/settings.template.json`. Claude Code sets this env var automatically when the plugin is installed via marketplace, but when the plugin is loaded ad-hoc via `claude --plugin-dir <path>` from the CLI the variable is **not** set (Finding from dogfood-1). Before doing anything else in this step, verify:

```bash
test -n "${CLAUDE_PLUGIN_ROOT:-}" && test -f "$CLAUDE_PLUGIN_ROOT/templates/settings.template.json"
```

If either check fails, **stop with an actionable error** — do NOT continue to step 4. Report exactly:

```text
✗ /setup-project: cannot locate the atelier plugin template.

   $CLAUDE_PLUGIN_ROOT = "<unset or wrong path>"
   expected file:       <$CLAUDE_PLUGIN_ROOT>/templates/settings.template.json

   This usually means atelier was loaded via `claude --plugin-dir …` (CLI),
   which does not export CLAUDE_PLUGIN_ROOT. Two ways forward:

   - Recommended: install atelier through its marketplace:
       /plugin marketplace add AkaLab-Tech/claude-plugins
       /plugin install atelier@akalab-tech
     and restart Claude Code. The variable will be set automatically.

   - Quick workaround for a one-off CLI run:
       export CLAUDE_PLUGIN_ROOT=/abs/path/to/atelier-checkout
     then re-run `/atelier:setup-project <path>`.
```

Once the precondition is satisfied, `mkdir -p <path>/.claude` and instantiate the template:

```bash
sed "s|<worktree>|<resolved-project-path>|g" \
    "$CLAUDE_PLUGIN_ROOT/templates/settings.template.json" \
    > <path>/.claude/settings.json
```

Confirm the result parses with `jq empty`. If the file already exists and you are in reconfigure mode, **diff** it against the new content. If there are local edits, the behaviour depends on interaction mode: **interactive** — ask the operator before overwriting; **non-interactive** — preserve the existing file (do not overwrite) and report `⚠ <path>/.claude/settings.json preserved (local edits detected, non-interactive)`. The reconfigure-on-configured-project case is already refused upstream in step 2 for non-interactive mode, so this branch only fires when the operator deliberately reconfigured interactively, then re-ran with `--yes`.

**Hard refusal:** if `sed` returns non-zero, `jq empty` returns non-zero, or the output file size is 0 bytes, **delete the failed output and stop** with the same actionable error above. Do not advance to step 4 with a corrupt or missing settings.json — Finding #3 from dogfood-1 showed that silently skipping this step left the project in a half-configured state.

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
- **`.npmrc` exists, some/all guardrails missing or weaker** (e.g., `audit-level=high`) → behaviour depends on interaction mode. **Interactive:** ask the operator; the default offer is "append the missing ones at the bottom under a clearly-marked atelier section". **Non-interactive:** apply the default automatically (append the missing lines) and log `⚠ <path>/.npmrc had weaker/missing guardrails — appended atelier section (non-interactive default)`. In **both** modes, do **not** rewrite existing operator-authored lines — only append; weakening (e.g., lowering `audit-level=moderate` to `high`) is never auto-applied.

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
