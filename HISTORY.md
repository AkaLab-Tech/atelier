# History

Completed work log. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Newest first. Each entry references the PR(s) that delivered the work.

---

## 2026-05

### Dogfood-1 — first end-to-end run on a real GitHub repo — 2026-05-19
**PR:** _pending_ (this PR)

First real end-to-end exercise of the full atelier chain on a real GitHub repo (`AkaLab-Tech/atelier-dogfood-1`, private). Pre-implementation milestones M1.x–M4.2 had only been validated piece-by-piece; this is the first time the orchestrator + 6 specialists + retry/unblocker loop ran on a real project, end-to-end, against a forced-failure task. Surfaced **14 atelier findings** and **2 distinct deny-list bypass vulnerabilities** that pre-existed in the auto-merge guardrails but had never been exercised by a sub-agent.

**Three runs:**

1. **Run 1 (pre-flight blocked, no chain executed)** — `/atelier:next-task` aborted before invoking any specialist. Two systemic blockers: (a) the `scan-edit-write` hook's `hardcoded-secret-known-prefix` pattern was a bare-substring match on `sk-` and triggered on every atelier worktree path (`task-N-slug` contains the substring `sk-`); (b) the per-worktree path `<repo>-worktrees/...` was outside the sandbox `additionalDirectories` from `settings.template.json`, so the orchestrator could not operate inside the worktree it had just created.
2. **Run 2 (happy-path Task #1, full chain executed)** — after the three Phase-A fixes, the chain ran end-to-end: `task-discovery → task-orchestrator → git-wt switch → implementer → tester → e2e-runner (skipped, no UI) → pr-author → reviewer → auto-merge (held)`. [PR #1](https://github.com/AkaLab-Tech/atelier-dogfood-1/pull/1) opened on the dogfood repo, +24/-9 across 4 files. The `auto-merge` skill correctly held the PR — but for a non-actionable reason: GitHub rejects self-approval when `pr-author` and `reviewer` run under the same identity, so the reviewer's verdict landed as a comment, tripping guardrails #2 (review status) and #6 (pending human comment). The PR was squash-merged manually for dogfood progress.
3. **Run 3 (forced-failure Task #2, hard-stop validation)** — designed to exercise [PLAN.md §8](PLAN.md)'s retry budget by requesting an `Edit(./package.json)` which is in the per-worktree deny list. The chain ran exactly as the spec promises: 6 attempts written to `<worktree>/.task-log/<ISO-timestamp>-<NN>.md` with the reset between attempt 03 and 04 (and a temp-copy of `.task-log/` preserved at `<repo>-worktrees/.atelier-task-log-2/`), `retry-with-logs` returned `hard-stop` after attempt 06, the `unblocker` agent opened [issue #2](https://github.com/AkaLab-Tech/atelier-dogfood-1/issues/2) on GitHub with the 6 logs verbatim + a structured root-cause synthesis, and applied the `blocked` label (created idempotently since the label didn't exist). **M4.1 + M4.2 are now validated end-to-end on a real GitHub repo.**

**Five fixes landed in this PR:**

- `hooks/patterns/scan-edit-write.json` — `hardcoded-secret-known-prefix` rewritten from a bare substring list (`["sk-", "gho_", ...]`) to a regex requiring (a) a non-identifier boundary before the prefix and (b) a credential-shaped body of 20+/30+ chars after each prefix. Validated 10/10 negatives + 10/10 positives via a bash script. Fixes Findings #4 and #9 (the same regex bug surfaced twice).
- `templates/settings.template.json` — `additionalDirectories` extended from `["<worktree>"]` to `["<worktree>", "<worktree>-worktrees"]`; `Edit/Write/Read` allow patterns extended with matching `<worktree>-worktrees/**` entries. After `sed` substitution by `/setup-project`, this gives the operator's session pre-authorised access to every per-task worktree the orchestrator may create. Fixes Finding #8.
- `commands/setup-project.md` — step 3 now asserts `$CLAUDE_PLUGIN_ROOT` resolves to a directory containing `templates/settings.template.json` BEFORE attempting the `sed` instantiation, and stops with an actionable error if either check fails (with explicit recovery instructions: install via marketplace, or `export CLAUDE_PLUGIN_ROOT=…` for a one-off CLI run). Fixes Findings #2 (env var unset under `--plugin-dir`) and #3 (Step 3 had been silently failing without surfacing the error).
- `agents/unblocker.md` — Step 5 rewritten to mark `[BLOCKED]` in the **main worktree's** `IN_PROGRESS.md` (not the failed task's worktree copy) and **commit+push** the change on a dedicated `docs/blocked-<task-id>` branch so the marker reaches `main`. Without this, the marker stayed local to the failed worktree, `main` never saw it, and the next `/next-task` would re-pick the same task forever. Fixes Finding #14.
- `templates/settings.template.json` — `Bash(pnpm exec *)` (broad wildcard) replaced with a per-binary allow list (`pnpm exec eslint*`, `pnpm exec prettier*`, `pnpm exec tsc*`, `pnpm exec vitest*`, `pnpm exec jest*`, `pnpm exec playwright*`, `pnpm exec tsx*`). The wildcard allowed `pnpm exec node -e "fs.writeFileSync(...)"` to be used as a side-channel to write to deny-listed paths, which the implementer discovered during attempt 03 of run 3 and reverted as a hard refusal. **Fixes the security finding (Finding A from issue #2 on the dogfood repo).**

**Findings deferred to follow-up milestones (documented in this PR's ROADMAP edits):**

- **M4.6** — `/next-task` and orchestrator must detect non-interactive (`-p`) mode and skip operator-confirmation prompts. (Finding #7 from run 1 — operator confirmation traps a `-p` invocation.)
- **M4.7** — the orchestrator must instantiate a per-worktree `.claude/settings.json` (currently the sandbox blocks the write and the sub-agents silently inherit the main session's scope). (Finding #12 from run 2.)
- **M4.8** — `pr-author` must enforce the `IN_PROGRESS.md → HISTORY.md` move (its own prompt says it does, but in run 2 it did not). Alternatively, reassign the move to `auto-merge`'s post-merge cleanup. (Finding #13 from run 2.)
- **M6.4** — operator troubleshooting doc must call out two non-atelier issues with operator-side mitigations: (a) GitHub same-identity self-approval limitation (Finding #11 from run 2), and (b) Claude Code permission-cache mis-alignment after `git worktree remove --force` + `git worktree add`, which dogfood-1 showed lets two `Edit` calls succeed on a deny-listed path post-reset (Finding B from issue #2).

**Decisions captured:**

- **Hook regex with both word-boundary AND length floor.** Either alone would close some of the false-positive surface; the combination is what makes `task-N-slug` clearly safe (no non-identifier boundary in front of `sk-` once `task-` precedes it) AND `sk-` alone clearly safe (no 20-char body). The two checks compose without weakening real-credential detection.
- **Hard refusal on Step 3 of `/setup-project` rather than silent skip.** Run 1 showed silent skip leaves the project half-configured (no `.claude/settings.json`, but `.npmrc` and the markdown files written), which is worse than not running setup at all — the operator believes setup succeeded. The hard-refusal recovery message is verbose by design.
- **`pnpm exec` narrowed by per-binary entries, not by adding `node -e` to deny.** A new deny entry for `node -e` would not have closed the bypass (the attacker can use `bash -c`, `python -c`, etc.); the only sound fix is to drop the wildcard. The seven binaries chosen (`eslint`, `prettier`, `tsc`, `vitest`, `jest`, `playwright`, `tsx`) cover the testing/linting needs of a typical Phase 2 task; new binaries get added explicitly in a future PR with justification.
- **Unblocker's docs-PR approach over direct push to `main`.** A direct push would require lifting the `Bash(git push * main)` deny rule, which is a load-bearing safety invariant. A docs PR for a 1-line `IN_PROGRESS.md` change is light enough that it could even auto-merge (it touches none of the auto-merge-blocking files), and it preserves the audit trail.

**Acceptance criterion status:** there is no formal ROADMAP entry for "dogfood-1" — this is a friction-discovery exercise, not a planned milestone. The five blockers were the *implicit* acceptance criterion, and all five are now resolved (three in run 1's pre-flight, two more after run 2/3 surfaced them). The remaining four ROADMAP items (M4.6 / M4.7 / M4.8 / M6.4) are the deferred portion that does not block end-to-end runs.

### M4.2 — `unblocker` agent — 2026-05-19
**PR:** [#31](https://github.com/AkaLab-Tech/atelier/pull/31)

Second Phase 4 milestone. Closes the loop on `retry-with-logs` (M4.1) by turning the `hard-stop` decision into operator-visible state: a GitHub `blocked` issue with all 6 attempt logs attached, a `[BLOCKED]` marker in `IN_PROGRESS.md`, and an automatic handoff back to the orchestrator so the next ROADMAP item is picked up without human intervention.

**Delivered:**
- `agents/unblocker.md` — new specialist (Sonnet, color `orange`). Invoked **only** by `task-orchestrator` when `retry-with-logs` returns `hard-stop`. Six explicit steps: (1) verify exactly 6 logs on disk; (2) ensure the GitHub `blocked` label exists (creates it idempotently with color `#B60205` if missing); (3) build the issue body with an apparent-root-cause synthesis + the 6 logs verbatim inside `<details>` blocks (truncates to 3 KB/log if total exceeds GitHub's 65 536-char issue-body limit, surfacing the truncation in the report); (4) `gh issue create --title "[blocked] <task-id> — <title>" --label blocked --body-file ...`; (5) edit `IN_PROGRESS.md` to rename the heading to `<task-id> — <title> — [BLOCKED] see #<NN>` and prepend a metadata block (issue URL, worktree path, log count) while leaving the original task block intact below; (6) return a structured `unblocker report` the orchestrator parses. Hard refusals: never modifies code, never `git wt rm` (worktree is evidence), never opens the issue without the `blocked` label, never opens a second `blocked` issue for the same `<task-id>`, never marks `[BLOCKED]` an entry that was not in `IN_PROGRESS.md`.
- `agents/task-orchestrator.md` — three structural changes: **(a)** Step 1 ("Pick the task") now reads `IN_PROGRESS.md` first and filters entries with the literal `[BLOCKED]` marker silently (they belong to the operator's queue, not to a fresh pick); a remaining non-blocked active entry surfaces an anomaly and stops the orchestrator. **(b)** Step 5 lists `unblocker` as a specialist that is **not** part of the happy-path chain but is invoked from the retry loop. **(c)** Step 6's `hard-stop` branch now invokes `unblocker` (instead of "surface to operator") and Step 7 gains a fourth `unblocker → advance to next task` branch that loops back to Step 1, which now correctly ignores the just-blocked `[BLOCKED]` entry. The output schema's Status line updated from `blocked — see <log-path>` to `blocked — see <issue-url>`.
- `templates/settings.template.json` — added `Bash(gh label list*)` and `Bash(gh label create*)` next to the existing `Bash(gh issue *)` entry, scope-minimum. Required for the unblocker's idempotent label-creation step (no fallback path: the issue must carry the `blocked` label or the operator's queue view breaks).
- `ROADMAP.md` — two new low-priority follow-ups identified during this milestone's design and deferred (separate commit, `bd7fc9f`): **M4.4** extend `/status` to list `[BLOCKED]` tasks alongside the active one; **M4.5** `/abandon-task <id>` to automate the Camino C of the blocked-task lifecycle (operator decides not to retry — close issue as `wontfix` + move `IN_PROGRESS` → `HISTORY` with `abandoned` mark).

**Tests:**
- YAML frontmatter parses cleanly on both files (`agents/unblocker.md`, updated `agents/task-orchestrator.md`).
- Plugin loader auto-discovers the new agent. `claude --plugin-dir <worktree> --permission-mode plan -p "list agents..."` returned 7 atelier agents (`task-orchestrator`, `implementer`, `tester`, `e2e-runner`, `pr-author`, `reviewer`, **`unblocker`**) and confirmed the 7 atelier skills (including `retry-with-logs`) are still intact.
- `python3 -m json.tool` clean on `templates/settings.template.json` after the two new permission entries.

**Decisions captured:**
- **Sonnet, not Opus.** The unblocker reads 6 already-structured logs (each log's `Reasoning on what went wrong` is the specialist's own post-mortem) and synthesises one paragraph + writes a GitHub issue. No deep reasoning required — Sonnet at lower cost.
- **`blocked` label is mandatory, not optional.** The operator's primary "what is blocked?" view is `gh issue list --label blocked` (or the equivalent label filter in the GitHub UI). Without the label the issue is just one more issue in the noise — discoverability collapses. The idempotent label-creation step accepts the small added permission surface (`gh label create`) as the cost.
- **Task stays in `IN_PROGRESS.md` with `[BLOCKED]` marker (not moved back to ROADMAP).** Considered three placements: (a) keep in `IN_PROGRESS` with marker, (b) move back to `ROADMAP.md` with a `blocked_by:<issue-number>` annotation, (c) introduce a new `BLOCKED.md` file. Picked (a): preserves the `ROADMAP → IN_PROGRESS → HISTORY` convention, requires zero `task-discovery` changes, and the `[BLOCKED]` marker is greppable. Option (b) would have required `task-discovery` to learn how to resolve `blocked_by:#<issue>` against a remote GitHub issue's open/closed state — invasive cross-cutting change. Option (c) breaks the three-file convention.
- **Cierre del issue de GitHub == "ready to retry" signal.** The operator's contract: investigate, fix something (or decide nothing needs fixing), **close the issue**, run `/resume-task <id>` (M4.3, not in this PR). The close itself is the unambiguous signal. An open issue means the task is still under operator triage; `/resume-task` will refuse if the issue is still open.
- **Budget renews to 6 on resume.** When `/resume-task` lands in M4.3, it will delete `<worktree>/.task-log/` (the 6 logs are preserved in the closed issue's body) and start the retry counter at 0 again — clean slate, full 6 new attempts. Continuing the counter would mean "resume" only gives the operator a partial budget, which contradicts the user's intent of "I fixed something, try again properly".
- **Orchestrator advances automatically after `unblocker`.** Per PLAN.md §8 ("move to next task" after hard stop). The orchestrator loops back to Step 1, which now filters the just-`[BLOCKED]` entry and proceeds to `task-discovery` for the next ROADMAP item. The loop terminates after the next task's own chain ends (merged | held | request-changes | blocked) — it does not chain indefinitely across the entire ROADMAP unless the operator asked for it explicitly.
- **Worktree preserved after `hard-stop`.** The orchestrator and the unblocker both refuse to `git wt rm` a hard-stopped task's worktree. The worktree is the evidence the operator inspects to understand the failure; removing it would orphan the issue from its on-disk artifacts.
- **GitHub issue body cap handled by per-log truncation, not full-log dropping.** If the 6 logs exceed GitHub's 65 536-char limit, each log's `<details>` block is truncated to 3 KB and a `[truncated — full log at <path>]` notice is added. Worst case: the operator opens the worktree to read the full log. Better than dropping a whole log entry.

**Acceptance criterion status:** the ROADMAP M4.2 acceptance — *"the 6-failure scenario from M4.1 ends with a `blocked` issue created and the next task picked up"* — is **structurally satisfied**: the unblocker creates the GitHub issue (with the `blocked` label, with the 6 logs verbatim, with the URL handed back to the orchestrator), marks the entry in `IN_PROGRESS.md`, and the orchestrator's Step 7 wires the "advance to next task" branch. The end-to-end exercise (deterministic failing test → 6 attempts → real `blocked` issue created on a toy repo) is captured in the Test plan of PR #31 as still-deferred under "do NOT validate as part of this PR" because it requires the dogfooding setup from M7.1 (toy repo with `test.sh` that exits 1, real GitHub remote, settings.template instantiated). The complete close on that checkbox lands with the dogfooding milestone, not here.

**Follow-ups (carried forward into Phase 4+ and beyond):**
- M4.3 (`/resume-task <id>`) implements the "operator closed the issue, retry" handler — the contract this PR established (close-issue-as-ready signal, budget renews to 6, `.task-log/` wiped, re-entry from `implementer`).
- M4.4 (extend `/status` for blocked tasks) and M4.5 (`/abandon-task <id>` for Camino C) — both documented in ROADMAP in commit `bd7fc9f`.
- Dogfooding (M7.1) will be the first time the full Phase 4 loop runs against a real (non-toy) project, exercising the `[BLOCKED]` → close issue → `/resume-task` cycle end-to-end.

### M4.1 — Retry logic with log persistence — 2026-05-19
**PR:** [#30](https://github.com/AkaLab-Tech/atelier/pull/30)

First Phase 4 milestone. Materializes the fixed retry budget from [PLAN.md §8](PLAN.md) (3 attempts → reset → 3 attempts → hard stop) as an executable skill the `task-orchestrator` invokes on every specialist failure. Removes the orchestrator's freedom to interpret the policy and replaces it with a finite-state machine: count logs, pick the decision from a table, write a structured per-attempt log.

**Delivered:**
- `templates/task-log/attempt.md` — the per-attempt log template. Five mandatory sections per [PLAN.md §8](PLAN.md): `Initial hypothesis`, `Actions taken`, `Final error` (verbatim, never paraphrased), `Reasoning on what went wrong`, plus a `Next attempt should` block that seeds the following attempt's hypothesis. Filename convention is `<YYYY-MM-DDTHHMMSS-UTC>-<NN>.md` (lexicographically sortable, FS-safe, attempt number zero-padded so `01..06` sort naturally).
- `skills/retry-with-logs/SKILL.md` — the executable form of [PLAN.md §8](PLAN.md). On every specialist failure: counts existing `.task-log/*.md` files, computes the next attempt number `N`, refuses to continue past `N=6`, writes the log from the template at `$CLAUDE_PLUGIN_ROOT/templates/task-log/attempt.md`, and returns one of three decisions: `continue` (retry in same worktree), `reset` (preserve `.task-log/` outside the worktree, run `git wt rm` + `git wt switch` to recreate from updated base, restore the logs, then retry — happens only after attempt 03 fails), `hard-stop` (after attempt 06, hand off to `unblocker` when M4.2 ships; surface to operator until then). The `.task-log/` directory MUST survive the reset between attempts 03 and 04 — the skill copies it to `/tmp/atelier-task-log-<branch>/` before `git wt rm` and restores it after `git wt switch`, otherwise attempts 04..06 lose the prior history and the retry loop is amnesic.
- `agents/task-orchestrator.md` — core-responsibility #6 ("Enforce the retry budget") rewritten to delegate to the skill instead of interpreting the policy inline. Three explicit branches per returned decision: `continue` → re-invoke specialist with all `.task-log/*.md` as context; `reset` → preserve logs, run wt cycle, restore logs, retry; `hard-stop` → stop, hand off to `unblocker` (M4.2) or surface to operator.

**Tests:**
- YAML frontmatter parses cleanly on the new skill (`name=retry-with-logs`) and the updated agent (`name=task-orchestrator`).
- Plugin loader auto-discovers the skill. `claude --plugin-dir <worktree> --permission-mode plan -p "list skills..."` returned 7 atelier skills (`task-discovery`, `pr-flow`, `safe-commit`, `safe-install`, `visual-validation`, `auto-merge`, **`retry-with-logs`**).
- Agent loader still discovers all 6 agents (`task-orchestrator`, `implementer`, `tester`, `e2e-runner`, `pr-author`, `reviewer`) after the orchestrator edit.
- `python3 -m json.tool` clean on `hooks/hooks.json` (no template changes needed; no new permissions required because the skill only reads/writes files inside the worktree and the existing `Edit`/`Write` patterns already cover `.task-log/`).

**Decisions captured:**
- **Skill, not standalone agent.** The retry policy is invoked from inside `task-orchestrator` on every failure, not as a top-level entry point. A `retry-with-logs` agent would mean spawning a sub-conversation just to count files, which is more cost and context than the procedure warrants.
- **Skill describes; orchestrator executes.** Matches the `auto-merge` and `safe-install` patterns. The skill is the procedure document + decision table; the orchestrator runs the `ls`, the `cp`, the `git wt` calls. This keeps the skill stateless and the orchestrator in charge of the worktree.
- **`.task-log/` survives the reset via temp-copy.** Considered (a) committing logs to the branch, (b) keeping them in `.task-log/` and relying on `git wt rm` to preserve files via stash, (c) temp-copy out and back. Option (c) is the only one that works regardless of project gitignore conventions; (a) requires `.task-log/` to not be gitignored, which conflicts with `<worktree>/.task-log/` being intentionally local-only; (b) does not work because `git wt rm` removes the directory entirely.
- **UTC timestamps, zero-padded attempt number.** Reset-and-retry can span hours and timezones; UTC + lexicographic sort + zero-padded attempt number means `ls -1 .task-log/` always returns the logs in chronological order, no parsing required.
- **No retry-budget guardrail hook in this milestone.** Considered a `PreToolUse` hook that counts `.task-log/*.md` files and blocks if `> 6`, as a mechanical backstop on the orchestrator's discipline. Decided to defer to M4.2 — the `unblocker` agent owns the hard-stop semantics end-to-end, so the guardrail belongs in its skill or hook, not as a free-floating PreToolUse rule whose tool-match is hard to scope correctly.
- **Off-by-one explicit in the skill.** PLAN.md §8 says "3 attempts → reset → 3 more". The decision returned **after attempt 03 fails** is `reset`, not `continue`; the decision returned **after attempt 06 fails** is `hard-stop`. Encoded as a table in the skill so the orchestrator does not have to derive it on the fly.

**Acceptance criterion status:** the ROADMAP M4.1 acceptance — *"injecting a deterministic failing test triggers exactly 3 retries, then a reset, then 3 more, then escalation"* — is **structurally satisfied**: the skill enforces the 3+3 split via the decision table, the orchestrator delegates the retry-budget logic to the skill, and the hard-stop is wired to the future `unblocker` hand-off. End-to-end exercise (deterministic failing test → 6 attempts → blocked issue) waits for M4.2 (`unblocker` agent) and M7.1 (real-project dogfooding).

**Follow-ups (carried forward into Phase 4 / 5):**
- M4.2 (`unblocker` agent) consumes the `hard-stop` decision from this skill: opens the `blocked` GitHub issue, attaches every `.task-log/*.md`, notifies the operator, advances the orchestrator to the next ROADMAP item.
- M4.3 (`/resume-task <id>`) re-attaches to an existing worktree, reads `.task-log/` to determine the last successful step, and resumes from there. The fixed filename convention from this milestone is the contract `/resume-task` depends on.
- The retry-budget PreToolUse guardrail hook (deferred above) can be reconsidered after M4.2 ships, once we know whether the orchestrator + skill discipline is sufficient in practice.

### M3.3 — Auto-merge logic with guardrails — 2026-05-19
**PR:** [#29](https://github.com/AkaLab-Tech/atelier/pull/29)

Final Phase 3 milestone. Closes the autonomous-merge loop: when the chain (`implementer` → `tester` → `e2e-runner` → `pr-author` → `reviewer`) ends green, this skill evaluates the six [PLAN.md §6](PLAN.md) guardrails and squash-merges the PR (or holds it for human review). Phase 3 closed.

**Delivered:**
- `skills/auto-merge/SKILL.md` — the executable form of the PLAN.md §6 auto-merge gate. Reads PR metadata via `gh pr view --json`, evaluates **six short-circuiting guardrails** in order, and only merges when **all** pass:
  1. **PR is not a draft.**
  2. **`reviewDecision == "APPROVED"`** — honours GitHub's net verdict (if a human marks `request-changes` after `atelier:reviewer` approved, GitHub returns `CHANGES_REQUESTED` and this guardrail trips).
  3. **All CI checks SUCCESS** (`statusCheckRollup` walked check-by-check; empty array treated as pass with explicit "no CI configured" note).
  4. **No forbidden files in the diff** — `package.json`, `pnpm-lock.yaml` / `package-lock.json` / `yarn.lock`, `Dockerfile*`, `docker-compose*.{yml,yaml}`, `.github/workflows/**`.
  5. **PR size `additions + deletions ≤ 500`**.
  6. **No unresolved human comments** — heuristic: any non-bot comment without a resolution marker (`resolved`, `done`, `lgtm`, `looks good`, leading `:+1:` / `👍`).
  On pass: `gh pr merge --squash --delete-branch --body-file <(echo "")` (squash strategy only, no rebase/merge-commit). Capture the merge commit SHA. Post-merge cleanup: `git wt rm <branch>` with operator confirmation (no auto-confirm), verify the task entry is in `HISTORY.md` (already moved by `pr-flow`), and surface any orphan local task branches. On any guardrail failure: report `held: <reasons>` and stop — the operator decides when to re-invoke.
- `agents/task-orchestrator.md` — chain updated to include the new specialists from M3.1 and M3.2 plus this milestone's skill: `implementer → tester → e2e-runner (when UI surface) → pr-author → reviewer → auto-merge`. The output schema gains a `Status` field that surfaces one of `merged (<sha>)` | `held — <guardrails>` | `request-changes (N findings)` | `blocked — see <log-path>`. The orchestrator now knows not to invoke `auto-merge` after `reviewer` returns `request-changes`.

**Tests:**
- YAML frontmatter parses cleanly on the new skill and the updated agent.
- Plugin loader auto-discovers the skill. `claude --plugin-dir <worktree> --permission-mode plan -p "list skills..."` returned 6 skills total (`task-discovery`, `pr-flow`, `safe-commit`, `safe-install`, `visual-validation`, **`auto-merge`**), and confirmed the updated `task-orchestrator` body references both `reviewer` and `auto-merge` as part of the chain.
- `jq empty` clean on `hooks/hooks.json` (no template changes needed; `gh pr merge*` and `git wt*` were already on the allow list since M1.4 / M1.5).

**Decisions captured:**
- **Skill, not slash command.** The auto-merge gate is the last step of an agent chain, not an operator-facing entry point. A `/auto-merge <PR>` command would be plumbing on top with no unique value; the operator can already invoke the skill ad-hoc by saying "merge PR #N". Slash command can be added later if friction surfaces.
- **Updated `task-orchestrator` in this PR.** The acceptance criterion ("toy-repo flow ends with a merged PR…") requires the orchestrator to invoke this skill, so wiring it now keeps the end-to-end semantics correct. Cross-cutting change to a file from M2.1, captured explicitly here so the diff is reviewable.
- **Squash-only; no rebase / merge-commit.** Single decision point for the merge strategy. Avoids the proliferation of strategies that's hard to audit later. Documented as a hard refusal in the skill.
- **`--body-file <(echo "")` to clear the squash-commit body.** The PR body lives on the closed PR for history; the merge commit on `main` should be terse (just the title). Avoids dumping the full Summary / Test plan / Tracking block into every squash commit.
- **No auto-confirm for `git wt rm`.** Worktree removal post-merge passes through the skill's `git wt rm` invocation, which prompts; the skill must surface that prompt rather than confirming silently. Dirty worktree after a clean merge is an anomaly that deserves operator attention.
- **Unresolved-comment detection is heuristic, on purpose.** GitHub does not expose a structured "resolved" flag for top-level PR comments (only inline review threads via GraphQL). The safe default is **conservative**: any pending human comment trips the guardrail. A future v2 could use the GraphQL `reviewThreads.isResolved` field for inline comments.
- **500-line threshold is hard-coded.** PLAN.md §6 calls it "adjustable" but a per-project override is v2 (project-level config). For v1 the threshold is the contract.

**Acceptance criterion status:** the ROADMAP M3.3 acceptance — *"toy-repo flow ends with a merged PR, deleted branch, cleaned worktree, and `[x]` in the project's ROADMAP.md"* — is **structurally satisfied**: the skill calls `gh pr merge --squash --delete-branch` (deleted branch), then `git wt rm` (cleaned worktree), then verifies the entry is in `HISTORY.md` (the `[x]` equivalent under `roadmap-tracking-flow`, or marks the literal `- [ ]` line under PLAN.md §5 layout when applicable). End-to-end exercise on a real toy repo waits for M7.1 dogfooding.

**Phase 3 closed with this PR.** All three M3.x milestones merged: M3.1 (#27), M3.2 (#28), M3.3 (#29). The full agent chain (`task-orchestrator` → `implementer` → `tester` → `e2e-runner` → `pr-author` → `reviewer` → `auto-merge` skill) now exists end-to-end. Next phase: **Phase 4 — Robustness** (M4.1 retry logic, M4.2 `unblocker` agent, M4.3 `/resume-task`).

**Follow-ups (carried forward into Phase 4+):**
- The full chain has never run end-to-end on a real project; the validation is per-piece (this PR's smoke tests confirm each component loads and the orchestrator knows the chain). M7.1 dogfooding is when the loop closes for real.
- The `auto-merge` skill's heuristic for resolved-comment detection will get noisy in projects that use threaded discussions heavily. The v2 GraphQL-based resolution is the long-term fix.
- The 500-line threshold is the obvious next per-project knob; revisit during M5.x when project config grows beyond `.claude/settings.json`.

### M3.2 — `reviewer` agent (Opus, fresh context) — 2026-05-19
**PR:** [#28](https://github.com/AkaLab-Tech/atelier/pull/28)

Second Phase 3 milestone. The independent reviewer that feeds the auto-merge gate from [PLAN.md §6](PLAN.md). Six of the seven full-chain agents now exist (`task-orchestrator`, `implementer`, `tester`, `e2e-runner`, `pr-author`, **`reviewer`**); only `unblocker` (M4.2) remains.

**Delivered:**
- `agents/reviewer.md` (opus, color `red`, tools `Read`, `Grep`, `Glob`, `Bash`, `TodoWrite`). The first opus agent after `task-orchestrator`. Deliberately omits `Edit`, `Write`, `Task`, and `Skill`: the reviewer evaluates, never modifies; never delegates to other agents; and reads everything directly via `Bash(gh pr view/diff)` rather than via skills (the skill `pr-flow` is for opening PRs, not reviewing). 1701-char description with three triggering examples; 177-line body covering: fresh-context contract, inputs, seven-step checklist (scope, correctness, tests, code quality, security, dependencies, PR shape), confidence-based filtering at ≥ 80%, auto-merge guardrails from PLAN.md §6, structured output, hard refusals.
- `templates/settings.template.json` — extended with `Bash(gh pr diff*)` and `Bash(gh pr review*)` allow entries. Both are review operations the reviewer needs and that no previous agent needed. `gh pr review` is a write op to GitHub (posts an approve / request-changes), but is exactly the reviewer's purpose; the operator can revoke a misfired review post-hoc. Allow count: 64 → 66.

**Tests:**
- YAML frontmatter parses cleanly (Ruby `YAML.safe_load`).
- `jq empty templates/settings.template.json` clean after the 2 new allow entries.
- Plugin loader auto-discovers the agent. `claude --plugin-dir <worktree> --permission-mode plan -p "list agents..."` returned `reviewer` alongside the 5 existing agents from M2.1/M3.1, totalling 6 agents.

**Decisions captured:**
- **Fresh context = sub-agent invocation pattern.** Claude Code's `Task` tool launches sub-agents with prompt-only input, no parent-session history. That is exactly the fresh-context property PLAN.md §6 demands. The agent's body re-states this explicitly so no future caller is tempted to "warm up" the reviewer with the implementing session's transcript.
- **No `Edit` / `Write` in tools list.** Mechanical guarantee that the reviewer cannot rewrite the diff it is reviewing. Least privilege.
- **No `Task` in tools list.** Reviewer does not delegate. If it cannot decide on its own, that itself is signal — surface to the operator, do not chain into another agent.
- **`gh pr review` allowed, `gh pr merge` denied for this agent's invocation.** The reviewer posts the verdict; the **auto-merge gate** (M3.3) reads the verdict + CI + guardrails and decides whether to merge. Conceptual separation: review decision ≠ merge decision; the same PR can be `approved` and still not auto-mergeable.
- **Confidence threshold ≥ 80%.** Hand-tuned to match the canonical `code-reviewer` agent from `claude-plugins-official`. Lower thresholds train the operator to dismiss findings; the few real ones get lost in noise.
- **`approve` ≠ `auto-mergeable`.** Two separate fields in the structured output. PRs that touch `package.json`, lockfile, Dockerfile, workflows, or exceed 500 lines can be approved by the reviewer **and** flagged as not auto-mergeable. The auto-merge gate (M3.3) consumes both.

**Acceptance criterion status:** the ROADMAP M3.2 acceptance — *"reviewer can `approve` or `request-changes` on a PR, and its decision feeds the auto-merge gate"* — is **structurally satisfied**. The agent posts via `gh pr review`; its output includes the `auto-merge: yes | no — <blockers>` line that M3.3 will read. End-to-end validation requires M3.3 (auto-merge logic) to land and a real PR to flow through; deferred to M7.1 dogfood.

**Follow-ups:**
- M3.3 will define the gate that reads `(reviewDecision, statusCheckRollup, files changed)` and decides whether to call `gh pr merge --squash --delete-branch`.
- The seven-step checklist is intentionally lean. Each check has a known false-positive surface; if dogfood (M7.1) surfaces a recurring false positive, the fix is to either tighten the confidence rule for that bucket or remove the check entirely — never to "add a heuristic to skip the false positive", which is how reviewers calcify into rubber stamps.

### M3.1 — `e2e-runner` agent + `visual-validation` skill — 2026-05-19
**PR:** [#27](https://github.com/AkaLab-Tech/atelier/pull/27)

First Phase 3 milestone. Adds the Playwright end-to-end validation step to the agent chain (`implementer` → `tester` → **`e2e-runner`** → `pr-author`), per [PLAN.md §7](PLAN.md). The browser install was deferred here from `install.sh` M1.3 Phase A so operators who never run e2e tasks never pay the ~250 MB download — the skill handles the lazy install on first invocation.

**Delivered:**
- `agents/e2e-runner.md` (sonnet, color `magenta`, tools `Read`, `Grep`, `Glob`, `Edit`, `Bash`, `TodoWrite`, `Skill`). Detects whether the task's diff has a UI surface (skips when not), delegates the install / run / screenshot dance to `visual-validation`, and assembles the structured markdown block (`## E2E validation` with suite results + failures + screenshot list) that `pr-author` pastes verbatim into the PR description. Surfaces `installed @playwright/test@<version> + browsers` when the install was first-time so `pr-author` knows the PR touches `package.json` (and therefore falls into the never-auto-merge guardrail from [PLAN.md §6](PLAN.md)).
- `skills/visual-validation/SKILL.md` — five-step executable recipe:
  1. **Lazy install** — detect `@playwright/test` via `pnpm ls --json`. If missing, `pnpm add -D @playwright/test` (passes the M2.4 `safe-package-change` hook because `@playwright/test` is on the lifecycle-script allowlist) → `pnpm exec playwright install` (downloads chromium/firefox/webkit to `~/.cache/ms-playwright`).
  2. **Config** — detect existing `playwright.config.{ts,js,mjs}`, use as-is. Scaffold a minimal one only when none exists; never overwrite operator-authored config.
  3. **Run** — `pnpm exec playwright test --reporter=list`, with `--screenshot=on` from config so every test produces a PNG. Output captured to `<worktree>/.task-log/playwright-output.txt`.
  4. **Upload** — for each PNG, `gh gist create --secret <png>` and capture the raw URL. Always `--secret` (refuses public). When `gh` auth fails, falls back to *paths-only* mode and surfaces the degradation in the markdown block.
  5. **Assemble** — produces the markdown block in the exact shape `pr-author` expects (suite summary line, optional failures section, embedded `![](raw-url)` screenshots, optional paths-only fallback note).
- `templates/settings.template.json` — extended with `Bash(gh gist create*)` and `Bash(gh gist view*)` allow entries. Narrow scope (only `create` and `view` subcommands, never `gh gist delete*` or `gh gist list*` which leak history). Allow count: 62 → 64.

**Tests:**
- YAML frontmatter parses cleanly on both files (Ruby `YAML.safe_load`).
- `description` length: agent 1339ch, skill 1079ch (both well above the 10-char minimum, below 5000-char ceiling per `skill-creator` guidance).
- Body length: agent 44 lines, skill 132 lines (both well under 500-line ideal).
- Plugin loader auto-discovers both: `claude --plugin-dir <worktree> --permission-mode plan -p "list agents and skills..."` reports `e2e-runner` (Sonnet, magenta) and `visual-validation` alongside the existing 4 agents + 4 skills from M2.1/M2.2 — totals 5 of each.
- `jq empty templates/settings.template.json` clean after the 2 new allow entries.

**Decisions captured (confirmed with the operator before implementation):**
- **Install is lazy via the skill, not a slash command.** Adding a `/setup-e2e` command would force a manual step before the first e2e task, which breaks the "no manual" promise. Lazy install means the first task that needs e2e pays the cost; subsequent tasks reuse the install. The cost is borne when there is value (a UI surface change to validate), not upfront.
- **Screenshots embed via `gh gist create --secret`.** Three rejected alternatives: (a) committing screenshots to the repo (engorges the repo, may contain sensitive UI), (b) listing local paths only (fails the acceptance criterion "embedded in the description"), (c) public gists (search-indexed leak). Secret gists are unlisted; the URL is shareable with anyone who has it — adequate for review.
- **Paths-only fallback when `gh` auth fails.** Rather than aborting, the skill degrades gracefully and surfaces the fallback in the markdown block so the reviewer knows what to expect. The full screenshots stay in `.task-log/screenshots/` for the operator to attach manually.
- **e2e is conditional, not mandatory.** When `git diff --name-only` shows no UI surface changed (docs-only, infra-only, pure-backend), the agent returns `e2e: skipped (no UI surface)` rather than padding the report with an empty suite. This avoids forcing every PR to install Playwright even when there's nothing to validate.

**Acceptance criterion status:** the ROADMAP M3.1 acceptance — *"a PR opened by the toy-repo flow has Playwright output attached and screenshots embedded in the description"* — is **structurally satisfied**. End-to-end validation on a real toy repo requires M3.3 (auto-merge gate, currently not yet shipped) to close the chain and is deferred to M7.1 dogfooding.

**Follow-ups:**
- Real toy-repo dogfood run (M7.1) — first time Playwright actually downloads + runs against a UI change, first gist upload happens for real.
- The current scaffolded `playwright.config.ts` uses chromium only. If projects need cross-browser coverage, the operator extends the config; the skill detects existing config and uses it as-is.

### M2.4 — Phase 2 hooks (dynamic security layer: `block-env-commit`, `safe-commit`, `scan-edit-write`, `scan-git-add`, `safe-package-change`) — 2026-05-19
**PRs:** [#22](https://github.com/AkaLab-Tech/atelier/pull/22) (block-env-commit + shared logging) · [#23](https://github.com/AkaLab-Tech/atelier/pull/23) (safe-commit) · [#24](https://github.com/AkaLab-Tech/atelier/pull/24) (scan-edit-write) · [#25](https://github.com/AkaLab-Tech/atelier/pull/25) (scan-git-add) · [#26](https://github.com/AkaLab-Tech/atelier/pull/26) (safe-package-change + this closure)

Final Phase 2 milestone. The five `PreToolUse` hooks that make atelier's defence-in-depth real: the static permissions matrix from M1.4 gates *which* tool an agent can call; this suite gates *with what content* the allowed call may proceed (PLAN.md §3 "Defense-in-depth"). Shipped across five sub-PRs because each hook's pattern catalogue is its own reviewable security surface; the threat-model addendum in PLAN.md §3 (finalised in M1.6) is the authoritative spec each catalogue maps to 1:1.

**Delivered:**
- `hooks/lib/log-decision.sh` (sub-PR 1) — sourceable helper. `log_decision <hook> <tool> <pattern> <action> <message>` appends one JSON line per decision to `<worktree>/.task-log/hook-decisions.jsonl`. Resolves the log path via `CLAUDE_PROJECT_DIR` (falls back to `$PWD`). Fail-soft: missing `jq`, unwritable log dir, missing path all return 0 — a hook must never abort because of a logging hiccup, and the unblocker agent (M4.2) reads the JSONL to escalate to blocked issues.
- `hooks/block-env-commit.sh` (sub-PR 1) — `PreToolUse` on Bash. Three detection paths for `.env*` in `git add` / `git commit`: literal path tokens, wildcard adds (`-A`/`.`/`--all`) resolved via `git ls-files --others --exclude-standard`, and already-staged paths via `git diff --cached`. Exit 2 with a precise message; the operator sees the offending path and the recovery hint.
- `hooks/safe-commit.sh` (sub-PR 2) — `PreToolUse` on Bash for `git commit`. Walks up looking for `package.json`, runs `pnpm run lint → typecheck → test` in order, stops on first red, returns truncated output. Steps without a matching `scripts.<name>` are N/A and continue (mirrors the M2.2 skill's contract). Escape hatch `ATELIER_SKIP_SAFE_COMMIT=1` documented in the script header. Naming collision with `skills/safe-commit/SKILL.md` (M2.2) is intentional: skill = deliberate (invoked by `pr-author`), hook = automatic (every `git commit`); both implement the same PLAN.md §6 rule at different layers.
- `hooks/scan-edit-write.sh` + `hooks/patterns/scan-edit-write.json` (sub-PR 3) — `PreToolUse` on `Edit | Write | MultiEdit`. Resolves the **proposed** content per tool (`Write.content`, `Edit.new_string`, `MultiEdit.edits[].new_string` concatenated), applies skips (`path_substrings`, `basename_prefixes`, content directive), then walks the externalised 8-pattern catalogue: 6 Block (eval/exec of user input, hardcoded secrets generic + known-prefix, Python eval) and 2 Warn (SQL/shell injection shapes, CSP relaxation).
- `hooks/scan-git-add.sh` + `hooks/patterns/scan-git-add.json` (sub-PR 4) — `PreToolUse` on Bash for `git add`. Three-phase scan per resolved path: file-level (path patterns: `.env*`, `secrets/`, `credentials/`), added-line-level (regex for AWS access keys, GitHub fine-grained PATs, substring for private-key headers, plus Shannon-entropy heuristic for ≥ 32 base64-ish runs on non-comment lines), and **reused** content scan from the scan-edit-write catalogue. Entropy calculation runs in Python with content passed via tmpfile (early version hit a HEREDOC-vs-stdin conflict — fixed mid-PR). The `Ask` action is implemented as stdout JSON `{"permissionDecision":"ask",...}` per the Claude Code hooks reference.
- `hooks/safe-package-change.sh` + `hooks/patterns/safe-package-change.json` (sub-PR 5) — `PreToolUse` on Bash for `pnpm install`/`add`/`update`/`run` and any `rm pnpm-lock.yaml`. Eight patterns: non-ASCII package name (Block, homoglyph defence), typosquatting via Levenshtein distance ≤ 2 against a 44-package curated list (Ask), package age < 7 days via `pnpm view <pkg> time` (Block, mirrors `.npmrc minimum-release-age=10080`), lifecycle script with `curl|sh`/`wget|sh`/`eval $(curl`/`node -e require('https` patterns (Block), lifecycle script presence not on the native-build allowlist (`sharp`/`puppeteer`/`playwright`/`node-gyp`/etc.) (Ask), `bin` path traversal `../` or `/` prefix (Block), non-registry version specifier (`git+`/`file:`/non-npmjs URL/tarball) (Ask), and explicit lockfile removal (Block).
- `hooks/hooks.json` — extended across the five sub-PRs to register every hook with the appropriate matcher. Final state: 1 `SessionStart` (from M1.5) + 5 `PreToolUse` entries (4 Bash + 1 Edit|Write|MultiEdit). Multiple Bash matchers coexist and all fire on every Bash call; each script filters its own subcommand of interest.
- `.gitignore` — `.task-log/` added (sub-PR 1) so the JSONL never accidentally enters version control.

**Tests:** every hook smoke-tested with synthetic stdin payloads covering its Block / Warn / Ask / Allow / Skip branches.
- sub-PR 1: 6 scenarios (`git add .env`, wildcards, chained commands).
- sub-PR 2: 7 scenarios (no package.json / empty scripts / passing lint / failing lint with truncated output / `ATELIER_SKIP_SAFE_COMMIT`).
- sub-PR 3: 20 scenarios (one positive per Block + Warn pattern, three negatives, five skips, Edit + MultiEdit variants).
- sub-PR 4: 13 scenarios across path-level, added-line, Ask (high-entropy with realistic 4.75-bit base64-ish string), reused scan-edit-write patterns, skips (snapshot files, lockfiles), wildcard catch.
- sub-PR 5: 17 scenarios across all 8 patterns (with mocked `pnpm view` for the four that need remote queries).

`shellcheck` clean on every script (only the expected `SC1091` info about the `source` directive). `jq empty` clean on every JSON.

**Decisions captured across the five PRs:**
- **`path_globs` from threat-model implemented as `path_substrings`** in both content-scanning catalogues. Bash glob-to-regex is fragile (especially `**`); the substring set covers the same files for these patterns. JSON `skips_note` field explains the mapping.
- **Pattern catalogues externalised in `hooks/patterns/<hook>.json`**, not inlined in bash. The patterns are the security surface and deserve to be reviewable independently.
- **`Ask` exit shape uses Claude Code's documented JSON output** (`{"permissionDecision":"ask",...}` on stdout) rather than a bash exit code, because the bash convention for hooks is exit 0 (allow) or 2 (block) only.
- **Naming collision `safe-commit` skill vs hook is intentional.** Skill is deliberate, hook is automatic; both implement PLAN.md §6 push gate at different layers. Documented inline in both files.
- **HEREDOC + pipe stdin compete in bash.** Bit me in scan-git-add's first version where `python3 - <<'PY' ... PY` ate the content the script was piping. Fixed with a tmpfile passed as arg 2.
- **`*"git add ."*` glob is too greedy** (matches `git add .env`). Replaced with a regex word-bounded matcher in scan-git-add after smoke test caught it.
- **BSD `date %3N` and BSD grep `\xNN` don't expand on macOS.** Both bit the implementation; log-decision falls back to second precision for the timestamp, scan-edit-write/safe-package-change use `[^ -~]` (printable-ASCII complement) instead of `\x` ranges.
- **`jq -e ... /dev/null` returns rc=4** (no JSON input); use `jq -en` (null-input mode) when only `--arg`/`--argjson` provide the data. Cost: one false-positive ask on every allowlisted package in safe-package-change before the fix.

**Acceptance criteria from the ROADMAP entry, all satisfied:**
- `git add .env` is blocked with a clear message → ✓ (block-env-commit + scan-git-add env-file-added, double defence).
- `git commit` is blocked when lint or tests fail → ✓ (safe-commit hook).
- Three content-scanning hooks reject deterministic positive cases (planted secret, planted `eval(stdin)`, planted `"postinstall": "curl … | sh"`) and pass clean cases → ✓ (all three smoke-tested with the canonical fixture shapes from the addendum).

**Phase 2 (Single-project agent flow) closed with this PR.** All four M2.x milestones merged: M2.1 (#19), M2.2 (#20), M2.3 (#21), M2.4 (#22 → #26). Next phase: M3.1 (`e2e-runner` agent + `visual-validation` skill — includes installing Playwright + browsers, which was deferred here from M1.3 to keep the install lean for operators who don't run e2e tasks).

**Follow-ups (carried forward into Phase 3+):**
- Dogfood the full chain on a real (non-toy) project (M7.1). All five hooks have been smoke-tested synthetically; a live `pnpm add` against the real npm registry is the missing end-to-end check.
- The `safe-package-change` typosquat list is intentionally minimal (44 entries). It will grow organically as M7.1 surfaces real false positives / true negatives.
- The `safe-commit` hook's default 60s Claude Code timeout will hit on projects with long test suites. The `ATELIER_SKIP_SAFE_COMMIT=1` env-var escape hatch is enough for v1; a more graceful resolution (per-project `hooks/hooks.json` override or progressive gate that runs lint/typecheck first and tests in the background) is a v2 idea.

### M2.3 — Phase 2 slash commands (`/next-task`, `/status`, `/finish-task`, `/setup-project`) — 2026-05-18
**PR:** [#21](https://github.com/AkaLab-Tech/atelier/pull/21)

Third Phase 2 milestone. Materialises the four operator-facing slash commands that drive an atelier task end-to-end. `/doctor` was already delivered in M1.6 (`commands/doctor.md`), so M2.3 effectively scopes to four new commands. Each command is a pure markdown prompt — no auxiliary scripts — that orchestrates the agents (M2.1) and skills (M2.2) already in place.

**Delivered:**
- `commands/next-task.md` (argument-hint `[task-id]`) — full pickup-to-PR flow. Sanity-checks worktree state, refuses to start if `IN_PROGRESS.md` is occupied, invokes the `atelier:task-discovery` skill (or honours an explicit `$ARGUMENTS` id), confirms with the operator before claiming, moves `ROADMAP.md → IN_PROGRESS.md`, creates the worktree via `git-wt`, instantiates `<worktree>/.claude/settings.json` by substituting `<worktree>` in `$CLAUDE_PLUGIN_ROOT/templates/settings.template.json` (the placeholder M1.4 left in the matrix), and hands off to the `atelier:task-orchestrator` agent. allowed-tools restricted to read/edit + narrow `Bash(git wt:*)`/`Bash(sed:*)` patterns + `Skill` + `Task`.
- `commands/status.md` (no args, read-only) — single-screen dashboard for the operator. Sections: in-progress task (from `IN_PROGRESS.md`), worktrees (`git wt list` + dirty-check), open PRs (`gh pr list --json …`) split into `task/*` vs out-of-band, blocked-by tasks in `ROADMAP.md`, orphans (worktree without entry / entry without worktree). Never modifies state. Falls back gracefully when `gh` or `git-wt` is unavailable.
- `commands/finish-task.md` (argument-hint `[task-id]`) — finalises the in-progress task. Identifies the task from `IN_PROGRESS.md` + the current branch, runs the push gate via the `atelier:safe-commit` skill (stops on `RED`, asks confirm on `PARTIAL`), invokes `atelier:pr-flow` for the branch → commit → push → PR sequence, and returns the PR URL. Includes a partial-recovery path for the rare push-succeeded-but-PR-not-opened case (Ctrl+C between steps).
- `commands/setup-project.md` (argument-hint `[project-path]`) — initialises a directory for atelier-managed work. Idempotent via `~/.claude/.atelier-config.json` (`projects[<path>] = { setupCompleted, setupVersion }`); if the project is already configured, default is to skip the wizard and offer a reconfigure flow on operator confirmation. Writes `.claude/settings.json` (from `settings.template.json`), creates `ROADMAP.md` + `IN_PROGRESS.md` + `HISTORY.md` if missing (operator-facing template from PLAN.md §5), writes `.claude/CLAUDE.md` that points at the global `operator-rules.md` (no duplication), writes/appends `.npmrc` with the three PLAN.md §4 guardrails (`ignore-scripts=true`, `minimum-release-age=10080`, `audit-level=moderate`), appends `.task-log/`, `.claude/settings.local.json`, `.DS_Store` to `.gitignore`. Refuses dangerous paths (`/`, `$HOME`, the plugin's own dir).

**Tests:**
- YAML frontmatter parses cleanly for all four commands (Ruby `YAML.safe_load`).
- `argument-hint` and `allowed-tools` fields well-formed; `allowed-tools` follows least-privilege per command (e.g., `/status` allows only `Bash(git wt list)`, `Bash(gh pr list:*)`, no write tools at all).
- Plugin loader discovers all five `commands/*.md` (the four new + `doctor.md` from M1.6) via `claude --plugin-dir <worktree> --permission-mode plan -p "..."`. Auto-discovery same as `agents/` (M2.1) and `skills/` (M2.2) — no entry in `plugin.json` needed.

**Decisions captured:**
- **No auxiliary scripts in `scripts/`.** Each command is a self-contained prompt. `/next-task` uses inline `sed` for the `<worktree>` substitution rather than a `scripts/instantiate-settings.sh` helper — keeps the indirection low and the substitution visible to reviewers. If a command grows complex enough to need a helper, we add it then; not pre-emptively.
- **`/finish-task` does not run `git wt rm` after merge.** The PR may need follow-up commits during review, so deleting the worktree mid-review corrupts the chain. Worktree cleanup is a manual operator step (or a future `/cleanup-task` command); the post-merge instruction lives in the success report so the operator knows when to run it.
- **`/setup-project` defaults to skip-when-configured.** First implementation tried the opposite (always offer reconfigure on re-run) and felt noisy — most re-runs are accidental. Default is now `✓ already configured — nothing to do`, with reconfigure available on explicit request.
- **`/status` is read-only by allowed-tools.** Even surface suggestions (`git wt rm <orphan>`) are printed as text, never executed. This keeps `/status` safe to run reflexively at any moment.

**Acceptance criterion status:** the ROADMAP M2.3 acceptance — *"in a toy repo, `/next-task` runs end-to-end (pick task → worktree → implement → PR draft) without manual intervention"* — is **structurally satisfied** but requires a toy-repo dogfood run to validate end-to-end. Each piece is in place (commands, skills, agents, settings template), so the gap is integration testing, not functionality. Will be exercised during M7.1.

**Follow-ups:**
- Toy-repo dogfood run (M7.1) — validates the full `/next-task → /finish-task` cycle.
- `/cleanup-task <id>` command (post-merge worktree removal + branch deletion) — currently a manual operator step; can be split out if friction surfaces.
- `/resume-task <id>` — referenced by `/next-task` and `/finish-task` but lives in M4.3.

### M2.2 — Phase 2 skills (`task-discovery`, `pr-flow`, `safe-commit`, `safe-install`) — 2026-05-18
**PR:** [#20](https://github.com/AkaLab-Tech/atelier/pull/20)

Second Phase 2 milestone. Materialises the four skills the orchestrator and specialist agents from M2.1 invoke via the `Skill` tool, per [PLAN.md §7](PLAN.md). The `git-wt` skill is **not** in this PR — it ships from the external [Miguelslo27/git-wt](https://github.com/Miguelslo27/git-wt) package (installed by `install.sh` Phase C.1, not maintained here).

**Delivered:**
- `skills/task-discovery/SKILL.md` — parses the operator-facing `ROADMAP.md` format from [PLAN.md §5](PLAN.md) (P0/P1/P2 sections with `bug`/`feat`/`chore`/`docs`/`refactor` type tags, `#id`, `~estimate`, `blocked_by:` metadata) and picks the highest-priority unblocked item. Returns a structured record (`id`, `title`, `type`, `priority`, `estimate`, `blocked_by`, `worktree` slug, `acceptance`, `context`) so the orchestrator can route the task. Handles the dual layout — operator-facing P0/P1/P2 in target projects, simpler High/Medium/Low in atelier's own repo — and refuses to pick a task when every unchecked item is blocked.
- `skills/pr-flow/SKILL.md` — branch → commit → push → PR recipe, executable form of [PLAN.md §6](PLAN.md). Step-by-step: stage explicit paths (never `-A`), Conventional Commits message via HEREDOC, push only to `origin task/<id>-<slug>`, move `IN_PROGRESS.md` → `HISTORY.md` in the same PR, open the PR with the standard description shape (Summary / Test plan / Tracking). Hard refusals listed explicitly: no push to protected branches, no `--force`, no `--no-verify`, no `Co-Authored-By` attribution, no marking the PR auto-merge-ready (that gate needs `reviewer` from M3.2), no touching `package.json` / lockfile / workflows / Docker from this flow.
- `skills/safe-commit/SKILL.md` — executable form of the push gate from [PLAN.md §6](PLAN.md). Detects the project's pnpm scripts (`lint`, `typecheck`, `test`) with fallback name conventions, runs them in order, stops on first red, returns a structured report (`✓` / `✗` per step + `Result: GREEN | RED`) so callers can parse it deterministically. Allows exactly one retry for suspected flakes; never softens reds, never `--passWithNoTests`, never quarantines tests to make a red go green.
- `skills/safe-install/SKILL.md` — executable form of [PLAN.md §4](PLAN.md). Five-step recipe: (1) self-question whether stdlib / existing utility suffices (lists common false-needs: `Intl.DateTimeFormat`, `fetch`, `crypto.randomUUID`, `structuredClone`, `URLSearchParams`), (2) `pnpm view` to compare ≥ 2 alternatives by downloads / last publish / dep tree, (3) hard-fail if `now - published < 7 days`, (4) `pnpm add --lockfile-only` + `pnpm audit --audit-level=moderate`, revert lockfile on any moderate+ finding, (5) install + write justification to commit / PR body. Belt-and-braces with the per-project `.npmrc` written by `/setup-project` (M2.3) — never relies on `.npmrc` alone, so the reasoning lives in the PR where reviewers see it.

**Tests:**
- YAML frontmatter parses cleanly for all four files (`ruby -ryaml`).
- `description` block scalars use `>-` (folded, strip) where the prose contains `:` characters — initial attempt with plain inline `description: <text>` failed YAML parsing for `pr-flow` and `safe-install` because of unquoted colons after "PLAN.md §6" / "§4"; fixed in the same PR.
- Each skill: name + description well-formed, body 86–156 lines (well under the 500-line ideal from `skill-creator`'s guidance), description 680–857 chars (well above the 10-char minimum, below the 5000-char ceiling), each starting with the action verb and explicitly listing trigger phrases per skill-creator's "pushy description" guidance.
- Plugin loader picks them up via auto-discovery (no entry needed in `plugin.json`, same auto-scan behaviour as `agents/` confirmed in M2.1 and `skills/` confirmed since M1.2).

**Decisions captured:**
- **No `references/` or `scripts/` directories yet.** Each SKILL.md is a single self-contained markdown file. The `skill-creator` recommends progressive disclosure (split into `references/<topic>.md` for larger reference material, `scripts/<task>.py` for deterministic helpers), but all four skills fit comfortably under 500 lines — adding hierarchy now would be premature.
- **`safe-install` writes the justification into the commit/PR body, not into a separate file.** The reasoning is the audit trail; burying it in a metadata file makes it invisible to reviewers. PLAN.md §4 step 3 says "justify in commit / PR description" — this skill enforces that literal interpretation.
- **`pr-flow` keeps the PR description schema explicit.** Reviewers should not have to guess which template a PR follows. Future skills (`/finish-task`, `pr-author`) will be added; the schema lives in one place so all callers produce the same shape.
- **`pr-flow` description reinforced after the manual smoke test surfaced under-triggering.** Initial wording overlapped heavily with what `operator-rules.md` (SessionStart hook from M1.5) already covers — Claude responded correctly from the hook's context without loading the SKILL.md body, even for ejecutive prompts ("open the PR for me"). Fixed by adding an explicit "ALWAYS load this skill before running any of `git add` / `git commit` / `git push` / `gh pr create`" instruction and naming `operator-rules.md` directly so Claude understands the skill **complements** the hook (the hook is summary, the skill is executable detail — HEREDOC templates, `gh pr create` body shape, hard-refusal list). `task-discovery` and `safe-commit` triggered cleanly from the start because their bodies contain content not present anywhere else in context (the §5 parsing algorithm; the GREEN/RED report schema with N/A handling). `safe-install` triggered cleanly because its stdlib-check catalogue (`Intl.DateTimeFormat`, `crypto.randomUUID`, `structuredClone`, etc.) is unique to the skill. General lesson: a skill description must promise something the SessionStart-loaded context cannot deliver, otherwise Claude will (correctly) skip it.

**Follow-ups:**
- Acceptance criterion *"exercised by at least one slash command"* — blocked on M2.3 (`/next-task`, `/finish-task` will be the canonical callers for `task-discovery` and `pr-flow` respectively).
- `safe-install` step 4 needs validation against a real `pnpm audit` output. Will be exercised when the first toy-repo dependency install happens during M7.1 dogfooding.

### M2.1 — Phase 2 agents (`task-orchestrator`, `implementer`, `tester`, `pr-author`) — 2026-05-18
**PR:** [#19](https://github.com/AkaLab-Tech/atelier/pull/19)

First Phase 2 milestone. Materialises the four agents that drive an atelier task through the chain `task-orchestrator` (Opus) → `implementer` (Sonnet) → `tester` (Sonnet) → `pr-author` (Sonnet), per [PLAN.md §7](PLAN.md). e2e-runner, reviewer, and unblocker are out of scope here (M3.1, M3.2, M4.2).

**Delivered:**
- `agents/task-orchestrator.md` (opus, color `blue`, tools: `Read`, `Grep`, `Glob`, `Edit`, `Bash`, `TodoWrite`, `Task`, `Skill`). Owns the chain: picks the next ROADMAP item via the `task-discovery` skill (when M2.2 lands; fallback today is manual), invokes `git-wt` for isolation, moves the block from `ROADMAP.md` → `IN_PROGRESS.md`, then delegates to the three specialists sequentially. Enforces the 6-attempt retry budget from [PLAN.md §8](PLAN.md). Does not write code or tests itself.
- `agents/implementer.md` (sonnet, color `green`, tools: `Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, `TodoWrite`, `Skill`). Writes the minimum-viable change against the task's acceptance criteria inside the per-task worktree. Refuses to touch `package.json` / `pnpm-lock.yaml` / `.github/workflows/**` / `Dockerfile` / `docker-compose*` — those route back to the orchestrator and ultimately a human. Reports `Changes / Verification done locally / Unresolved / Next` back.
- `agents/tester.md` (sonnet, color `yellow`, tools: `Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, `TodoWrite`). Authors unit + integration tests in the project's existing framework, runs the full lint + typecheck + test push gate from [PLAN.md §6](PLAN.md), and surfaces flakes rather than masking them. e2e/Playwright explicitly deferred to `e2e-runner` (M3.1).
- `agents/pr-author.md` (sonnet, color `cyan`, tools: `Read`, `Grep`, `Glob`, `Bash`, `TodoWrite`, `Skill`). Re-runs the push gate one more time, composes a Conventional Commits message, pushes only to `origin task/<id>-<slug>`, opens the PR via `gh pr create` with the standard description (roadmap ref, summary, validation checklist, screenshots placeholder), and moves the block from `IN_PROGRESS.md` → `HISTORY.md` in the same PR. Explicitly does **not** mark the PR auto-merge-ready (that gate requires `reviewer` from M3.2).

**Tests:** YAML frontmatter parses cleanly for all four files (`ruby -ryaml`). The official `plugin-dev` plugin's `validate-agent.sh` script passes on all four with only 3 cosmetic warnings — those are a false-positive from the script extracting only the first line of `description:` block scalars (`description: |`), the same shape used by Claude's own canonical `agent-creator.md` example. Tools list contains only known Claude Code tool names (`Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, `TodoWrite`, `Task`, `Skill`). End-to-end agent invocation will be exercised when M2.3 `/next-task` lands and the orchestrator can be reached from a slash command.

**Decisions captured:**
- **Operator rules not duplicated in each agent prompt.** PLAN.md §4 / §6 / §8 already load globally via the M1.5 `SessionStart` hook (`operator-rules.md`). Each agent's system prompt cites those sections by reference rather than re-stating them, so updates to the operator rules propagate without touching every agent file.
- **`Skill` and `Task` in the orchestrator's tool list, not `Agent`.** Claude Code's documented agent-invocation tool name inside an agent definition is `Task`; `Agent` is only the SDK-facing name. The `Skill` tool is what lets the orchestrator invoke `git-wt`, `task-discovery`, `safe-install`, etc.
- **Tester does not get `Skill`.** It does not need to invoke any skill — it operates entirely via `Bash` against the project's `pnpm` scripts. Least privilege.
- **Skeleton `README.md` files from M1.1 removed.** Manual smoke test surfaced that `agents/README.md` was being loaded as a phantom agent (`atelier:README · inherit`) in `/agents`. Same risk applied to `commands/README.md` (slash commands) and `skills/README.md` (skills). All six skeleton READMEs (`agents/`, `commands/`, `skills/`, `hooks/`, `templates/`, `scripts/`) deleted in the same PR — each directory now has real content that documents itself, so the one-line organizational note from M1.1 is no longer needed. Lesson for future skeleton scaffolding: do **not** drop a `README.md` inside a Claude Code auto-discovery directory (`agents/`, `commands/`, `skills/`) — it will be parsed as a definition.

**Follow-ups:**
- Real end-to-end smoke test (orchestrator routes implementer → tester → pr-author against a toy ROADMAP item) blocked on M2.2 (skills `task-discovery`, `pr-flow`, `safe-commit`) and M2.3 (`/next-task` slash command). Acceptance criterion "invoked from a slash command" is fully achievable only after M2.3 lands.
- `safe-install` mentions in the implementer/orchestrator prompts are forward references — the actual skill arrives in M2.2.

### M1.6 — `claude-roadmap-tools` extraction + shared catalog + `/doctor` — 2026-05-17
**PRs:** [#1 claude-roadmap-tools](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/1) (plugin published) · [#1 claude-plugins](https://github.com/AkaLab-Tech/claude-plugins/pull/1) (shared catalog) · [#11](https://github.com/AkaLab-Tech/atelier/pull/11) (atelier marketplace.json removed) · [#14](https://github.com/AkaLab-Tech/atelier/pull/14) (install.sh Phase C.2 already installed both plugins via shared catalog) · [#18](https://github.com/AkaLab-Tech/atelier/pull/18) (`/atelier:doctor` + M2.4 threat-model addendum + narrow doctor allows + this closure)

Final Phase 1 milestone. Promotes the ROADMAP/IN_PROGRESS/HISTORY tooling out of the maintainer's `~/.claude-personal/` into a public plugin (`AkaLab-Tech/claude-roadmap-tools`), registers every AkaLab-Tech plugin in a dedicated shared marketplace catalog repo (`AkaLab-Tech/claude-plugins`), drives both installs from `install.sh` Phase C.2, and ships the `/atelier:doctor` health check so operators can detect drift across the three artefacts they depend on (`atelier`, `claude-roadmap-tools`, `git-wt`).

**Delivered:**
- `AkaLab-Tech/claude-roadmap-tools` plugin and `AkaLab-Tech/claude-plugins` catalog repo (done in their own repos; this repo only references them).
- `install.sh` Phase C.2 already installs both plugins via the shared `akalab-tech` catalog (recognised retroactively — actually shipped in PR #14).
- `commands/doctor.md` (~140 lines) — pure-markdown slash command. Invoked as `/atelier:doctor` because Claude Code's built-in `/doctor` (CLI diagnostics) shadows the bare name. Six structured checks: two plugin-drift, one git-wt SHA, three host (legacy hooks / git-wt PATH / shellrc / `.npmrc` / `.atelier-config.json`). Reports `✓`/`✗`/`–` and prints exact remediation commands but never applies them.
- `templates/settings.template.json` allow list extended with 12 narrow patterns covering exactly the commands `/doctor` invokes. `Bash(gh api *)` is deliberately not allowed — only the specific endpoints (`releases/latest`, `tags`, `commits/main`) for the three known repos. Allow count: 50 → 62.
- `PLAN.md` §3 threat-model addendum (~76 lines) listing the exact pattern catalogue each M2.4 `PreToolUse` content-scanning hook checks (`scan-edit-write`, `scan-git-add`, `safe-package-change`) — match heuristic, action (Block/Warn/Ask), known false-positive surfaces per pattern. Implementation guardrails: pattern catalogues live in `hooks/patterns/<hook>.json`; every hook decision logs to `<worktree>/.task-log/hook-decisions.jsonl`. Carryover requirement from PR #16/#17 closed here.

**Tests:** `/atelier:doctor` run end-to-end on the maintainer's mac via `claude --plugin-dir <worktree>`. Produced the expected `✓`/`✗`/`–` report. Detected a real git-wt SHA drift (`ac88a32 → 8a734bc`, the maintainer's own upstream fix to `git wt rm`'s cwd-orphan bug). Plugin checks correctly emitted `–` because AkaLab-Tech/atelier and AkaLab-Tech/claude-roadmap-tools have no published releases/tags yet. Auxiliary checks resolved as expected for the maintainer's environment (`–` for `.npmrc` and `.atelier-config.json` since the maintainer's view is the atelier repo itself, not an operator-managed project).

**Decision captured during the PR:** the bare `/doctor` name collides with Claude Code's built-in `/doctor` (CLI install diagnostics). Plugin slash commands are namespaced as `<plugin-name>:<command-name>`, so `commands/doctor.md` in the atelier plugin is invoked as `/atelier:doctor`. The first end-to-end smoke test surfaced this — the user got the built-in's output instead. Documented in the command's intro paragraph and the PR description.

**Phase 1 (Foundation) closed with this PR.** All six M1.x milestones merged: M1.1 (#4), M1.2 (#5 + #11), M1.3 (six sub-PRs #7/#8/#12/#13/#14/#15), M1.4 (#16), M1.5 (#17), M1.6 (#18). The plugin now installs end-to-end on a clean Mac VM, both plugins coexist via the shared `akalab-tech` catalog, operator rules load via `SessionStart` hook, and `/atelier:doctor` reports drift. Next: Phase 2 (M2.1 agents, M2.2 skills, M2.3 slash commands, M2.4 content-scanning hooks).

**Follow-ups (carried forward):**
- Publish initial `v0.1.0` releases / tags on `AkaLab-Tech/atelier` and `AkaLab-Tech/claude-roadmap-tools` so the plugin drift checks can resolve to `✓`/`✗` instead of `–`. Not blocking — `/doctor` correctly handles the no-releases case today.
- M2.4 implementation will use the threat-model addendum as the authoritative pattern catalogue. The catalogue is reviewable as-is; tuning happens during the per-hook implementation sub-PRs.

### M1.5 — Plugin-shipped operator rules (`SessionStart` hook) — 2026-05-17
**PR:** [#17](https://github.com/AkaLab-Tech/atelier/pull/17)

Single-sub-PR Phase 1 milestone: ship the rules atelier's agents must follow on every task in an atelier-managed project. Mechanism revised mid-PR after re-reading the [Claude Code plugins reference](https://code.claude.com/docs/en/plugins-reference): a `CLAUDE.md` at the plugin root is **not** loaded as project context — the official path for unconditional context injection is a `SessionStart` hook whose stdout becomes context.

**Delivered:**
- `operator-rules.md` (plugin root) — clean markdown that condenses PLAN.md §4 (dep installs), §6 (push/PR/merge gates), §7 (agent chain), §8 (failure-recovery retry budget) into operator-facing prose (no maintainer content). ~95 lines.
- `hooks/load-operator-rules.sh` — bash script that `cat`s `operator-rules.md` to stdout. Path resolved via `${CLAUDE_PLUGIN_ROOT}` per the plugins reference. Fails soft on missing file (stderr note + exit 0) so a corrupted plugin never locks the operator out of a session.
- `hooks/hooks.json` — registers the `SessionStart` hook. Uses the documented exec-form command quoting around `${CLAUDE_PLUGIN_ROOT}`.

**Tests:** end-to-end validated by running `claude --plugin-dir <worktree>` and asking "What are the atelier operator rules?" — Claude responded with a faithful summary of all four sections, including verbatim phrases from `operator-rules.md`, which confirms hook discovery → SessionStart firing → stdout-to-context pipe → on-demand retrieval all work as designed. Also: `bash -n`, `shellcheck` (0.11.0), `jq empty hooks/hooks.json`, direct hook invocation with `CLAUDE_PLUGIN_ROOT=<worktree>`, missing-file fallback exit code.

**Decision captured during the PR:** the ROADMAP M1.5 entry literally said "ship a CLAUDE.md". The investigation surfaced that this approach does not actually load context (per the plugins reference, plugins contribute context via skills / agents / hooks, not CLAUDE.md). The implemented `SessionStart` hook is the official mechanism. Cost: ~500-800 tokens of context per session. Trade-off: token cost for autonomy guarantee accepted, since the rules apply to every atelier task and operators should never have to re-run install.sh to opt in to them.

**Follow-ups:**
- Threat-model addendum for M2.4 content-scanning hooks (carryover from PR #16) — still required before any matcher code in M2.4 lands.

### M1.4 — `settings.template.json` (static permissions matrix) — 2026-05-17
**PR:** [#16](https://github.com/AkaLab-Tech/atelier/pull/16)

Single-sub-PR Phase 1 milestone: materialize the allow / deny / ask permissions matrix from PLAN.md §3 at `templates/settings.template.json`. The template stays a template until M2.3 `/setup-project` / `/next-task` instantiate it per-task with the worktree path injected.

**Delivered:**
- `templates/settings.template.json` — 87 permission rules total: 33 deny, 4 ask, 50 allow. `defaultMode: acceptEdits`. `additionalDirectories: ["<worktree>"]` as the substitution placeholder. Faithful 1-to-1 mapping against PLAN.md §3.
- `PLAN.md` §3 gains a **"Defense-in-depth"** note: this matrix is the static layer (gates *which tool* can be called); the M2.4 hook suite is the dynamic layer (validates *content* of allowed tool calls). Neither alone is enough.
- `ROADMAP.md` M2.4 expanded from 2 hooks to 5 with three new content-scanning hooks — `scan-edit-write`, `scan-git-add`, `safe-package-change` — plus a pre-implementation note requiring a threat-model addendum in PLAN.md §3 before any matcher code lands.

**Tests:** `jq empty` validates the template parses as JSON; a sample instantiation (`sed 's|<worktree>|/tmp/sample|g' …`) substitutes the placeholder in every spot (additionalDirectories, Read/Edit/Write patterns) and the result re-parses cleanly. Real per-task instantiation by Claude Code is exercised when M2.3 `/next-task` lands.

**Decision captured during the PR:** the user pushed back on shipping a static-only permissions model — defense-in-perimeter is not defense-in-depth. The static template ships now; the dynamic content-validation hooks land with M2.4 (scope expanded in the same PR). Both layers must hold for a real attack to land.

**Follow-ups:**
- Threat-model addendum to PLAN.md §3 listing the exact pattern catalogue each M2.4 content-scanning hook checks — required before any matcher code in M2.4 lands.
- Real per-task instantiation validation by `/next-task` (M2.3) — confirms Claude Code accepts the substituted file.

### M1.3 — `install.sh` (Phases A + B + C.1 + C.2) — 2026-05-17
**PRs:** [#7](https://github.com/AkaLab-Tech/atelier/pull/7) (npmrc decision) · [#8](https://github.com/AkaLab-Tech/atelier/pull/8) (Phase A) · [#12](https://github.com/AkaLab-Tech/atelier/pull/12) (Phase B) · [#13](https://github.com/AkaLab-Tech/atelier/pull/13) (Phase C.1) · [#14](https://github.com/AkaLab-Tech/atelier/pull/14) (Phase C.2) · [#15](https://github.com/AkaLab-Tech/atelier/pull/15) (final verification + closure)

Phase 1 milestone: top-level installer that takes a fresh Mac (or Ubuntu best-effort) from "factory" to "ready to run atelier tasks". Implemented across 6 PRs.

**Delivered:**
- `install.sh` (548 lines) with strict mode + helpers + OS detection + 5 phases + verification block.
- **Phase A**: brew (mac) / apt (linux) installs of `git`, `gh`, `fnm`, `jq`, `fzf` + `corepack`-managed `pnpm`. Claude Code via Anthropic's official native installer (`curl -fsSL https://claude.ai/install.sh | bash`).
- **Phase B**: Claude OAuth (`claude auth login`) + GitHub HTTPS auth (`gh auth login --git-protocol https --skip-ssh-key`), idempotent via `claude auth status` / `gh auth status`, no-TTY-safe.
- **Phase C.1**: external `git-wt` install + SHA recording in `~/.local/state/atelier/git-wt.sha` for `/doctor` (M1.6); `.env*` in git global excludes; git identity prompts with current values as defaults (per PR #9), no-TTY-safe; shellrc hooks (`fnm env --use-on-cd`, `task() { claude "/next-task $*"; }`, `task-status` alias) injected into `~/.zshrc` / `~/.bashrc` via sentinel-bounded idempotent block, with unwritable-shellrc graceful fallback.
- **Phase C.2**: `claude plugin marketplace add AkaLab-Tech/claude-plugins` + `claude plugin install atelier@akalab-tech` + `claude plugin install claude-roadmap-tools@akalab-tech` (CLI verbs, not slash-commands), idempotent via `--json` + `jq`, with missing-claude / unauthed fallback that prints the manual commands and continues.
- **Verification block** (`phase_verify`): 6 `✓`/`✗` checks (`claude --version`, `claude auth status`, `gh auth status`, `git wt help`, both plugins installed) plus an inline note that `/doctor` lands in M1.6.

**Bugs discovered during testing & fixed in-flight:**
- `unzip` missing from apt deps (broke `fnm` install on a clean Ubuntu) — fixed in PR #8 commit `d40dd33`.
- git-wt SHA not recorded on idempotent re-runs (when git-wt was already on PATH from a manual install) — fixed in PR #13.
- Unwritable shellrc caused a fatal error mid-Phase-C.1 — fixed in PR #13 (warn with exact `sudo chown` command, skip, continue, exit 0).

**Decisions captured along the way:**
- npmrc supply-chain guardrails are per-project (written by `/setup-project` in M2.3), not global (PR #7).
- Marketplace name `akalab-tech` differs from plugin name `atelier` to avoid an `atelier@atelier` resolver collision (M1.2 / PR #5).
- Marketplace catalog moved to a dedicated `AkaLab-Tech/claude-plugins` repo so multiple AkaLab-Tech plugins can coexist under one marketplace (PR #11).
- `claude auth login` (CLI verb) instead of `/login` (slash command) for Phase B — slash commands only work inside an interactive `claude` session.
- `claude plugin …` (CLI verbs) instead of `/plugin …` (slash commands) for Phase C.2 — same rationale.

**Tests:** validated on macOS arm64 (Tart clean VM in PR #13 + maintainer's mac end-to-end across every sub-PR) and Ubuntu 24.04 ARM (Multipass clean VM in PR #8). `shellcheck` 0.11.0 clean across every sub-PR.

**Follow-ups:**
- `/doctor` slash command (tracked under M1.6) — turns the verification block into a callable plugin command and adds drift detection against `gh api repos/Miguelslo27/git-wt/commits/main` using the recorded SHA.
- A single clean-Mac-VM end-to-end run on squashed `main` as M7.x dogfood.
- Maintainer's `~/.zshrc` ownership keeps reverting to `root:wheel` periodically — outside atelier's scope, but worth tracking to root-cause (some installer or sudo invocation is touching it).

### M1.2 — Plugin manifest and marketplace — 2026-05-12
**PR:** [#5](https://github.com/AkaLab-Tech/atelier/pull/5)

Second Phase 1 milestone: stand up the plugin manifest and the marketplace catalog so atelier becomes installable via Claude Code's native plugin system.

**Delivered:**
- `.claude-plugin/plugin.json` — name `atelier`, version `0.1.0`, description, author (AkaLab-Tech), homepage, repository, keywords. No `skills` field (the default `skills/` scan path is sufficient; an explicit entry would only add a redundant scan).
- `.claude-plugin/marketplace.json` — vendor-scoped marketplace named `akalab-tech` with one plugin entry pointing at `source: "./"`. Plugin and marketplace names intentionally differ to avoid an `atelier@atelier` resolver collision discovered during validation.
- PLAN.md §1 step 11, §12, and ROADMAP.md M1.3 Phase C.2 updated for the new install command (`atelier@akalab-tech`).

**Tests:** end-to-end install validated in an operator Claude Code session — `/plugin marketplace add <worktree-path>` reported `Successfully added marketplace: akalab-tech`, `/plugin install atelier@akalab-tech` reported `✓ Installed atelier`, and `/reload-plugins` ran without manifest errors. `jq empty` validates both JSON files.

**Follow-ups:**
- Global `~/.npmrc` already has `ignore-scripts=true` (the guardrail PLAN.md §2 step 5 will enforce), which breaks the standalone `claude` CLI's native-binary postinstall (the user-facing `/plugin marketplace add` slash command in an existing Claude Code session works fine; only the standalone CLI does not). M1.3 (`install.sh`) must install Claude Code before applying the guardrail, or scope the guardrail to project-level npmrc instead of global.

### M1.1 — Repo skeleton — 2026-05-12
**PR:** [#4](https://github.com/AkaLab-Tech/atelier/pull/4)

First Phase 1 milestone: prepare the on-disk layout the plugin and host-OS layers will populate in M1.2–M1.5.

**Delivered:**
- Created `.claude-plugin/`, `agents/`, `skills/`, `commands/`, `hooks/`, `templates/`, `scripts/` at the repo root.
- Added a one-line `README.md` to each, naming its purpose.
- Tracking: removed M1.1 from `ROADMAP.md` and routed it through `IN_PROGRESS.md` to this entry.

**Tests:** `ls` shows the seven directories at the repo root; each contains a `README.md` whose first line names its purpose.

<!-- ## YYYY-MM

### Example title — YYYY-MM-DD
**PR:** [#N](https://github.com/<org>/<repo>/pull/N)

One- or two-sentence framing of why this PR existed.

**Delivered:**
- Bullet 1
- Bullet 2

**Tests:** one line on the validation done.

**Follow-ups:** (optional)
- Bullet
-->
