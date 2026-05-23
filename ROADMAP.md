# Roadmap

Backlog of work for this project. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Each task lives here as a heading with whatever description it needs (acceptance criteria, design notes, sub-tasks). When work starts, move the block to `IN_PROGRESS.md`.

Tasks are derived from the implementation plan in [PLAN.md §12](PLAN.md). Milestone IDs (M1.1, M2.3, …) refer to that plan and are kept in titles for traceability. Always read the referenced PLAN.md section before starting a task.

---

## High Priority

> **Phase 1 — Foundation.** Blocks everything else. A fresh Mac must be able to run `install.sh`, log in to Claude + GitHub, and end with the `atelier` plugin installed and `/doctor` ✅.

> **Install hardening from M7.1 dogfood-2 (2026-05-23).** Findings F1–F12 below surfaced during a full-wipe reinstall on the operator's machine, following [docs/dogfood-guide.md](docs/dogfood-guide.md) Stages 0–1. M7.1 (full task cycle on a real project) is paused until F1–F12 are resolved. Tags in each entry: `[correctness]` = real bug or constraint violation; `[ux-blocking]` = non-technical operator can be misled or blocked; `[noise]` / `[improvement]` = polish / would-be-nice but operator can work around.

### M7.1.F1 — Strip M5.0.2 preflight design block from `install.sh` output

`[noise]` · Source: M7.1 dogfood-2 install run (2026-05-23)

The end of `install.sh` prints a multi-line block titled `PREFLIGHT BEHAVIOUR (M5.0.2)` that documents atelier's internal design contract for the config-dir collision check (empty / marker-detected / collision branches). That text is aimed at future atelier maintainers — it does not belong in operator-facing stdout of a successful install. It dilutes the actual "first steps" message (see F12) and confuses non-technical operators.

**Scope:**

- [ ] Locate the heredoc / echo block in `install.sh` and either delete it, demote it to a `#`-prefixed code comment, or move it to `docs/install-internals.md`.
- [ ] Audit the rest of `install.sh` for similar design-doc leakage (any `==>` / `!!` blocks that explain internal contracts rather than reporting operator-relevant state).

**Acceptance:** running `./install.sh` end-to-end on a clean system produces no output mentioning `PREFLIGHT BEHAVIOUR`, milestone IDs (`M5.0.2`, etc.), or other internal design framing.

### M7.1.F2 — `install.sh` output legibility (colors, section headers, progress markers)

`[ux-blocking]` · Source: M7.1 dogfood-2 install run (2026-05-23)

Current output is monochrome and flat — Phases A / B / C.1 / C.2 blur together, sub-steps lack visual hierarchy, and success / skip / fail are not visually distinct. For a non-technical operator following a multi-minute install, it is hard to tell where they are or whether something quietly broke.

**Scope:**

- [ ] Introduce ANSI color, auto-disabled when `[ -t 1 ]` is false or `NO_COLOR` is set in env (so logs piped to a file stay clean).
- [ ] Bold / colored phase headers (`==> Phase A`, `==> Phase B`, …).
- [ ] Unicode markers: ✓ success, → in progress, ↷ skipped (no-op), ✗ failed.
- [ ] Clear visual separators between phases (rule line + blank line).
- [ ] Consistent indent so the phase-level vs step-level vs sub-step hierarchy is obvious at a glance.

**Acceptance:** a side-by-side comparison of the current and new outputs on the same install path shows phase boundaries and success / skip / fail are scannable in <5 seconds without reading every line.

### M7.1.F3 — Phase A: detect outdated base deps and offer update

`[improvement]` · Source: M7.1 dogfood-2 install run (2026-05-23)

Phase A today only checks that base deps (`git`, `gh`, `fnm`, `node`, `pnpm`, `docker compose v2`) are *present* and meet a minimum version. It does not check whether a newer version is available. Operators running atelier for months can be unknowingly on stale tooling — and atelier's install / doctor flow is the obvious surface to surface this.

**Scope:**

