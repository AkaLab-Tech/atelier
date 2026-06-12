# Roadmap

Backlog of work for this project. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Each task lives here as a heading with whatever description it needs (acceptance criteria, design notes, sub-tasks). When work starts, move the block to `IN_PROGRESS.md`.

Tasks are derived from the implementation plan in [PLAN.md §12](PLAN.md). Milestone IDs (M1.1, M2.3, …) refer to that plan and are kept in titles for traceability. Always read the referenced PLAN.md section before starting a task.

---

## High Priority

> **Phase 1 — Foundation.** Blocks everything else. A fresh Mac must be able to run `install.sh`, log in to Claude + GitHub, and end with the `atelier` plugin installed and `/doctor` ✅.

> **Install hardening from M7.1 dogfood-2 + dogfood-3 (2026-05-23 / 2026-05-25).** Findings F1–F12 surfaced during dogfood-2 full-wipe reinstall. F11b discovered during PR-C validation. F13 + F7c discovered during dogfood-3 setup. F14 + F15 + F16 discovered during the dogfood-3 first `/atelier:doctor` run. Closed: PR-A [#70](https://github.com/AkaLab-Tech/atelier/pull/70) (F6+F7a+F9+F11, v0.4.2), PR-B [#72](https://github.com/AkaLab-Tech/atelier/pull/72) (F2+F5+F10+F12), PR-C [#73](https://github.com/AkaLab-Tech/atelier/pull/73) (F1+F3+F4+F8), PR-D [#74](https://github.com/AkaLab-Tech/atelier/pull/74) (F11b), PR-E [#75](https://github.com/AkaLab-Tech/atelier/pull/75) (F7b, v0.5.0), PR-F [#76](https://github.com/AkaLab-Tech/atelier/pull/76) (F13 atelier() shortcut). PR-G [#77](https://github.com/AkaLab-Tech/atelier/pull/77) closes F16 (doctor.md allowed-tools, v0.5.1). F7c + F14 + F15 closed 2026-05-26 — see [HISTORY.md](HISTORY.md). **All Phase 1 hardening findings resolved.**

> **Dogfood bugs — orchestrator behavior (2026-06-05).** Two correctness bugs found while running real atelier task chains: the orchestrator doing specialist work inline instead of delegating (F52), and the operator's personal `CLAUDE.md` leaking confirmation gates into the autonomous flow (F53). Both resolved — see [HISTORY.md](HISTORY.md).

> **Reviewer access on fresh private repos (2026-06-09).** F56 — the independent `reviewer` identity could not see freshly-created private repos, so the auto-merge review step failed silently. Resolved — see [HISTORY.md](HISTORY.md).

---

## Medium Priority

> **Phases 2–5 — Single-project agent flow + robustness + multi-project foundation.** Done when the toy-repo flow can pick a task, implement it, open a reviewed PR, auto-merge it, clean up, and survive failures with retries — and when an operator can install / uninstall atelier without risking unrelated Claude state.

### M7.4 — Detect + migrate non-§5 task ids in a project's ROADMAP

**Found during M7.1 dogfood (storefront, 2026-06-10).** A real project's `ROADMAP.md` used a hierarchical, phase-prefixed id scheme (`RLS.2`, `WEB.5g`, `BUG-RESILIENCE.2`) instead of the numeric `#NN` / `#NNa` convention PLAN.md §5 defines. The planning gate (M4.30) enforces §5 via `plan-task` (`^#?\d+[a-z]?$`) and `slice-task` (`^#?\d+$`), so **no task in such a project is plannable → none is claimable by the orchestrator**. RLS.2 only shipped because it predated M4.30. This is **not** a bug in `plan-task` (§5 is numeric by design); it is a project whose ids drifted from the convention, which atelier should detect and migrate — the same way the operator migrated tracking layouts via `migrate-roadmap`.

**Design (two parts):**

1. **Detection — `atelier-doctor` per-project check.** Doctor already iterates `projects.json`. Add a check that parses each registered project's `ROADMAP.md` and flags task ids that do not match §5 (`#NN` / `#NNa`). Emit `✗` with the count and a pointer to the migration. Same per-check-independence contract as the rest of the binary.
2. **Migration — `atelier-migrate-task-ids <project>`** (analogous to `migrate-roadmap`). Assign sequential `#NN` ids preserving section/priority order and epic structure (epic `#NN` + sub-tasks `#NNa`/`#NNb`), rewrite `ROADMAP.md` + `IN_PROGRESS.md`, rewrite `blocked_by:` references through the same mapping, and emit a traceability map (`RLS.2 → #5`).

**Open design questions to resolve when planned:**
- **`HISTORY.md` is an immutable log** of merged PRs. Decide whether to rewrite historical ids or preserve them with a forward-mapping table (leaning preserve + map).
- **Live branches / open PRs** (`task/RLS.2-rls-policies`, PR #132) carry the old id. Decide whether the migration re-maps them or leaves them as legacy with a recorded mapping.
- Interaction with the **`[ready]` / `.plan/<id>.md`** artifacts already on disk for a partially-planned project.

**Acceptance:** `atelier-doctor` flags a project whose ROADMAP uses non-§5 ids; `atelier-migrate-task-ids <project>` converts them to §5 ids across `ROADMAP.md` + `IN_PROGRESS.md` with `blocked_by:` updated and a printed mapping, leaving `HISTORY.md` handled per the resolved design question. Idempotent: a second run on an already-§5 ROADMAP is a no-op.

**Note:** this task should itself be planned via `/atelier:plan-task` once it carries a §5 id — a small irony worth preserving as the first dogfood of the very gate it unblocks.

---

## Phase 8 — Multi-repo workspaces ✅

> **Complete (M8.1–M8.7).** Group several single-repo projects into a "workspace" (e.g. backend + frontend + CMS): the `/setup-workspace` → `/list-workspaces` → `/remove-workspace` lifecycle, aggregated `/workspace-status`, root-level `task` routing, and *sequenced* cross-repo `blocked_by:<token>#id` dependencies enforced offline — **without** ever introducing cross-repo atomicity (each task stays one worktree / one PR). Design: [PLAN.md §15](PLAN.md); delivery log (M8.1–M8.7) in [HISTORY.md](HISTORY.md).

---

## Low Priority / Ideas

> **Phases 5–7 + deferred v2 patterns.** Multi-project, docs, end-to-end validation, and the OMC-borrowed ideas from PLAN.md §11.

### Idea — first-class `High`/`Medium`/`Low` ROADMAP layout for operator projects (M7.1.F68 option B)

Surfaced designing the F68 fix. Today operator projects must use the PLAN.md §5 layout (`P0`/`P1`/`P2` + backtick type tags + `#id` + `~estimate` + `[ready]`) for `task-discovery` / `/atelier:next-task`; real teams' roadmaps use simpler `High`/`Medium`/`Low` + checkboxes (which `/adopt-roadmap`'s default and `claude-roadmap-tools` produce). **Option B** was to make atelier's `task-discovery` accept the `High`/`Med`/`Low` layout natively for operator projects too — applying the `[ready]` planning gate there and treating `type`/`estimate` as optional — instead of requiring the §5 conversion (option A, shipped in claude-roadmap-tools #15). It would cut onboarding friction (no §5 rewrite) and meet teams where they are, but it **changes a decided spec (PLAN.md §5)**, so it is a product-design conversation, not a quick fix. Revisit once the §5 + `--format atelier` path has real mileage and we can judge whether the §5 metadata (type/estimate/priority granularity) earns its onboarding cost.

### Idea — actionable "nothing planned" dead-end: surface plan candidates

Surfaced finishing M7.1: when `/atelier:next-task` finds no `[ready]` task it stops with a bare "run `/atelier:plan-task` first" error. Instead, make the dead-end **actionable** — hand the operator a ranked shortlist of what to plan next, so `task` always returns something useful (either a started task or a precise "plan one of these").

**Where it lives:** in `task-discovery` + `/next-task`'s no-eligible-task path — **not** the `task-orchestrator` (the orchestrator is only dispatched *after* a task is claimed; with nothing claimable it never runs). `task-discovery` already parses the whole ROADMAP and knows each item's `[ready]` state, so it has the data — it just needs to **return the unplanned candidates** instead of only an error.

**Smart dead-end, by ROADMAP state:**
- **§5 backlog with unplanned candidates** → ranked shortlist (P0 > P1 > P2, tie-break by *no open `blocked_by`*), each line `#id · title · priority · why-not-ready`, suggesting `/atelier:plan-task #X`.
- **Non-§5 ROADMAP** (nothing parseable) → suggest `/adopt-roadmap --format atelier` first (the deminut state today).
- **Empty backlog** → say so.

**Interaction:**
- **Interactive** → offer to plan one now (`AskUserQuestion` → dispatch `/atelier:plan-task #X`).
- **Headless** (`ATELIER_AUTO`) → only print the list; never auto-plan — approving a plan is a human gate by design.

**Trigger to revisit:** soon — it directly improves the most common autonomous dead-end (validated live during M7.1: a real run on deminut hit exactly this, and an ad-hoc list was helpful but not guaranteed).

### Idea — `/setup-project` detects CI/CD and offers to scaffold it per stack

`/atelier:setup-project` should check whether the project has CI/CD configured (e.g. `.github/workflows/**`, or other providers) and, when absent, **proactively offer to create a baseline pipeline** inferred from the detected stack (lint + typecheck + test, matching the package manager / language already detected for `/validate`). Today a freshly-onboarded project with no CI means the push/PR gates have no automated backstop on the remote. Read-only detection + an opt-in offer (never write workflows without confirmation — and recall agents never edit `.github/workflows/**` autonomously, so this is an explicit operator-confirmed scaffold at setup time, not a per-task action). Identified while onboarding deminut.

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
