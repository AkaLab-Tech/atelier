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

`[orchestrator]` · Source: dogfood (2026-06-05)

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

### M2.8 — Adopt Claude Code's native `auto` permission mode as layer 3

`[security-design]` · Source: [docs/research/permission-layer-3.md](docs/research/permission-layer-3.md) (M2.6 spike + M2.7 validation, 2026-05-29) · `blocked_by: M2.7 (already closed, all OQ favorable)`

M2.7 confirmed empirically that adoption is safe on Claude Code v2.1.156: `CLAUDE_CONFIG_DIR` honors `defaultMode: "auto"` (OQ-A), issue #55507 does not reproduce so user-level `auto` survives the merge with a project `permissions` block (OQ-B), and the auto-mode classifier explicitly intercepts the shell-syntax bypass that motivated the spike (OQ-C, observed annotation "Allowed by auto mode classifier" on a `for … do … done` loop). This milestone ships the adoption.

**Scope:**

- [ ] **`templates/settings.template.json`** — remove the `"defaultMode": "acceptEdits"` line. Project-level `defaultMode` overrides user-level by normal merge precedence; leaving it would mask the user-level `auto`. The allow / deny / ask blocks stay unchanged — they compose with auto-mode as documented.
- [ ] **`install.sh` Phase C.1** — add a step that writes `{"permissions": {"defaultMode": "auto"}}` into `$ATELIER_CONFIG_DIR/settings.json` (merge with the existing keys; do not clobber `enabledPlugins`, `extraKnownMarketplaces`, `theme`, etc.). Idempotent: skip if already present at the right value.
- [ ] **`scripts/atelier-doctor`** — new check that `$ATELIER_CONFIG_DIR/settings.json` has `permissions.defaultMode == "auto"`. `--fix` writes the setting if missing.
- [ ] **`docs/operator-guide.md` + `docs/troubleshooting.md` + `operator-rules.md`** — document the auto-mode adoption: what it changes for the operator (no more permission prompts for shell loops or new commands within the deny-respecting envelope) and what stays the same (deny list still blocks force-push, never-auto-merge surface, etc.).
- [ ] **`docs/research/permission-layer-3.md`** — add a "Shipped in M2.8 (PR #N)" line to the addendum's Resolution summary.

**Plugin bump:** **0.7.5 → 0.8.0** per PLAN.md §14.2. Minor bump — operator-visible UX change (fewer permission prompts, semantic-classifier gate) that is not breaking but observably different. Cut release `v0.8.0`.

**Acceptance:**

- A fresh `install.sh` on a host with no prior atelier config produces `$ATELIER_CONFIG_DIR/settings.json` with `permissions.defaultMode == "auto"`.
- `atelier-doctor` reports the auto-mode check as `✓`; on a host without the setting, `atelier-doctor --fix` adds it.
- Inside an atelier task worktree, `/status` Config tab reports `Default permission mode: Auto mode`; `/status` Status tab reports `Setting sources: User settings, Shared project settings`.
- A `for p in foo bar; do echo "$p"; done` invocation by Claude inside the task worktree no longer surfaces the *"Contains shell syntax (string) that cannot be statically analyzed"* prompt.
- The `Bash(git worktree*)`, `Bash(git wt*)`, and the rest of the existing allow list still match before the classifier fires (verified by `/permissions` showing all allow entries intact).

**Trigger to revisit:** captured 2026-05-29 immediately after M2.7's three OQs resolved favorably. Run before any further enumeration-gap fixes — once auto-mode is live, follow-up F-series findings about specific missing allow entries either disappear (covered by the classifier) or get a more focused fix scope.

### M2.9 — Custom `PreToolUse` Haiku hook as targeted second layer above auto-mode (formerly PLAN §11 v2.3)

`[security-design]` · Source: [docs/research/permission-layer-3.md](docs/research/permission-layer-3.md) Recommendation · `blocked_by: M2.8`

Originally tracked as PLAN.md §11 v2.3. The M2.6 spike confirmed it complements auto-mode rather than replaces it — useful for the narrow residual high-risk surface where the documented ~17% FN rate of auto-mode matters (e.g. anything touching `pnpm-lock.yaml`, deploy paths, never-auto-merge files). Deferred from "v2" to a tracked v1 follow-up *after* M2.8 ships and the residual surface is observable in production.

**Scope:**

- [ ] A `PreToolUse` Bash hook that calls Haiku 4.5 with a structured prompt: tool name, args, the M2.5 risk-class tag of the path being touched (if any), the task's `CLAUDE.md` excerpt about deploy/secrets.
- [ ] Cache **disabled** — every invocation is a fresh judgment. The OMC reference design caches per command string; atelier does not, because the same command can be safe or unsafe depending on cwd and surrounding state.
- [ ] Logs decisions to `<worktree>/.task-log/hook-decisions.jsonl` for post-mortem and operator review.
- [ ] Scope: project-level only (not global). Operator opts in per project by adding a key to `.atelier.json`.