- [ ] For each base dep, query the latest available version via the operator's package manager (`brew outdated <pkg>` on macOS; `apt list --upgradable <pkg>` on Debian/Ubuntu; `fnm ls-remote --lts | tail -1` for node; `npm view pnpm version` for pnpm; `gh release view --repo cli/cli --json tagName` for gh; `gh release view --repo AkaLab-Tech/git-wt --json tagName` for git-wt).
- [ ] When `current < latest`, print: `↷ <pkg> 1.2.3 (latest 1.4.0 available) — atelier can update for you (Y/n)?`.
- [ ] Respect a global flag `ATELIER_SKIP_UPDATE_PROMPTS=1` for non-interactive installs.
- [ ] Never auto-update without explicit consent; default to **no** on Enter.

**Acceptance:** running `./install.sh` on a system with at least one outdated dep prints the offer, accepts Y / n, and on Y executes the update via the appropriate package manager and re-verifies the version before continuing.

### M7.1.F4 — Phase B: when Claude / gh already authenticated, offer to switch accounts

`[improvement]` · Source: M7.1 dogfood-2 install run (2026-05-23)

Phase B currently prints `Claude Code already authenticated` and proceeds silently. Same pattern applies to `atelier-author` / `atelier-reviewer` `gh` logins when their `GH_CONFIG_DIR` already holds a token. An operator reinstalling onto a machine that previously hosted a different identity (shared mac, identity rotation, account compromise) gets no opportunity to switch.

**Scope:**

- [ ] When Claude Code reports an existing session, prompt: `Already logged in as <user>. Keep this account (Y) or switch to another (s)?`. `s` triggers `claude logout` followed by a fresh auth flow.
- [ ] Same treatment for `atelier-author` and `atelier-reviewer` — they already isolate via `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/<role>`, so the prompt + logout / login are self-contained.
- [ ] Default to "keep" on Enter so the typical re-run stays fast.

**Acceptance:** running `./install.sh` on a machine where Claude + both gh identities are already authenticated produces three prompts (one per credential) each offering keep / switch with the existing identity displayed.

### M7.1.F5 — Phase B: explain GitHub permission requirements before each `gh auth login`

`[ux-blocking]` · Source: M7.1 dogfood-2 install run (2026-05-23)

Before each `gh auth login`, `install.sh` prints a one-line description of the role (`author` / `reviewer`) but does not explain what GitHub permissions the soon-to-be-authenticated account must have. Non-technical operators frequently authenticate with a personal account that does not have access to their organization's repositories, causing silent failures later when pushes / PRs / approvals fail without an obvious root cause.

**Scope:**

- [ ] Print before each `gh auth login` invocation:
  - **Role purpose**: author = push + PR open + issue ops; reviewer = PR approve + comment.
  - **Required GitHub access**: the account must have **push** access to the project repos (author) or at least **read + review** (reviewer).
  - **Org reminder**: if the project lives under a GitHub org, the account must be a member or invited collaborator *before* this login.
  - **Pointer**: link to the operator-facing docs section on org membership / repo access.
- [ ] Pause for an explicit Enter to confirm the operator has read the block before the device-code flow opens.

**Acceptance:** running `./install.sh` Phase B prints a labeled permissions-requirements block before each of the two `gh auth login` calls, separated visually from the device-code prompt.

### M7.1.F6 — Resumable installs: plant `install_status: in_progress` marker early

`[correctness]` · Source: M7.1 dogfood-2 install run (2026-05-23)

If `install.sh` fails anywhere after touching `$ATELIER_CONFIG_DIR` (token expiry mid-Phase B, `Ctrl+C` at any point, Phase C.1 symlink error, Phase C.2 marketplace clone fail, etc.), the directory is left partially populated **without** the `.atelier-managed` marker that Phase C.1 plants at the end. The next `./install.sh` triggers the M5.0.2 preflight collision check and refuses to reuse the directory — forcing the operator to pick an alternative path even though they actually want to retry the failed install. Observed in dogfood-2: a Phase B token expiry left `~/.claude-work/{.claude.json,backups,gh}` adrift, and the retry rejected the path.

