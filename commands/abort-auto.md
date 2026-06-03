---
description: Panic switch for the decision broker (M4.26.d). Defers every subsequent strategic decision in the current task worktree back to the operator via `AskUserQuestion`, regardless of the project's `decisionPolicy` configuration in `.atelier.json`. Use this when a task starts going sideways under `auto` policy and the operator wants every remaining decision routed through them — without aborting the task itself. The flag persists across specialist dispatches inside the worktree; clear it with `/atelier:resume-auto` when the operator is ready to hand decisions back to the broker.
allowed-tools: Bash(git rev-parse:*), Bash(touch:*), Bash(test:*), Bash(date:*), Write, Read
---

You are running the `/atelier:abort-auto` slash command. Your job is to write the panic flag at `<worktree>/.atelier-abort-auto.flag` and report back. You do **not** modify task state, you do **not** invoke any specialist agent, you do **not** read the catalog. Single-purpose command.

## What the flag means

The `decision-broker` skill (M4.26.a) checks `<worktree>/.atelier-abort-auto.flag` as the first step of every resolution. If the file exists, the skill returns `mode: panic` regardless of the catalog entry, the project's `.atelier.json`, or any environment-variable override. The caller then falls back to `AskUserQuestion` exactly as the pre-broker behaviour.

The flag is **per-worktree**, not per-project or per-session. A task chain operating inside `<project>-worktrees/task-42-feature/` is affected; a parallel chain in `<project>-worktrees/task-43-bugfix/` is not. This matches the auditability scope — every decision the broker logs is keyed to a single worktree's `.task-log/decisions.jsonl`.

## What to do

1. **Resolve the worktree root.** You are inside an `atelier`-launched Claude session; the cwd is the worktree the operator entered (the orchestrator pinned it during step 2 of the chain). Run `Bash(git rev-parse --show-toplevel)` to capture the absolute path. If the command fails (not a git worktree), surface clearly: *"Not inside a git worktree. `/atelier:abort-auto` only makes sense inside an active task worktree."* and stop.

2. **Check if the flag already exists.** Run `Bash(test -f "<worktree>/.atelier-abort-auto.flag" && echo exists || echo absent)`. If `exists`, report idempotently: *"Panic switch already active for `<worktree>`. The broker will continue to defer every decision until you run `/atelier:resume-auto`."* and stop.

3. **Write the flag.** Use `Write` against `<worktree>/.atelier-abort-auto.flag`. Body: a single line capturing the timestamp the flag was written, the user-visible reason if the operator provided one as `$ARGUMENTS`, and the schema version. Format:

   ```text
   atelier-panic-version: 1
   ts: <ISO 8601 UTC timestamp from `date -u +%FT%TZ`>
   reason: <$ARGUMENTS or "operator-initiated">
   ```

   The broker only checks the file's *existence*, not its content — the metadata is for audit purposes. Do NOT use `Bash(touch:*)` for the write; `Write` ensures the change goes through atelier's standard write path (M2.4 hooks apply, settings allow/deny matrix applies).

4. **Report back.** Print exactly:

   ```text
   ✓ panic switch ACTIVE for <worktree>
   
   The decision broker will now route every strategic decision in this
   worktree back to you (via AskUserQuestion), regardless of
   .atelier.json's decisionPolicy. To resume autonomous decisions, run:
   
       /atelier:resume-auto
   ```

## Hard refusals

- **Never** touch any other file. `.atelier-abort-auto.flag` is the only file this command writes.
- **Never** invoke `task-orchestrator`, `pr-author`, the broker skill, or any specialist agent. The panic switch is configuration-only; the orchestrator decides what to do next on its own next turn.
- **Never** disable or remove the flag from this command. `/atelier:resume-auto` owns the clear path; mixing the two surfaces in one command would defeat the explicit-action contract.
- **Never** write the flag outside the current worktree. If `git rev-parse --show-toplevel` resolves to a path that is not under `~/Work` (or wherever the operator's projects live), still write — but the broker's own check is what enforces the worktree scope, not this command.

## Edge cases

- **Operator passes free text as `$ARGUMENTS`**: capture it verbatim in the `reason:` field of the flag file. Length cap at 200 characters; truncate longer input with `...` and surface the truncation in the report.
- **The worktree is on `main` / `master` / `develop` / `staging`**: still write the flag — the operator may be testing the panic switch outside a task chain. Surface a one-line warning in the report: *"Note: you are on a protected branch; `/atelier:abort-auto` was intended for task worktrees but the flag was written anyway."*
- **The .atelier-abort-auto.flag file is malformed or empty from a previous bad write**: do NOT preserve it. Overwrite with the fresh-format content.