**Acceptance:** see [PLAN.md §11 v2.3](PLAN.md) for the original surface area; refine once M2.8 has shipped and the residual FN cases are observable.

**Trigger to revisit:** after M2.8 has been in production long enough to surface real residual cases (target: ≥ 10 merged tasks under auto-mode). Run only if there are observed FN incidents that motivate the additional layer.

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

---

## Phase 8 — Multi-repo workspaces

> **Group several single-repo projects into a "workspace"** (e.g. backend + frontend + CMS) with aggregated status, root-level routing, and *sequenced* cross-repo `blocked_by:<token>#id` dependencies — **without** ever introducing cross-repo atomicity (each task stays one worktree / one PR). Design: [PLAN.md §15](PLAN.md). Milestones are ~1 PR each; M8.1→M8.5 are ordered, M8.6/M8.7 depend on M8.1 only.

> **M8.1 delivered** (registry + `atelier-setup-workspace` foundation) — see [HISTORY.md](HISTORY.md). The milestones below build on it.

### M8.2 — `/setup-workspace` command + per-member setup reuse + `--discover`

`[multi-repo]` · `blocked_by: M8.1` · Source: [PLAN.md §15.3](PLAN.md)

Thin `/atelier:setup-workspace` slash command wrapping the helper. Explicit `--members` (primary) and `--discover <parent-dir>` (secondary, one-level git-repo scan, operator confirms/prunes). Drives `/atelier:setup-project` on members the helper reports as `atelier-needs-setup`, then re-invokes to register the group (the M4.19 bash/AI split).

**Acceptance:** from a parent with two unconfigured git repos, `--discover .` registers both as projects and groups them; explicit `--members` is equivalent.

### M8.3 — `atelier-resolve-dep` offline cross-repo resolver

`[multi-repo]` · `blocked_by: M8.1` · Source: [PLAN.md §15.4](PLAN.md)

Helper that answers "is `<token>#<id>` merged?" **offline** from the sibling member's `HISTORY.md`. Exit-code contract `0/3/4/5/2` (satisfied / open / unknown-token / unknown-id / usage). Id matched in a heading/item-introducing position with a co-located PR reference; `unknown-id` refuses loudly.

**Acceptance:** member whose `HISTORY.md` closes `#23` → exit 0; open id → exit 3; unknown token → exit 4; unknown id → exit 5.

### M8.4 — Cross-repo `blocked_by` enforcement in `task-discovery` + `/next-task`

`[multi-repo]` · `blocked_by: M8.3` · Source: [PLAN.md §15.4](PLAN.md)

`task-discovery` detects the `<token>#id` shape, resolves the workspace by reverse-lookup, calls `atelier-resolve-dep`, and skips blocked candidates on auto-pick. `/next-task` Step 3 refuses an explicitly-named blocked task with a clear message; `allowed-tools` gains `Bash(atelier-resolve-dep:*)`; the cross-repo rule is added to Hard refusals.

**Acceptance:** a frontend task `blocked_by:backend#23` is auto-skipped while backend#23 is open, refused with a clear message on explicit `#id` pick, and becomes claimable once backend#23 lands in `backend/HISTORY.md`.

### M8.5 — `task` routing from the workspace root

`[multi-repo]` · `blocked_by: M8.1` · Source: [PLAN.md §15.5](PLAN.md)

`atelier-task-resolve` Step 1.5: when `cwd` is a workspace `root`, present a member picker (reusing the fzf block) with per-member open-task hints, then route into the chosen member's `/next-task`. Root-is-also-a-project → member picker precedence. Inside a member → unchanged.

**Acceptance:** `task` from the workspace root shows a member picker and routes correctly; `task` from inside a member is unchanged.

### M8.6 — Aggregated `/workspace-status`

`[multi-repo]` · `blocked_by: M8.1` · Source: [PLAN.md §15.6](PLAN.md)

New command + `atelier-list-projects --workspace <slug>` filter. One row per member (status, in-progress, open count, cross-repo-blocked count) plus a cross-repo-blocked section. Does not overload `/status`.

**Acceptance:** from the workspace root, `/workspace-status` renders one row per member and a coherent cross-repo-blocked section.

### M8.7 — Auxiliary: `/list-workspaces`, `/remove-workspace`, `/doctor` extension

`[multi-repo]` · `blocked_by: M8.1` · Source: [PLAN.md §15.7](PLAN.md)

`/list-workspaces` (+ `atelier-list-workspaces`) enumerates workspaces with per-member health. `/remove-workspace <slug>` (+ `atelier-remove-workspace`) removes only the group entry; `--with-members` also removes the member projects. `atelier-doctor` gains `check_workspaces` (root exists, members are dirs still in `projects.json`, tokens unique; silent skip when `workspaces.json` absent).

**Acceptance:** `/list-workspaces` enumerates workspaces; `/remove-workspace <slug>` drops the group and leaves members registered; `/doctor` flags a workspace with a missing/unregistered member.

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