**Scope:**

- [ ] At the very start of Phase 0 (after path resolution, before any other action), write the marker with content `install_status: in_progress` + `pid: $$` + `started_at: <iso8601>`.
- [ ] Update the M5.0.2 preflight to recognize three marker states: missing → proceed (clean install); `in_progress` → offer `Resume previous install (Y/abort)?`; `complete` → idempotent reuse (current behavior).
- [ ] At the end of a successful install, rewrite the marker with `install_status: complete` + `completed_at: <iso8601>` + `version: <sha or tag>`.
- [ ] Document the contract as a top-line comment inside the marker file so a future reader understands the field semantics.

**Acceptance:** simulate a Phase B failure (`kill -INT $$` mid-`gh auth login`). Re-running `./install.sh` finds the `in_progress` marker, offers resume, and proceeds without prompting for an alternative path. After a clean run, the marker reads `install_status: complete`.

### M7.1.F7 — `git user.name` / `user.email` default to `atelier-author` identity, not operator's personal one

`[correctness]` · Source: M7.1 dogfood-2 install run (2026-05-23)

The git-identity prompt at the end of Phase C.1 defaults to the operator's existing global `~/.gitconfig` values (e.g. `Mike` / `miguelmail2006@gmail.com`). Atelier commits will therefore be authored by the operator's personal identity but pushed via the `atelier-author` gh token — a mixed identity that defeats the purpose of the dual-gh-id design (M5.0.1) and makes "who did what" hard to reason about in the commit graph and on GitHub.

**Scope:**

- [ ] Read the `atelier-author` GitHub user via `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/author gh api user --jq '.name // .login, .login, .email'`.
- [ ] Propose `name = <real name or login>`, `email = <public email or `<id>+<login>@users.noreply.github.com`>` as the prompt defaults.
- [ ] Decide isolation mechanism: per-project `includeIf` block in `~/.gitconfig` keyed off `$ATELIER_CONFIG_DIR/projects/**` (or whatever atelier registers); OR injected per-commit by `task-orchestrator` via `git -c user.name=... -c user.email=... commit`. The chosen mechanism must NOT overwrite the operator's global `~/.gitconfig` identity.
- [ ] Document the chosen mechanism in `commands/setup-project.md` and operator-facing docs.

**Acceptance:** after install, commits made by atelier inside a managed worktree show `Author: <atelier-author identity>` while commits made by the operator outside that worktree retain the operator's personal identity. Verified via `git log --format='%an <%ae>' -1` from both contexts.

### M7.1.F8 — Trailing-slash normalization + path-format validation in Phase 0 prompt

`[noise]` · Source: M7.1 dogfood-2 install run (2026-05-23)

The Phase 0 prompt sample text shows paths with a trailing `/` (`pick an alternative path (e.g. ~/.claude-atelier/, ~/.atelier/):`). Operators copy the pattern, store `$ATELIER_CONFIG_DIR` with `/` suffix, and every subsequent concatenation `${ATELIER_CONFIG_DIR}/sub` produces `//sub` — a visible cosmetic bug throughout the rest of the install output. POSIX collapses `//` to `/` so there is no functional impact, but it makes the install look sloppy.

**Scope:**

- [ ] Reword the prompt sample text to show paths **without** trailing `/` (`~/.claude-atelier`, `~/.atelier`).
- [ ] Normalize the operator's input: `path="${path%/}"` before storing.
- [ ] Validate format before accepting: reject empty input, paths with unescaped whitespace, paths pointing at existing non-directory files, unresolvable relative paths. On reject, print the reason and re-prompt.
- [ ] Resolve `~` and `$HOME` if present (`path="${path/#\~/$HOME}"`).

**Acceptance:** entering `~/.claude-atelier/` (with trailing slash) results in the install storing `/Users/<user>/.claude-atelier` and all downstream log lines showing single-slash paths. Entering `/tmp/foo bar` (with space) is rejected with a clear message and re-prompts.

