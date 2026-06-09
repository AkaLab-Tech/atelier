# Roadmap

Backlog of work for this project. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Each task lives here as a heading with whatever description it needs (acceptance criteria, design notes, sub-tasks). When work starts, move the block to `IN_PROGRESS.md`.

Tasks are derived from the implementation plan in [PLAN.md §12](PLAN.md). Milestone IDs (M1.1, M2.3, …) refer to that plan and are kept in titles for traceability. Always read the referenced PLAN.md section before starting a task.

---

## High Priority

> **Phase 1 — Foundation.** Blocks everything else. A fresh Mac must be able to run `install.sh`, log in to Claude + GitHub, and end with the `atelier` plugin installed and `/doctor` ✅.

> **Install hardening from M7.1 dogfood-2 + dogfood-3 (2026-05-23 / 2026-05-25).** Findings F1–F12 surfaced during dogfood-2 full-wipe reinstall. F11b discovered during PR-C validation. F13 + F7c discovered during dogfood-3 setup. F14 + F15 + F16 discovered during the dogfood-3 first `/atelier:doctor` run. Closed: PR-A [#70](https://github.com/AkaLab-Tech/atelier/pull/70) (F6+F7a+F9+F11, v0.4.2), PR-B [#72](https://github.com/AkaLab-Tech/atelier/pull/72) (F2+F5+F10+F12), PR-C [#73](https://github.com/AkaLab-Tech/atelier/pull/73) (F1+F3+F4+F8), PR-D [#74](https://github.com/AkaLab-Tech/atelier/pull/74) (F11b), PR-E [#75](https://github.com/AkaLab-Tech/atelier/pull/75) (F7b, v0.5.0), PR-F [#76](https://github.com/AkaLab-Tech/atelier/pull/76) (F13 atelier() shortcut). PR-G (PR _pending_) closes F16 (doctor.md allowed-tools, v0.5.1). F7c + F14 + F15 remain as follow-ups (see entries below).

> **Dogfood bugs — orchestrator behavior (2026-06-05).** Two correctness bugs found while running real atelier task chains: the orchestrator doing specialist work inline instead of delegating (F52), and the operator's personal `CLAUDE.md` leaking confirmation gates into the autonomous flow (F53).

### M7.1.F52 — Orchestrator performs specialist work inline instead of delegating

`[orchestrator]` · Source: dogfood (2026-06-05) · **Partially addressed** by [M7.1.F55](HISTORY.md) ([#142](https://github.com/AkaLab-Tech/atelier/pull/142)) — the `pr-author`-authoring slice (re-dispatch instead of absorb) is covered; the broader hardening below stays open.

The `task-orchestrator` ([agents/task-orchestrator.md](agents/task-orchestrator.md)) is specified as a planner/router that "does not write feature code, tests, or PR descriptions itself" and delegates to `implementer` → `tester` → `pr-author`. In real chains it sometimes does the work itself and ends up asking the operator implementation-level questions, bypassing the specialist boundary entirely. This collapses the per-agent safety scoping and the auditable chain checkpoints the design relies on.

**Scope:**

- [ ] Reproduce: capture a chain where the orchestrator skips a `Task` dispatch and acts inline (which step, what triggered it).
- [ ] Reinforce the delegation contract in the orchestrator prompt — make "never implement/test/author inline; always dispatch the specialist via `Task`" a hard refusal, not just a prose description.
- [ ] Close the gap that lets implementation-level questions reach the operator: genuine ambiguity routes through `decision-broker` or surfaces as a terminal state, never as an inline operator question.
- [ ] Consider a guard: if the orchestrator is about to edit source files or write tests directly, treat it as a bug and stop.

**Acceptance:** on a representative ROADMAP task, the orchestrator dispatches `implementer` / `tester` / `pr-author` via `Task` for all code/test/PR work and never edits source or asks implementation-level questions itself; any genuine ambiguity goes through `decision-broker` or a terminal hand-off.

**Trigger to revisit:** captured 2026-06-05 from live dogfooding. Fix before further orchestrator-flow work so the delegation boundary is trustworthy.

### M7.1.F53 — Operator's personal `CLAUDE.md` blocks the autonomous commit/push/merge flow

`[orchestrator]` `[config-isolation]` · Source: dogfood (2026-06-05) · Related: [operator-rules.md:166](operator-rules.md#L166) (`CLAUDE_CONFIG_DIR` separation)

During a chain the orchestrator asks the operator to confirm **commit + push + merge**, citing the operator's *personal* `CLAUDE.md` directives (e.g. "never push without explicit confirmation", "never commit on protected branches", "ask before destructive commands"). Those directives live in the operator's personal Claude config — **not** atelier's — and must not govern atelier's autonomous flow, whose gates are defined by atelier itself (push gate, PR gate, `auto-merge` skill, [PLAN.md §6](PLAN.md)). This is a config-isolation bug: the `$ATELIER_CONFIG_DIR` (`~/.claude-work/`) separation documented in [operator-rules.md:166](operator-rules.md#L166) is meant to prevent exactly this, yet the personal `CLAUDE.md` is still in the session's context.

**Scope:**

- [ ] Determine how the personal `CLAUDE.md` (`~/.claude/CLAUDE.md` and/or `~/.claude-personal/CLAUDE.md`) reaches an `atelier()`-launched session despite `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR`.
- [ ] Ensure atelier sessions do not inherit personal global/project `CLAUDE.md` confirmation rules that conflict with the autonomous flow (config root, working dir, or memory-loading path — whichever is the actual leak).
- [ ] Make atelier's own rules authoritative for commit/push/merge: the orchestrator must not re-prompt for confirmation on actions the static matrix + gates already authorize (mirrors the existing "do not re-prompt after `auto-merge`'s positive verdict" rule).
- [ ] Document the precedence in `operator-rules.md` so future drift is caught.

**Acceptance:** an `atelier()` task chain commits to `task/<id>-<slug>`, pushes, and reaches the `auto-merge` gate without surfacing a confirmation prompt sourced from the operator's personal `CLAUDE.md`; atelier's gates remain the only authority on those actions.

**Trigger to revisit:** captured 2026-06-05 from live dogfooding. Marked a bug by the operator.

---

## Medium Priority

> **Phases 2–5 — Single-project agent flow + robustness + multi-project foundation.** Done when the toy-repo flow can pick a task, implement it, open a reviewed PR, auto-merge it, clean up, and survive failures with retries — and when an operator can install / uninstall atelier without risking unrelated Claude state.

### M7.1.F54 — Coolify skill assumes manual deploy; must detect GitHub App auto-deploy

`[coolify-integration]` · Source: dogfood (2026-06-05) · **Change lands in the `coolify-integration` repo** ([skills/coolify/SKILL.md](../coolify-integration/skills/coolify/SKILL.md)), tracked here per the operator's decision.

The coolify skill's validate-and-fix flow assumes a deploy is always triggered manually via `atelier-coolify deploy <uuid>`. In practice the apps are wired through Coolify's GitHub App so that a push to `main` (or the per-env branch) **auto-deploys** — assuming a manual deploy is wrong, can double-trigger, and misleads diagnosis. The skill should read the app's deployment configuration (connected git source, auto-deploy flag, watched branch) and remember that a push already deploys, instead of assuming.

**Scope:**

- [ ] Add a way to read an app's git/auto-deploy config via `atelier-coolify` (git source connected, auto-deploy enabled, watched branch) — new subcommand or extend `status` / `validate` output.
- [ ] Update the skill flow: before suggesting a manual `deploy`, check whether the app auto-deploys on push; if so, a `git push` to the watched branch *is* the deploy — say so rather than calling `deploy`.
- [ ] Persist / record the per-app deploy mode so the skill does not re-assume on every run (skill guidance + where the fact is stored).
- [ ] Keep the manual `deploy <uuid>` path for apps that genuinely lack auto-deploy.

**Acceptance:** on an app configured with the GitHub App + auto-deploy on a branch, the skill reports that pushing the watched branch deploys (and does not propose a redundant manual `deploy`); on an app without auto-deploy, the manual flow is unchanged.

**Trigger to revisit:** captured 2026-06-05 from live dogfooding. The fix is in `coolify-integration` but tracked here per the operator's decision.

### M4.29 — Import an existing operator's Claude conversations on first atelier use

`[onboarding]` · Source: operator request (2026-06-05) · Related: [operator-rules.md:166](operator-rules.md#L166) (`CLAUDE_CONFIG_DIR` separation), M7.1.F53

Atelier runs under a config root (`$ATELIER_CONFIG_DIR`, default `~/.claude-work/`) **separate** from the operator's personal `~/.claude/`. A side effect for someone who already uses Claude Code: their existing conversation history lives under the personal root (`~/.claude/projects/<cwd-hash>/*.jsonl`) and does **not** appear in atelier sessions — `claude --resume` / `--continue` inside an `atelier()` session sees an empty history. This makes adopting atelier feel like starting from scratch. Give the operator a way to bring their prior conversations across so they are not lost.

**Scope:**

- [ ] Decide the import mechanism: copy vs symlink the per-project transcript dirs (`projects/<cwd-hash>/`) from `~/.claude/` into `$ATELIER_CONFIG_DIR/`. Weigh that `<cwd-hash>` is path-derived — same working dir hashes the same under both roots, so transcripts map 1:1.
- [ ] Make it opt-in and selectable: import all projects, or pick specific project dirs (the operator may not want every personal conversation inside atelier).
- [ ] Decide the entry point: a step in `install.sh` onboarding and/or a dedicated `atelier-import-conversations` helper + `/atelier:import-conversations` command for later runs.
- [ ] Be non-destructive: never move or delete from the personal root; never overwrite an atelier transcript that already exists.
- [ ] Scope to conversation transcripts only — do **not** import personal `CLAUDE.md`, memory, or settings (those must stay isolated; importing them would re-introduce the leak M7.1.F53 fixes).
- [ ] Document in the operator guide what is and isn't imported, and that it is a one-time/opt-in convenience.

**Acceptance:** an operator with prior `~/.claude/` conversations runs the import (at install or via the command) and, inside an `atelier()` session for the same project, `claude --resume` lists those prior conversations; the personal root is untouched and no personal `CLAUDE.md` / settings cross over.

**Trigger to revisit:** requested by the operator 2026-06-05 while reasoning about the personal-vs-atelier config split. Natural companion to M7.1.F53 — same separation boundary, opposite direction (F53 keeps personal *rules* out; this lets personal *history* in, deliberately and scoped).

### M5.4 — Daily housekeeping of worktrees + local/remote branches (operator-authorized)

`[maintenance]` · Source: operator request (2026-06-05) · Related: [skills/auto-merge/SKILL.md](skills/auto-merge/SKILL.md) (post-merge cleanup), [agents/task-orchestrator.md](agents/task-orchestrator.md) (worktree-as-evidence on blocked/oversize)

Today cleanup is per-task: `auto-merge` removes the worktree and deletes the remote branch right after a successful squash-merge. Anything that falls outside that happy path accumulates — abandoned task worktrees, local `task/*` branches whose PR merged elsewhere, stale `origin/task/*` remotes. Atelier should run a **daily** housekeeping sweep that proposes what to clean, shows the operator a full summary, and acts **only** after explicit authorization.

**Scope:**

- [ ] An `atelier-housekeeping` helper that enumerates removable items in the registered projects/worktrees:
  - **Worktrees** with no active/blocked/oversize task (cross-checked against `IN_PROGRESS.md` markers — never a worktree that is task evidence).
  - **Local branches** that are fully merged into `main` (or whose PR is merged/closed) and are not checked out.
  - **Remote branches** (`origin/task/*`) whose PR is merged/closed.
- [ ] **Daily cadence, not per-session spam:** gate on a last-run timestamp (e.g. a `SessionStart` check that fires the sweep at most once per calendar day; record the stamp under `$ATELIER_CONFIG_DIR`). Decide whether a scheduled job is in scope or the session-gated check suffices.
- [ ] **Always ask first:** present a summary grouped by category — the exact list of worktrees, local branches, and remote branches that would be deleted, with why each is removable — then require explicit authorization (single confirm; ideally per-category or per-item opt-out) before touching anything.
- [ ] **Hard safety rails:** never delete protected branches (`main`/`master`/`develop`/`staging`), never delete a branch/worktree with an open PR, never remove a worktree backing an `[BLOCKED]` or `[OVERSIZE]` entry, never force-delete unmerged work without an explicit operator override.
- [ ] A manual entry point too (`/atelier:housekeeping` or similar) so the operator can run the sweep on demand, not only on the daily trigger.
- [ ] Document the cadence, what counts as removable, and the safety rails in the operator guide.

**Acceptance:** with a stale merged `task/*` branch, its merged `origin/task/*` remote, and an orphan worktree present, the daily sweep (or manual command) lists all three in a categorized summary, deletes them only after the operator authorizes, and leaves untouched any protected branch, open-PR branch, or worktree backing a blocked/oversize task; re-running the same day does not re-prompt.

**Trigger to revisit:** requested by the operator 2026-06-05 — wants worktrees and local/remote branches kept tidy automatically, but always behind an authorized summary rather than silent deletion.

### M4.30 — Plan-gated execution: orchestrator only claims pre-planned, approved tasks

`[orchestrator]` `[planning]` · Source: operator request (2026-06-08) · Related: [PLAN.md §5](PLAN.md) (ROADMAP format + selection order), [agents/task-orchestrator.md](agents/task-orchestrator.md) (steps 1/4/5), [agents/task-decomposer.md](agents/task-decomposer.md), `task-discovery` skill

Today the `task-orchestrator` picks the highest-priority unchecked ROADMAP item and improvises its plan at execution time (only `task-decomposer` fires, and only for oversize-likely tasks — M4.24.b). The operator, who is non-technical, is then asked to confirm a plan they have no basis to evaluate. Invert this: **planning is a separate, explicit, product-lead-owned step that commits an approved plan into the repo, and the orchestrator only ever claims tasks that already carry one.** The orchestrator must never author or improvise a plan; an unplanned task is simply not claimable.

**Design (per operator decision 2026-06-08):** a dedicated **planner agent** invoked by the product lead via **`/plan-task <id>`**. The planner reads the task + scans the codebase and produces a concrete plan (approach, affected files/areas, acceptance criteria, decomposition into sub-tasks if oversize, risks/open questions). The product lead reviews and approves; approval commits the plan and marks the task **`[ready]`**. The orchestrator selects only `[ready]` items.

**Scope:**

- [ ] **Planner agent** (`agents/planner.md`, Opus): reads a ROADMAP task, scans the repo, emits a structured plan. Does **not** write code. Subsumes / coordinates with `task-decomposer` for the oversize-split case (avoid two competing decomposition paths — decide whether the planner calls the decomposer or replaces its auto-trigger).
- [ ] **`/plan-task <id>` command** driven by the product lead: dispatches the planner, presents the draft, and on explicit product-lead approval commits the plan + flips the task to `[ready]`. Where the plan lives: inline in the ROADMAP block vs. an indexed `roadmap/TASK_NNN` file vs. a `.plan/` artifact — decide and document.
- [ ] **`[ready]` marker convention** added to [PLAN.md §5](PLAN.md): how readiness is written, how it interacts with `[ ]`/`[x]`/epic-derived checkboxes and `blocked_by`.
- [ ] **Orchestrator gate** ([agents/task-orchestrator.md](agents/task-orchestrator.md) step 1 + step 4): `task-discovery` selects only `[ready]` items; the orchestrator **refuses** an explicitly-named un-`[ready]` task with a clear message (*"task #<id> is not planned — run `/plan-task <id>` first"*), and **never** improvises a plan or asks the operator to approve one. Remove/replace the step-4 auto-decompose trigger accordingly.
- [ ] **`task-discovery` skill**: teach it the `[ready]` filter so auto-pick skips unplanned items the same way it skips `blocked_by`.
- [ ] **Operator/product-lead docs**: document the plan→approve→execute split and that the operator no longer approves improvised plans (ties into the M6.3 product-owner guide).

**Acceptance:** an un-`[ready]` ROADMAP task is never auto-picked and is refused on explicit pick with a pointer to `/plan-task`; running `/plan-task <id>`, having the product lead approve, commits a plan and marks the task `[ready]`; the orchestrator then claims it and runs the specialist chain **without** authoring its own plan or asking the operator to approve one.

**Trigger to revisit:** requested by the operator 2026-06-08 — the operator cannot meaningfully approve plans the orchestrator improvises, so planning must move upstream to the product lead. Natural follow-on to M7.1.F52 (orchestrator over-reaching into work that isn't its own).

---

## Phase 8 — Multi-repo workspaces ✅

> **Complete (M8.1–M8.7).** Group several single-repo projects into a "workspace" (e.g. backend + frontend + CMS): the `/setup-workspace` → `/list-workspaces` → `/remove-workspace` lifecycle, aggregated `/workspace-status`, root-level `task` routing, and *sequenced* cross-repo `blocked_by:<token>#id` dependencies enforced offline — **without** ever introducing cross-repo atomicity (each task stays one worktree / one PR). Design: [PLAN.md §15](PLAN.md); delivery log (M8.1–M8.7) in [HISTORY.md](HISTORY.md).

---

## Low Priority / Ideas

> **Phases 5–7 + deferred v2 patterns.** Multi-project, docs, end-to-end validation, and the OMC-borrowed ideas from PLAN.md §11.

### M4.4 — Blocked-task visibility in `/status`

Extend the existing `/status` command so it also lists tasks currently marked `[BLOCKED]` in `IN_PROGRESS.md`, with their issue URL and the count of attached `.task-log/*.md` entries. Today the operator only sees blocked tasks by filtering GitHub Issues by label `blocked` or by reading `IN_PROGRESS.md` manually — neither is discoverable from inside a Claude session.

**Acceptance:** `/status` on a project with N blocked tasks prints `Blocked: N` followed by one line per task with `<id> — <title> — <issue-url>`.

**Trigger to revisit:** when the operator starts having more than ~2 blocked tasks open simultaneously and finding them becomes friction. Identified while designing M4.2 — deferred because the M4.2 + M4.3 loop is functional without it; this is pure quality-of-life.

### M4.5 — `/abandon-task <id>`

A slash command for the Camino C of the blocked-task lifecycle (operator decides the task will not be retried). Today this requires the operator to (a) close the GitHub `blocked` issue with a `wontfix` comment and (b) manually move the entry from `IN_PROGRESS.md` to `HISTORY.md` with an "abandoned" note. The command automates both steps:

1. Close the GitHub `blocked` issue with a `wontfix` reason comment.
2. Move the `[BLOCKED]` entry from `IN_PROGRESS.md` to `HISTORY.md` under an explicit `### <id> — <title> — abandoned — <date>` heading.
3. Preserve the `.task-log/` directory inside the worktree (post-mortem evidence stays in case the task is ever revived) and `git wt rm` the worktree only after the operator confirms.

**Acceptance:** running `/abandon-task <id>` on a `[BLOCKED]` entry closes the issue with `wontfix`, moves the entry to `HISTORY.md` with `abandoned` mark, and removes the worktree (with confirmation).

**Trigger to revisit:** after M4.2 + M4.3 land and the operator hits a real "I'm not retrying this" situation. Identified while designing M4.2 — deferred because the manual workaround (close issue + edit two markdown files) works fine for the rare case where a task is genuinely abandoned.

### M4.21 — `/validate` Python toolchain in `allowed-tools` frontmatter

`commands/validate.md` (added in [M4.14](HISTORY.md) / PR #65) detects Python-project tooling in its body (`ruff` for lint, `mypy` / `pyright` for typecheck, `pytest` for tests via `pnpm` script) but its `allowed-tools` frontmatter only explicitly grants the JS/TS toolchain (`Bash(eslint:*)`, `Bash(biome:*)`, `Bash(tsc:*)`, `Bash(vitest:*)`, `Bash(jest:*)`, etc.) plus a single `Bash(pytest:*)` and `Bash(playwright:*)`. Missing: `Bash(ruff:*)`, `Bash(mypy:*)`, `Bash(pyright:*)`.

Concrete effect on a Python project: the first time `/validate` tries to invoke any of those three tools, the Claude Code harness prompts the operator for permission ("Allow `Bash(ruff check)` once / always?"). Same outcome as Phase 0 of any new permission — not broken, just interactive. The inner loop ([M4.14](HISTORY.md)) under `claude -p` would stall on that prompt.

**Scope:**

- [ ] Add `Bash(ruff:*)`, `Bash(mypy:*)`, `Bash(pyright:*)` to `commands/validate.md` frontmatter `allowed-tools`.
- [ ] Sanity check: any other Python-friendly invocations the body uses (e.g. `pnpm` is already covered; if `pdm` / `uv` / `poetry` are later added to the detection logic, allowlist those too).
- [ ] No behavior change — purely a permission-prompt prevention.

**Acceptance:** running `/atelier:validate` against a Python project (`pyproject.toml` with `[tool.ruff]` + `[tool.mypy]`) under `claude -p` completes without a permission prompt for any of the three tools. Static check: `grep -E "Bash\\(ruff|Bash\\(mypy|Bash\\(pyright" commands/validate.md` returns 3 matches.

**Trigger to revisit:** when the first Python project gets `/atelier:setup-project`-ed and `/validate` runs against it. Until atelier sees a Python project in real use, this is purely defensive — captured here so the next operator who hits the prompt knows the fix is one frontmatter edit. Identified during PR #65 pre-merge review (2026-05-23).

### M4.15 — `Stop`-hook auto-reprompt on validation failure (exceptional path)

`blocked_by: M4.14`

Complement to M4.14. Where M4.14 puts the implement↔validate loop inside `task-orchestrator` (the orchestrator reads the validation output and decides whether to re-invoke `implementer`), M4.15 explores doing the same thing one layer lower — at the harness level, via a `Stop` hook that triggers automatically when an assistant turn ends with a failed validation.

The hook script:

1. Detects that the last turn ran `/validate` (or `/validate --full`) and the exit was failure.
2. Reads `<worktree>/.task-log/attempt-count` and increments it. If the count exceeds the 3+3 budget, the hook does **nothing** — the orchestrator-side `blocked` issue path takes over.
3. Emits a structured retry prompt back to Claude containing:
   - An explicit `RETRY-attempt-N / 6` header (so the model knows this is not a fresh task and how much budget remains).
   - The full output of the failed validation (stdout + stderr from the failing checks) verbatim.
   - A directive: *"the previous attempt failed the checks below — correct the issues without restarting the task; do not reset the worktree".*

This is **not** the primary loop mechanism (M4.14 is). It is captured as an alternative for cases where the orchestrator-driven loop is too high-latency (long agent dispatch overhead per turn) or where the operator wants the loop to keep running across session restarts without re-entering `/next-task`.

**Acceptance:**

- A `Stop` hook script under `hooks/` detects validation-failure conditions and emits a structured retry prompt with `RETRY-attempt-N` framing and the previous validation output verbatim.
- The hook respects the same 3+3 budget anchored to `<worktree>/.task-log/attempt-count` (the file written by M4.14) — never exceeds it, never bypasses the `blocked` issue path.
- Hook is **opt-in** (off by default), enabled via a per-project setting or env var — atelier ships without it active to avoid surprising the operator.
- When active, the hook composes with M4.14 cleanly (no double-incrementing the counter, no race between orchestrator-driven and hook-driven reprompts).

**Trigger to revisit:** after M4.14 is in production and the operator observes that orchestrator dispatch latency dominates iteration time, **or** wants the loop to survive a session restart. Captured in conversation 2026-05-21 as an exceptional-case mechanism — the operator likes the idea but explicitly tagged it as "for later".

### M6.3 — Product owner guide (ROADMAP.md format)

How to write [PLAN.md §5](PLAN.md)-shaped roadmaps: priorities, types, estimates, `blocked_by`, acceptance criteria. With examples.

### M7.1 — Dogfood on a real (non-toy) project

Run a full task cycle on an actual project. Capture friction.

### M7.2 — Iterate the network allowlist

Grow the allowlist organically based on what M7.1 needs. Document each addition with a one-line justification.

### v2 ideas (deferred)

Per [PLAN.md §11](PLAN.md). Revisit only after v1 is stable.

- v2.1 — Skill auto-injector hook (`UserPromptSubmit`) to load skills by context signals.
- v2.2 — Router skill with subcommands (`/atelier setup|doctor|update|reconfigure`).
- v2.3 — `PermissionRequest` Bash hook for dynamic permissions, replacing static `settings.template.json`.
- v2.4 — Project-memory hooks (`SessionStart` + `PostToolUse`) to auto-persist project learnings.
- v2.5 — `/learner` + `/skillify` to extract reusable patterns from successful tasks.
- v2.6 — Node.js hook dispatcher (`scripts/run.cjs`) for portable, fail-open hook execution.

### Out of scope for v1

Per [PLAN.md §11](PLAN.md). Listed here so they are not picked up by accident: **atomic** cross-repo changes (one task/PR spanning multiple repos — note that multi-repo *workspaces* with sequenced cross-repo dependencies are now in scope, see Phase 8 / [PLAN.md §15](PLAN.md)), deployment/release management, cost monitoring / per-task budgets, visual regression baselines, ROADMAP ↔ Issues bidirectional sync.
