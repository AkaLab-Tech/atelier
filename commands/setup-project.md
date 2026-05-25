---
description: Initialise a project so the operator can run atelier tasks in it — delegates to the `atelier-setup-project` bash helper installed by `install.sh`, then dispatches `project-profiler` to draft the root `CLAUDE.md`. Idempotent — re-running preserves all existing files. Typical usage is just `/atelier:setup-project` from inside the project directory; passing a path is only for the uncommon case of configuring a project from outside it.
argument-hint: "[--yes|-y] [--mode=new|existing] [project-path-if-not-cwd]"
allowed-tools: Read, Glob, Grep, Write, Bash(atelier-setup-project:*), AskUserQuestion, Task
---

You are running the `/setup-project` slash command. This command has two phases: (1) delegate mechanical scaffolding to the `atelier-setup-project` bash binary on `$PATH`, then (2) dispatch the `project-profiler` agent to draft the root `CLAUDE.md` based on the mode the bash helper detected.

**Typical invocation is `$ARGUMENTS = empty`** (M7.1.F19) — the operator runs `/atelier:setup-project` from inside the project directory they want to configure, and the helper resolves the project path to `pwd` automatically. A positional `<project-path>` is only used when configuring a project from outside it; the argument-hint puts it last so operators don't reflexively pass `.` as a "required" path.

## Phase 1 — bash helper

Invoke the bash helper, passing through the operator's arguments verbatim. **Do NOT pass `--plugin-root` from the slash command** (M7.1.F18): `$CLAUDE_PLUGIN_ROOT` is only auto-set by Claude Code for hook invocations, not for Bash tool calls inside slash commands. Passing `--plugin-root ""` (the empty expansion of an unset env var) used to make the helper die with `"--plugin-root requires a path"`. The helper now auto-discovers its own plugin root via the symlink chain (`~/.local/bin/atelier-setup-project` → `<dotfiles>/scripts/atelier-setup-project`, parent dir is the atelier checkout containing `templates/` + `.claude-plugin/`), so the slash command just calls:

```bash
atelier-setup-project $ARGUMENTS
```

That single command does **all** of the mechanical work:

1. Resolves the project path — **defaults to the current working directory** when `$ARGUMENTS` is empty (the typical case: operator is inside the project they want to configure). Only resolves to an explicit `<project-path>` when one is passed. Refuses dangerous targets: `$HOME`, `/`, `/etc`, `/usr`, `/Applications`, `/bin`, `/sbin`, `/var`, `/opt`, `/private`, and the plugin root itself.
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

After the bash helper completes, parse its stdout for the two marker lines (`atelier-detected-mode=...` and `atelier-root-claude-md=...`). The split:

- **`project-profiler` (read-only)** scans the repo and **returns a drafted `CLAUDE.md` content block** in its report. It does NOT write the file itself — its tools list excludes `Write` by design.
- **This slash command** takes the drafted content from the agent's report and writes it to `<project>/CLAUDE.md` using the `Write` tool. The session's initial permissions cover this path; the agent's sub-scope does not.

### Decision table (which action this slash command takes)

| `atelier-root-claude-md` | `atelier-detected-mode` | Action |
| --- | --- | --- |
| `present` | (ignored) | **Skip Phase 2 entirely.** Print: *"Root CLAUDE.md already exists — preserved."* Do not dispatch any agent, do not write anything. The operator's customizations are sacred. |
| `missing` | `existing` | **Invoke `Task` with `subagent_type: "project-profiler"`.** Briefing payload: `{ mode: "existing", project_path: "<abs>" }`. The agent scans manifests / src layout / CI configs / README and **returns drafted content in its report**. After it returns, **extract the inner content of the agent's `## Drafted content` fenced block and Write it to `<abs>/CLAUDE.md`.** |
| `missing` | `new` | **Ask the operator** via `AskUserQuestion`: *"What is this project about? Describe in your own words — purpose, intended stack if you know, anything else useful."* (free-form, no preset options). Then **invoke `Task` with `subagent_type: "project-profiler"`** and briefing `{ mode: "new", project_path: "<abs>", operator_answer: "<the answer>" }`. After it returns, same extract + Write as above. |

After the Write completes, surface the agent's report **verbatim** to the operator (including the `## Drafted content` block) so they can see what was written. Then stop.

### Non-interactive mode in Phase 2

If `$ARGUMENTS` carries `--yes` / `-y` or `$ATELIER_AUTO` is set:

- `existing` mode: dispatch `project-profiler` immediately via `Task` — no operator input needed for the scan. **The `--yes` does NOT change this code path; it is the same dispatch as the interactive case.**
- `new` mode: **stop and report** — the `AskUserQuestion` for the interview cannot run non-interactively. Print: *"Non-interactive setup of a new project requires `--mode=existing` to skip the interview, or re-run interactively."*

This rule prevents an autonomous chain from drafting a fabricated `CLAUDE.md` from a fabricated answer.

### Mandatory dispatch + Write path

When the decision table says "dispatch `project-profiler`", the **only** correct implementation is:

```text
1. Task(subagent_type: "project-profiler", description: "Draft root CLAUDE.md", prompt: <briefing>)
2. Parse agent's report: locate the ` ```markdown ... ``` ` fenced block under `## Drafted content`.
3. If status == "drafted": Write(<abs>/CLAUDE.md, <extracted content>).
4. If status == "kept-existing": skip Write, print preservation note.
```

The agent's report carries the drafted content as a literal markdown fenced block. Extract the inner markdown (between `` ```markdown `` and `` ``` ``), trim no whitespace, and call `Write(<abs>/CLAUDE.md, <content>)`. The Write succeeds because this slash command's session is the one with `Write` on the project path in its allowed-tools.

If `Task` returns an error (agent not found, dispatch refused, etc.), surface it and stop. Do **not** fall back to inventing CLAUDE.md content from scratch — without the agent's scan, the content would be fabricated.

If the agent's report is missing the `## Drafted content` block (and status is not `kept-existing`), the agent malformed its output: surface the report verbatim and stop. The slash command should not try to "recover" by inventing content.

## Hard refusals

These all live in the bash helper; documented here so the operator knows what to expect when reading the `/setup-project` contract:

- **Never overwrite** `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` / `.claude/CLAUDE.md` / root `CLAUDE.md` if they already exist (the root file is `project-profiler`'s own refusal, but the rule is the same).
- **Never weaken** an existing `.npmrc` (no `audit-level` downgrade, no `minimum-release-age` reduction).
- **Never reconfigure under `--yes` / `ATELIER_AUTO`**: re-running on a configured project in non-interactive mode exits with code 2.
- **Never run `git init`** or any git write — `/setup-project` is for atelier scaffolding only.
- **Never draft `CLAUDE.md` content inline from this slash command**, even when the project is "obviously simple". Drafting is `project-profiler`'s job — the agent returns the content; this slash command writes it. The `Write` call from here uses the agent-returned content verbatim; no editorial pass, no embellishment.
- **Never write `CLAUDE.md` without first dispatching `project-profiler`.** If the agent dispatch fails or returns a malformed report (no `## Drafted content` block when status is `drafted`), surface the failure and stop. Do not fabricate content to "rescue" the flow.
- **Never invoke `Edit`, `mkdir`, `sed`, or `jq` directly from this slash command.** Phase 1's file work happens inside the bash helper. Phase 2's only allowed writes are: (a) `Write(<abs>/CLAUDE.md, <agent-returned-content>)` and (b) nothing else.
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