### M7.1.F9 — Force HTTPS for marketplace `git clone` (violates PLAN.md §2 HTTPS-only)

`[correctness]` · Source: M7.1 dogfood-2 install run (2026-05-23)

Phase C.2 prints `Cloning via SSH: git@github.com:AkaLab-Tech/claude-plugins.git` when `claude plugin marketplace add AkaLab-Tech/claude-plugins` runs. This violates the hard constraint in [PLAN.md §2](PLAN.md) step 5 ("GitHub auth: HTTPS only. **Never** generate, reference, or rely on SSH keys."). It succeeded on the dogfood machine only because the operator has SSH keys configured *outside* atelier — on a clean Mac without SSH keys, Phase C.2 would fail with an opaque SSH error.

**Scope:**

- [ ] Determine whether `claude plugin marketplace add` accepts a protocol override flag. If it does, use it from `install.sh`.
- [ ] If not, set a scoped `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_0=git@github.com:` environment override on the `claude plugin marketplace add` invocation only, so it does not leak into the operator's global git config.
- [ ] Verify the same protocol enforcement applies to `claude plugin install <plugin>@<marketplace>` invocations.
- [ ] Extend `commands/doctor.md` to flag any installed marketplace whose remote starts with `git@` as a violation (post-install detection).

**Acceptance:** running `./install.sh` Phase C.2 on a machine with **no** SSH keys configured completes successfully. `git -C ~/.claude*/plugins/marketplaces/akalab-tech remote -v` shows `https://github.com/AkaLab-Tech/claude-plugins.git`, not the `git@github.com:` form.

### M7.1.F10 — Suppress or wrap git-wt sub-installer's "installation complete" epilogue

`[ux-blocking]` · Source: M7.1 dogfood-2 install run (2026-05-23)

In the middle of Phase C.1, atelier delegates to the upstream git-wt installer (`/tmp/git-wt/install.sh`). That installer prints its own `==> installation complete / next steps: 1. Restart your shell …` epilogue — but this is the *sub-installer's* completion, not atelier's. To a non-technical operator following along, it looks like the entire install just finished, while in reality Phase C.1 still has git-identity prompts + helper symlink wiring + Phase C.2 to go.

**Scope:**

- [ ] If the git-wt installer exposes a quiet / no-epilogue flag (`--quiet`, `--no-next-steps`, etc.), use it from atelier's invocation. Coordinate upstream if needed (atelier maintains the AkaLab-Tech/git-wt fork — adding the flag is in our control).
- [ ] Otherwise: pipe git-wt's output through a filter that drops lines from `==> installation complete` to end-of-block, or wrap it in a clearly-labeled sub-section (`---- git-wt sub-installer output ----` / `---- end git-wt sub-installer ----`) so the operator understands the scope.

**Acceptance:** running `./install.sh` shows git-wt's install lines clearly attributed as a sub-step inside Phase C.1, **without** the `installation complete / next steps` epilogue suggesting the whole atelier install is done.

### M7.1.F11 — Persist the operator's `$ATELIER_CONFIG_DIR` choice across runs

`[correctness]` · Source: M7.1 dogfood-2 install run (2026-05-23)

When Phase 0 prompts the operator for an alternative path (because the default `~/.claude-work/` collided), the chosen path appears to be used only in-memory for the current install. Open questions to verify by reading `install.sh` + downstream tooling:

- Does `install.sh` write the chosen path anywhere durable so subsequent `./install.sh` runs default to it?
- Does `atelier-uninstall` know to look at the alternative path?
- Does `/atelier:doctor` resolve the alternative path correctly?
- Does `scripts/atelier-setup-project` write the alternative path into per-task `.claude/settings.json`?

If any answer is "no", the operator who chose `~/.claude-atelier/` ends up with a working install but downstream tools that default back to `~/.claude-work/` and silently miss the real install — a variant of F6 that breaks after the install rather than during it.

**Scope:**

