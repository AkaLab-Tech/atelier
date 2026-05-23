---
description: Initialise a project so the operator can run atelier tasks in it — delegates to the `atelier-setup-project` bash helper installed by `install.sh`, then dispatches `project-profiler` to draft the root `CLAUDE.md`. Idempotent — re-running preserves all existing files.
argument-hint: "[project-path] [--yes|-y] [--mode=new|existing]"
allowed-tools: Read, Glob, Grep, Bash(atelier-setup-project:*), AskUserQuestion, Task
---

You are running the `/setup-project` slash command. This command has two phases: (1) delegate mechanical scaffolding to the `atelier-setup-project` bash binary on `$PATH`, then (2) dispatch the `project-profiler` agent to draft the root `CLAUDE.md` based on the mode the bash helper detected.

## Phase 1 — bash helper

Invoke the bash helper, passing through the operator's arguments verbatim and the plugin root from `$CLAUDE_PLUGIN_ROOT`:

```bash
atelier-setup-project --plugin-root "$CLAUDE_PLUGIN_ROOT" $ARGUMENTS
```

That single command does **all** of the mechanical work:

1. Resolves the project path (defaults to `.` if `$ARGUMENTS` is empty); refuses `$HOME`, `/`, `/etc`, `/usr`, `/Applications`, `/bin`, `/sbin`, `/var`, `/opt`, `/private`, and the plugin root itself.
2. Detects non-interactive mode via `--yes` / `-y` in `$ARGUMENTS`, or `$ATELIER_AUTO`.
3. Reads `$ATELIER_CONFIG_DIR/projects.json` (atelier's project registry). If the project is already configured: interactive → ask to reconfigure; non-interactive → refuse with exit code 2.
4. Writes `<path>/.claude/settings.json` from `$ATELIER_CONFIG_DIR/templates/settings.template.json` with `<worktree>` substituted. Validates the result parses with `jq empty` and that no literal `<worktree>` token remains.
5. Creates `<path>/ROADMAP.md`, `<path>/IN_PROGRESS.md`, `<path>/HISTORY.md`, `<path>/.claude/CLAUDE.md` only when missing (the latter from `$CLAUDE_PLUGIN_ROOT/templates/project-claude.md.template`).
6. Creates or appends to `<path>/.npmrc` the three PLAN.md §4 guardrails (`ignore-scripts=true`, `minimum-release-age=10080`, `audit-level=moderate`); never weakens existing values.
7. Creates or appends to `<path>/.gitignore` the four required entries (`.task-log/`, `.claude/settings.json`, `.claude/settings.local.json`, `.DS_Store`). `.claude/settings.json` is gitignored because the helper substitutes `<worktree>` with the operator's absolute path; committing it would propagate that path to every clone.
8. Records the setup in `$ATELIER_CONFIG_DIR/projects.json` with `setupCompleted` and `setupVersion`.

The helper also emits two `atelier-*=...` marker lines that Phase 2 parses:

- `atelier-detected-mode=new|existing` — the heuristic result (or `--mode=...` override).
- `atelier-root-claude-md=present|missing` — whether `<path>/CLAUDE.md` already exists.

Relay the helper's stdout back to the operator verbatim. If the helper exits non-zero, surface the error and stop — do NOT run Phase 2.

## Phase 2 — root `CLAUDE.md` draft (M4.19)

After the bash helper completes, parse its stdout for the two marker lines. Apply this decision table:

| `atelier-root-claude-md` | `atelier-detected-mode` | Action |
| --- | --- | --- |
| `present` | (ignored) | **Skip** Phase 2. Print: *"Root CLAUDE.md already exists — preserved."* The operator's customizations are sacred. |
| `missing` | `existing` | **Dispatch `project-profiler`** in `existing` mode. Briefing: `{ mode: "existing", project_path: "<abs>" }`. The agent scans manifest files / src layout / CI configs / README and drafts `<path>/CLAUDE.md`. |
| `missing` | `new` | **Ask the operator** (via `AskUserQuestion`): *"What is this project about? Describe in your own words — purpose, intended stack if you know, anything else useful."* (free-form, no preset options). Then dispatch `project-profiler` in `new` mode. Briefing: `{ mode: "new", project_path: "<abs>", operator_answer: "<the answer>" }`. The agent converts the answer into a structured `CLAUDE.md` with `TBD` markers for unknowns. |

### Non-interactive mode in Phase 2

If `$ARGUMENTS` carries `--yes` / `-y` or `$ATELIER_AUTO` is set:

- `existing` mode: dispatch `project-profiler` normally — no operator input needed for the scan.
- `new` mode: **stop and report** — the `AskUserQuestion` for the interview cannot run non-interactively. Print: *"Non-interactive setup of a new project requires `--mode=existing` to skip the interview, or re-run interactively."*

This rule prevents an autonomous chain from drafting a fabricated `CLAUDE.md` from a fabricated answer.

### Project-profiler invocation

Use the `Task` tool with `subagent_type: "project-profiler"` and a briefing built from the decision table. Surface the agent's report (which includes `status: written | kept-existing` and the sections written / left TBD) verbatim to the operator.

## Hard refusals

These all live in the bash helper; documented here so the operator knows what to expect when reading the `/setup-project` contract:

- **Never overwrite** `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` / `.claude/CLAUDE.md` / root `CLAUDE.md` if they already exist (the root file is `project-profiler`'s own refusal, but the rule is the same).
- **Never weaken** an existing `.npmrc` (no `audit-level` downgrade, no `minimum-release-age` reduction).
- **Never reconfigure under `--yes` / `ATELIER_AUTO`**: re-running on a configured project in non-interactive mode exits with code 2.
- **Never run `git init`** or any git write — `/setup-project` is for atelier scaffolding only.
- **Never invoke `Write`, `Edit`, `mkdir`, `sed`, or `jq` directly from this slash command.** All file work happens inside the bash helper or `project-profiler`.
- **Never dispatch `project-profiler` in `new` mode without an explicit operator answer.** The agent's prompt enforces this defensively but the slash command should refuse to even invoke it (the briefing would carry an empty `operator_answer` field).

## Hard refusals

These all live in the bash helper; documented here so the operator knows what to expect when reading the `/setup-project` contract:

- **Never overwrite** `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` / `.claude/CLAUDE.md` if they already exist.
- **Never weaken** an existing `.npmrc` (no `audit-level` downgrade, no `minimum-release-age` reduction).
- **Never reconfigure under `--yes` / `ATELIER_AUTO`**: re-running on a configured project in non-interactive mode exits with code 2.
- **Never run `git init`** or any git write — `/setup-project` is for atelier scaffolding only.
- **Never invoke `Write`, `Edit`, `mkdir`, `sed`, or `jq` directly from this slash command.** All file work happens inside the bash helper, which is the only tool allowed here.

## Where to look if something breaks

- `atelier-setup-project --help` prints the full CLI contract.
- `which atelier-setup-project` should resolve to `~/.local/bin/atelier-setup-project` (a symlink installed by `install.sh`).
- If `which` is empty: re-run `install.sh`, or check that `~/.local/bin` is on `$PATH`.
- If the helper reports "cannot locate the atelier plugin root", `$CLAUDE_PLUGIN_ROOT` is not set (you are probably running ad-hoc via `claude --plugin-dir`). Run `atelier-setup-project --plugin-root /abs/path/to/atelier-checkout <path>` directly from your terminal, or export `ATELIER_PLUGIN_ROOT` in your shell.