- [ ] Persist the choice in `~/.config/atelier/config` (XDG-ish) **or** as an env var exported by an atelier hook block in `~/.zshrc` (matching how atelier already wires shell hooks during install).
- [ ] Document the lookup order: explicit `$ATELIER_CONFIG_DIR` env var > config file > default `~/.claude-work/`.
- [ ] Audit `install.sh`, `scripts/atelier-uninstall`, `commands/doctor.md`, `scripts/atelier-setup-project`, and every reference to `$ATELIER_CONFIG_DIR` to ensure they go through the same resolver.

**Acceptance:** after choosing `~/.claude-atelier/` in a Phase 0 prompt, opening a fresh shell and running `/atelier:doctor` resolves the same path; `atelier-uninstall` defaults to the same path; `./install.sh` re-run skips the Phase 0 prompt and proceeds idempotently (uses the marker semantics from F6).

### M7.1.F12 — End-of-install "first steps" guide for the operator

`[ux-blocking]` · Source: M7.1 dogfood-2 install run (2026-05-23)

After a successful install, `install.sh` prints only: `==> install.sh done. Open a new terminal (or run source ~/.zshrc) to use task and task-status.`. A non-technical operator has no idea what to do next — what command sets up a project, how to start a task, how to ask the doctor for status, how to uninstall if something goes wrong.

**Scope:**

- [ ] At the end of a successful install, print a clearly-formatted "First steps" block:
  1. Reload your shell: `source ~/.zshrc`.
  2. Verify the install: open Claude Code and run `/atelier:doctor`.
  3. Set up your first project: `/atelier:setup-project <path-to-project>`.
  4. Start your first task: open the project's Claude session and run `/atelier:next-task`.
  5. Where to find docs: pointer to `docs/operator-guide.md` once M6.2 lands (or the in-repo README until then).
  6. How to undo the install: `atelier-uninstall` (or `atelier-uninstall --purge` to also wipe `$ATELIER_CONFIG_DIR`).
- [ ] Use clear visual hierarchy (header, numbered steps, code-block style for commands).
- [ ] Keep it copy-pasteable: no soft-wrap, no embedded variables the operator has to substitute mentally.

**Acceptance:** running `./install.sh` end-to-end ends with a "First steps" section the operator can follow without opening any other documentation.

---

## Medium Priority

> **Phases 2–5 — Single-project agent flow + robustness + multi-project foundation.** Done when the toy-repo flow can pick a task, implement it, open a reviewed PR, auto-merge it, clean up, and survive failures with retries — and when an operator can install / uninstall atelier without risking unrelated Claude state.

### M4.22 — Spike: Coolify VPS integration research

Research spike to inform a future implementation (M4.23). Atelier today has no path to deploy or manage apps on a VPS-hosted Coolify instance. Before committing to an implementation, audit what already exists in the ecosystem and document Coolify's API surface so the impl task starts from concrete options rather than guesses.

[PLAN.md §11](PLAN.md) lists *deployment/release management* as out-of-scope for v1. This spike does not contradict that — it produces a written artifact that informs whether and how to lift that scope later. The implementation task (M4.23) stays tagged `v2` until the spike completes and the team explicitly decides to promote it.

**Investigation surface:**

- [ ] **Ecosystem inventory.** Catalog existing tooling for Coolify integration: Claude Code MCP servers, plugins, skills, agents (search the official marketplace + community marketplaces); third-party CLIs (`coolify-cli`, Terraform providers); libraries / API wrappers in any language. For each entry record: source URL, license, last-update date, maintenance status, coverage vs gaps.
- [ ] **API surface mapping.** For each use case below, document the relevant Coolify API endpoints, required auth, expected payloads/responses, rate-limit posture, and idempotency characteristics:
  - Deploy from branch / commit.
  - List apps, fetch status, tail logs.
  - Manage env vars / secrets (CRUD).
  - Provision new apps.
  - Anything else the API exposes that fits atelier's workflow (cron jobs, databases, backups, etc.) — flag opportunistically.
- [ ] **Auth flow design.** Document the per-project `.env` token approach: env var naming convention (e.g., `COOLIFY_API_TOKEN` + `COOLIFY_BASE_URL`), how the skill loads them, fallback behavior when missing, multi-instance support (one operator, multiple Coolify instances across projects).
- [ ] **Recommendation — build-on / wrap / from-scratch.** Based on the inventory: (a) adopt an existing MCP/skill directly, (b) wrap an existing tool with a thin atelier layer, or (c) build a native skill calling Coolify's REST API. Justify the choice and call out the second-best option as a fallback.

**Deliverable:** a markdown document at `docs/research/coolify-integration.md` covering all four sections above. Must be self-contained — whoever picks up M4.23 cold should be able to act on it without re-doing the research.

**Acceptance:** `docs/research/coolify-integration.md` exists with all four sections populated. M4.23's description is updated with a `Based on: docs/research/coolify-integration.md` reference and any scope adjustments the research surfaced (e.g., dropping a use case the API does not support cleanly, or adding one the API exposes cheaply).

**Trigger to revisit:** captured 2026-05-23. Operator wants a path to deploy atelier-managed projects to VPS-hosted Coolify. Spike runs immediately because the implementation cost depends heavily on whether existing tooling already covers the use cases — building from scratch when a maintained MCP already exists would be waste.

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

### M4.23 — Coolify VPS deployment integration (`v2`, `blocked_by: M4.22`)

`v2` · `blocked_by: M4.22`

**Out-of-scope for v1 per [PLAN.md §11](PLAN.md).** Captured as a v2 task so the work is not lost; promotion to v1 requires an explicit decision after M4.22's research artifact lands.

Implementation of Coolify VPS integration covering deploy, status/logs, env vars/secrets, and app provisioning. Full scope is whatever M4.22's research determines the API supports and what adds value to the atelier workflow. The exact shape (MCP adoption / skill wrapper / native API client) is set by M4.22's recommendation.

**Constraints already settled (do not relitigate):**

- **Auth:** per-project `.env`, gitignored by atelier's existing `.env*` guardrail. Token env var naming convention is finalized in M4.22's auth-flow section.
- **Minimum use cases:** deploy from branch/commit, list apps + status + logs, CRUD env vars/secrets, provision new apps. Anything else the API exposes that fits the atelier workflow may be added opportunistically (per M4.22's mapping).
- **Auto-merge guardrail:** any PR that touches deployment config (analogous rationale to PLAN.md §6 for `Dockerfile`/`docker-compose*`) must fall back to human review. The `auto-merge` skill's never-auto-merge list needs an additional entry for whatever paths the implementation introduces.

**Sub-tasks (refine after M4.22):**

- [ ] Adopt M4.22's recommendation (build-on / wrap / from-scratch).
- [ ] Skill / agent / command surface area as decided by M4.22.
- [ ] `settings.template.json` permissions delta: allowlist for Coolify-related Bash / MCP calls scoped to the worktree; deny anything that would touch other projects' deployments.
- [ ] `/doctor` extension: verify the Coolify connection (token + base URL reachable) when the project has Coolify configured.
- [ ] Operator-facing docs: a `docs/coolify.md` (or section in `commands/setup-project.md`) explaining how to wire a project to a Coolify instance.

**Acceptance:** an atelier task can trigger a Coolify deploy of the current branch's HEAD, fetch the resulting app status + last N log lines, set/get an env var, and provision a fresh app — all from inside a Claude session, with the Coolify API token loaded from the project's `.env` only. PRs touching Coolify config fall back to human review per the extended guardrail list.

**Trigger to revisit:** after M4.22 lands AND the team explicitly decides to promote deployment work into v1 (or accepts this stays v2 with the spike having unblocked the path).

### M5.1 — Project registry

`~/.claude-work/projects.json` tracks every project the operator has set up. Fields per project: path, name, last-task timestamp, setup version.

### M5.2 — `/setup-project` full bootstrap

Extend the Phase 2 command to be the canonical multi-project entry point: registers in `projects.json`, creates `.claude/settings.json`, project `ROADMAP.md`, project `.claude/CLAUDE.md`, project `.npmrc` (pnpm guardrails), `.gitignore` entries.

### M5.3 — `task` alias resolves project from cwd

Shell alias detects which registered project the cwd belongs to and opens a Claude session that auto-invokes `/next-task` for that project. Falls back to a project-picker menu if cwd is not inside a registered project.

### M6.1 — `update.sh`

Incremental updater per [PLAN.md §9](PLAN.md): `git pull` → diff changed files → apply deltas → if `settings.template.json` changed, prompt the operator with a human-readable permissions diff (added / removed / impact) before applying.

### M6.2 — Operator guide

Junior-friendly walkthrough: clone → install → first task. No git/branching/PR jargon.

### M6.3 — Product owner guide (ROADMAP.md format)

How to write [PLAN.md §5](PLAN.md)-shaped roadmaps: priorities, types, estimates, `blocked_by`, acceptance criteria. With examples.

### M6.4 — Troubleshooting doc

Common failure modes and recovery: auth expired, plugin not loading, hooks blocking unexpectedly, `git-wt` misconfigured, `.npmrc` guardrail false-positives.

Two specific items captured during dogfood-1 that belong here:

- **GitHub same-identity self-approval limitation.** When `pr-author` and `reviewer` run under the same GitHub identity (the operator's, in single-developer projects), GitHub silently downgrades the reviewer's `gh pr review --approve` to a comment, which trips both auto-merge guardrails #2 (review status) and #6 (pending human comment). The auto-merge skill is correct to hold the PR. Two operator-side mitigations to document: (a) configure a separate bot identity for `atelier:reviewer` (recommended for ≥1 active project), or (b) accept that single-developer projects always merge manually and add `--squash --delete-branch` to the operator's muscle memory. Identified in dogfood-1 (Finding #11).
- **Claude Code permission-cache mis-alignment after worktree reset.** When `retry-with-logs` triggers the reset between attempt 03 and 04, the worktree is recreated via `git worktree remove --force` + `git worktree add`. The harness's permission cache continues to apply the pre-reset deny list against the recreated worktree path inconsistently — in dogfood-1, two separate `Edit` calls on a deny-listed path succeeded in attempts 04 and 05 (and were reverted to honor the hard refusal). Mitigation until Claude Code fixes the harness: between attempt 03 and attempt 04, the operator should restart the Claude Code session, or the orchestrator should surface a warning that enforcement is undefined post-reset. Identified in dogfood-1 (Finding B).

### M7.1 — Dogfood on a real (non-toy) project

Run a full task cycle on an actual project. Capture friction.

### M7.2 — Iterate the network allowlist

Grow the allowlist organically based on what M7.1 needs. Document each addition with a one-line justification.

### M7.3 — Measure autonomous merge rate

Sample 10 real tasks; compute the % that reach merged state without human intervention. Target ≥80%.

### v2 ideas (deferred)

Per [PLAN.md §11](PLAN.md). Revisit only after v1 is stable.

- v2.1 — Skill auto-injector hook (`UserPromptSubmit`) to load skills by context signals.
- v2.2 — Router skill with subcommands (`/atelier setup|doctor|update|reconfigure`).
- v2.3 — `PermissionRequest` Bash hook for dynamic permissions, replacing static `settings.template.json`.
- v2.4 — Project-memory hooks (`SessionStart` + `PostToolUse`) to auto-persist project learnings.
- v2.5 — `/learner` + `/skillify` to extract reusable patterns from successful tasks.
- v2.6 — Node.js hook dispatcher (`scripts/run.cjs`) for portable, fail-open hook execution.

### Out of scope for v1

Per [PLAN.md §11](PLAN.md). Listed here so they are not picked up by accident: multi-repo coordination, deployment/release management, cost monitoring / per-task budgets, visual regression baselines, ROADMAP ↔ Issues bidirectional sync.
