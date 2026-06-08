# Troubleshooting

Quick reference for when something doesn't work. Symptoms first — search this page for what you see on screen, then read the fix.

If you can't find your symptom here, the most recent entries in `HISTORY.md` and the dogfood-test logs in `docs/dogfood-guide.md` cover many real failures with their fixes.

---

## Always first: run the doctor

```bash
atelier-doctor               # from any shell
atelier-doctor --fix         # apply auto-fixable repairs in one pass
```

Inside a Claude session the same checks live at `/atelier:doctor` (with `--fix` as an arg). Each `✗` line in the doctor's report carries the fix command — `--fix` applies the ones it can resolve on its own (templates symlink, stale shellrc block, marketplace not registered, missing helper symlinks). Re-run plain `atelier-doctor` afterward to confirm.

If the doctor flags a version mismatch between the installed atelier and the latest released tag, run `atelier-update` and re-check.

For checks the doctor cannot perform (it can't reach the network, your shell hasn't loaded the hooks yet, etc.), see the sections below.

---

## Setup-time problems

Issues that come up while running `install.sh` or right after.

### `task: command not found` after install

**Symptom:** Install finished cleanly. Running `task` in a new terminal gives `command not found`.

**Cause:** The shell hasn't loaded atelier's shell functions yet.

**Fix:** Run `source ~/.zshrc` (or `~/.bashrc` on bash). Alternative: open a fresh terminal — same effect.

### `install.sh` fails on Phase A (system tools)

**Symptom:** Install stops with a Homebrew (Mac) or apt (Linux) error before reaching the "Phase B" output.

**Cause:** A base dependency (`git`, `gh`, `fnm`, `pnpm`, `jq`, `fzf`) couldn't install.

**Fix:** Install the failing tool by hand using your package manager, then re-run `./install.sh`. The installer is idempotent: it picks up where it left off (M7.1.F6).

### `install.sh` keeps prompting to log in with the same GitHub account

**Symptom:** During Phase B, after logging in to GitHub for the "author" identity, the install rejects the same identity for the "reviewer" with a "same as 5a" error.

**Cause:** Your browser remained logged in to one GitHub account between the two prompts. atelier needs **two separate** GitHub accounts: one for the agent that writes code, one for the agent that approves it. Same-identity approvals get downgraded to comments by GitHub itself (see "Auto-merge skipped my PR" below).

**Fix:** Open https://github.com/logout in the browser, then sign in with your second account when the next prompt fires. If you don't have a second account, [create one](https://github.com/signup) — it's free.

### `install.sh` finishes but Claude still loads the wrong config

**Symptom:** `claude` in a new terminal doesn't show atelier's slash commands like `/atelier:doctor`.

**Cause:** Bare `claude` loads your personal Claude config, not atelier's isolated one. atelier ships the `atelier` shell function that pins `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR` before invoking `claude`.

**Fix:** Always launch atelier sessions with `atelier ...` (not `claude ...`). The slash commands (`/atelier:doctor`, `/atelier:setup-project`, etc.) only appear when the atelier-isolated config is loaded.

---

## Runtime problems

Issues that come up while running a task.

### `task` opens but immediately exits / picker doesn't fire

**Symptom:** Running `task` returns to the shell prompt without launching Claude.

**Cause:** `atelier-task-resolve` is missing from `PATH`, or `~/.local/bin` isn't on `PATH` yet.

**Fix:** Re-run `./install.sh` from the atelier checkout — this refreshes the symlinks at `~/.local/bin/atelier-*`. Then `source ~/.zshrc`.

### `atelier-task-resolve` says "no projects registered" but you have set up a project

**Symptom:** Running `task` from anywhere prints `atelier: no projects registered yet. Run /atelier:setup-project <path> first.`

**Cause:** `$ATELIER_CONFIG_DIR/projects.json` is missing or unreadable. This happens if `atelier-uninstall --purge` was run and then a project was set up without re-registering it.

**Fix:** Run `atelier-list-projects` to confirm the registry is empty. Then `cd` into each project that should be registered and run `atelier /atelier:setup-project .` — it's idempotent and only writes the registry entry if it doesn't exist.

### `/next-task` stops at step 2 — "a task is already in progress" but you never started one

**Symptom:** `/next-task` refuses to claim a task, reporting `IN_PROGRESS.md` as occupied, even though no atelier task is running. The file is full of sections like `RLS`, `ADMIN`, `WEB`, `i18n` with `[x]`/`[ ]` items.

**Cause:** the project predates the atelier tracking flow. Its `IN_PROGRESS.md` is a hand-rolled **multi-phase progress tracker**, not the single active-task slot the flow expects. `/next-task` correctly refuses to overwrite a non-empty slot — but here the slot was never one task, it's a phase board.

**Fix:** normalize the tracking in place with **`/adopt-roadmap`** (from the `claude-roadmap-tools` plugin): done items move to `HISTORY.md`, open items to `ROADMAP.md`, and `IN_PROGRESS.md` is reset to an empty slot — nothing is dropped. Re-running `/atelier:setup-project` in the project also detects this layout (M7.1.F50) and offers to run `/adopt-roadmap` for you. If the plugin is not installed: `claude plugin install claude-roadmap-tools@akalab-tech`. After adoption, `/next-task` picks the next item normally.

### `atelier --help` prints nothing / "atelier-help.txt: No such file"

**Symptom:** Running `atelier --help` shows an empty output or a "file not found" error pointing at `$ATELIER_CONFIG_DIR/atelier-help.txt`.

**Cause:** The help file was introduced in **M7.1.F34** (v0.7.1) and is written by `install.sh` Phase C.1. Older installs never had it, and `atelier-update` will refresh it the next time it runs.

**Fix:** Run `atelier-update`. If it still fails, re-run `./install.sh` from the atelier checkout — phase `phase_c_1_atelier_help_file` writes the file unconditionally.

### `atelier-update` says "already up to date" but the doctor still warns about a stale version

**Symptom:** `atelier-update` exits with "already up to date — no template refresh needed", but `atelier-doctor` keeps flagging a plugin-version mismatch.

**Cause:** The atelier git clone (`~/atelier`) is at the latest tag but `$ATELIER_CONFIG_DIR/templates/` or the plugin cache lags behind. This was the dogfood-5 finding behind **M7.1.F31**: a no-op `git pull` skipped the template refresh.

**Fix:** Force the refresh: `atelier-update --force` (or delete `$ATELIER_CONFIG_DIR/templates/` and re-run `atelier-update`). Then re-launch any open Claude sessions so they pick up the refreshed settings template.

### `claude plugin install` fails with "marketplace not registered"

**Symptom:** `install.sh` or `atelier-update` fails on the `claude plugin install atelier@akalab-tech` step with a message about the `akalab-tech` marketplace not being registered.

**Cause:** The marketplace was removed (e.g. by `atelier-uninstall --purge` or a manual `/plugin marketplace remove`) and never re-added. `claude plugin install` cannot fetch a plugin from a marketplace that isn't in `$ATELIER_CONFIG_DIR/`'s config.

**Fix:** `atelier-doctor --fix` auto-repairs this (it re-adds `AkaLab-Tech/claude-plugins` under the atelier config root). Or run it manually:
```bash
CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin marketplace add AkaLab-Tech/claude-plugins
```

### `atelier` warns about "running from inside another atelier session" (fork-bomb guard)

**Symptom:** Inside an existing `atelier` Claude session, you run `atelier` again from a `Bash` tool call and see a warning about a recursive launch.

**Cause:** This is the **M7.1.F28** fork-bomb guard. atelier nests Claude sessions one level deep at most; a second nested `atelier` would create an unbounded prompt-cache cascade.

**Fix:** Don't nest. Run the inner command (`atelier-doctor`, `atelier-update`, `atelier-list-projects`, etc.) as a plain shell call without the `atelier` prefix — the `atelier-*` helpers already pin `CLAUDE_CONFIG_DIR` correctly on their own.

### Auto-mode classifier still prompts for an unexpected command

**Symptom:** Even though atelier sessions run under auto-mode (M2.8, v0.8.0+), a Bash command you expected to be auto-approved surfaces a permission prompt — usually framed as *"Do you want to proceed?"*.

**Cause:** Auto-mode is a **second gate**, not a replacement for the static matrix. Two distinct prompt sources still fire even with auto-mode on:

1. **The static `ask` matrix** in `templates/settings.template.json` — these are commands atelier explicitly marked as "always confirm with the operator" (e.g. anything touching `package.json`, `Dockerfile`, deploy paths). The classifier never sees these because the matcher resolves them first.
2. **The classifier's own decision** — for commands not enumerated in `allow` / `deny` / `ask`, auto-mode evaluates and may decide the action is non-obvious enough to warrant a prompt anyway (e.g. a compound Bash like `cd /some/path && git fetch && gh pr view 120 --json mergeable` — multiple state-touching ops chained together).

**Fix (per-call):** Accept the prompt once with **Yes**, or pick **"Yes, and don't ask again for: `<pattern>`"** to add the pattern to `.claude/settings.local.json` (project-local, untracked).

**Fix (per-project):** If the command is genuinely safe and you want it pre-allowed for every task on this project, add it to the project's `.claude/settings.json` allow list (under your control). Don't add it to atelier's `templates/settings.template.json` unless it's safe for every atelier project — that file is the cross-project default.

**Fix (per-machine, last resort):** Disable auto-mode by editing `$ATELIER_CONFIG_DIR/settings.json` and changing `.permissions.defaultMode` from `"auto"` to `"acceptEdits"`. You go back to pre-M2.8 behavior — more prompts, but predictable.

To check whether auto-mode is currently active, inside any atelier session: `/status` → Config tab → `Default permission mode`. Should show `Auto mode`.

### A high-risk command pauses, or asks when you didn't expect it (semantic risk judge)

**Symptom:** On a project where you enabled the optional semantic risk judge (M2.9), a Bash command touching your lockfile, `Dockerfile`/`docker-compose`, `.github/workflows/`, `package.json`, or a deploy/infra path takes a beat longer than usual, or surfaces a permission prompt with a reason like *"Haiku flagged a deploy action: …"*.

**Cause:** This is the opt-in layer-3 gate working as designed. When `semanticRiskJudge.enabled` is `true` in the project's `.atelier.json`, the `semantic-risk-judge` hook runs a quick Haiku judgement on commands that touch the high-risk surface (catalogued in `hooks/patterns/semantic-risk-judge.json`) and escalates the ones it judges overeager to an `ask`. The short pause is that single model call; only high-risk commands reach it (a cheap local check filters everything else first).

**It is fail-open.** If the judge can't reach the model (no network, missing `claude` CLI, timeout), it **allows** the command and records a degraded line in `<worktree>/.task-log/hook-decisions.jsonl` — it never blocks just because the model was unavailable. It also never hard-blocks: the worst it does is ask.

**Fix (per-call):** If the flagged command is fine, accept the prompt with **Yes**.

**Fix (per-project):** To turn the layer off entirely, set `"semanticRiskJudge": { "enabled": false }` in the project's `.atelier.json` (or remove the block — it defaults to off). Review past decisions in `<worktree>/.task-log/hook-decisions.jsonl` (look for `"hook":"semantic-risk-judge"`).

### `pnpm install` rejected because of `minimum-release-age`

**Symptom:** A dependency install fails with a `minimum-release-age` error mentioning a 10080-minute (7-day) threshold.

**Cause:** atelier's per-project `.npmrc` (created by `/atelier:setup-project`) enforces a 7-day cool-off for new package versions — defense against supply-chain attacks where a malicious version is published and removed before maintainers notice (PLAN.md §4).

**Fix (recommended):** Wait until the version is 7+ days old, or pick a slightly older known-good version.

**Fix (override, only when you've personally vetted the package):** Edit the project's `.npmrc` and comment out the `minimum-release-age` line, install, then restore the line. Don't commit the change.

### A hook blocked an edit / commit you expected to work

**Symptom:** An edit, write, or commit fails with a hook message like "blocked by `scan-edit-write`" or "blocked by `block-env-commit`".

**Cause:** One of the M2.4 PreToolUse hooks intercepted the operation:
- `block-env-commit` — refuses any commit that touches `.env*` files.
- `scan-edit-write` — refuses an edit/write whose content matches a sensitive-pattern catalog.
- `scan-git-add` — refuses a `git add` that stages a `.env*` file.
- `safe-package-change` — refuses a `pnpm add/install/update` for a too-new package or unauthorized post-install scripts.
- `safe-commit` — refuses a commit when lint or tests fail.

**Fix:** Read the hook's message — it cites the specific pattern that triggered it. Address the underlying issue (remove the sensitive content, wait out the cool-off, fix the failing test, etc.). The pattern catalogs are read-only and live at `~/.claude-work/plugins/cache/akalab-tech/atelier/<version>/hooks/patterns/*.json` if you want to understand the trigger.

### Auto-merge skipped my PR

**Symptom:** The pull request was opened and reviewed, but atelier didn't auto-merge it.

**Cause:** This is by design (PLAN.md §6). Auto-merge holds back any PR that:
- Touches `package.json` / `pnpm-lock.yaml`
- Touches `Dockerfile` / `docker-compose*`
- Touches `.github/workflows/**`
- Trips the **size gate** — the default budget is `>200 lines AND >10 files` (AND-gate, after exemptions for tests/lockfiles/migrations) per `scripts/atelier-pr-size-check`. Override per-project in `<project>/.atelier.json`. PRs that trip the gate are tagged `[OVERSIZE]` by `pr-author` and the orchestrator stops without retrying (M4.24 + M7.1.F27).
- Has pending human review comments
- Has a `request-changes` from the reviewer

**Fix:** Review the PR yourself and merge it manually (`gh pr merge <N> --squash --delete-branch`). The held-back rules protect dependencies, CI, and large changes from going in without a human check. If you'd rather have atelier break the work into smaller tasks automatically, run `/atelier:slice-task` against the offending roadmap item — the `task-decomposer` agent will rewrite it as an epic with sub-tasks (M4.24).

### Reviewer's `gh pr review --approve` shows as a comment, not an approval

**Symptom:** The reviewer agent ran `gh pr review --approve` but the PR still shows zero approvals in `gh pr view`. Auto-merge is held.

**Cause:** Author and reviewer are the same GitHub identity. GitHub silently downgrades approvals when the reviewer is the PR author — there's no way to override this server-side. This is **dogfood-1 finding #11**.

**Fix (recommended):** Re-run `./install.sh`, log out from GitHub in the browser between the two prompts, and sign in with a different account for the reviewer identity.

**Fix (single-developer pattern):** Accept that single-account projects merge manually. Memorize:
```bash
gh pr merge <N> --squash --delete-branch
```

### Task is stuck — atelier created a `blocked` GitHub issue

**Symptom:** atelier opened a GitHub issue labeled `blocked` and stopped working on a task.

**Cause:** This is the failure-recovery path (PLAN.md §8). atelier tried up to three implementation attempts, reset the worktree, tried three more, and gave up. The issue contains the `.task-log/<timestamp>-<attempt>.md` files describing each failure.

**Fix:** Read the latest `.task-log` excerpt in the issue to understand what went wrong. Decide:
- **(a) Retry:** refine the task description in `ROADMAP.md`, close the `blocked` issue, then run `task` again.
- **(b) Abandon:** close the `blocked` issue with a `wontfix` comment, manually mark the task `[x]` in `ROADMAP.md` (or move to `HISTORY.md`). Optionally remove the worktree with `git wt rm <name>`.

### Edits succeed on a deny-listed path after a worktree reset

**Symptom:** During retry attempts 04–06 (after the first reset between attempts 03 and 04), Claude completes an `Edit` call on a path that's in the project's deny list. Earlier attempts (01–03) on the same path were correctly refused.

**Cause:** Claude Code's permission cache is stale. When `retry-with-logs` removes and recreates the worktree, the harness's per-session deny patterns don't always re-evaluate the recreated directory. This is **dogfood-1 finding B** — a Claude Code harness limitation, not an atelier bug.

**Mitigation until Claude Code fixes the harness:** When the orchestrator triggers a reset between attempt 03 and 04, **restart your Claude Code session** before continuing. The fresh session loads `.claude/settings.json` clean and the deny patterns apply correctly.

### `git-wt` commands fail

**Symptom:** `task` opens Claude but task-orchestrator errors with "command not found: git-wt" or "git-wt: invalid usage".

**Cause:** The external `git-wt` binary at `~/.local/bin/git-wt` is missing, outdated, or shadowed by a different `git-wt` on `PATH`.

**Fix:** Run `atelier-doctor` (or `atelier-doctor --fix` to auto-repair the symlink when possible) — the report will flag the issue with the exact fix. The fix is the snippet from `install.sh:check_git_wt_drift` (clone, run `install.sh --skill-for=claude`, record the SHA). Or simply re-run `./install.sh` from the atelier checkout.

### `atelier-hooks-version` mismatch warning during install

**Symptom:** `./install.sh` prints `→ refreshing atelier shellrc block (v0 → v1)` (or similar version pair).

**Cause:** This is **expected behavior** when upgrading atelier from one version to a later one (M7.1.F7c). The shellrc block in your `~/.zshrc` is older than the current `install.sh` ships; the installer strips the old block and re-injects the new one in place.

**Fix:** Nothing. The message is informational. After `source ~/.zshrc`, the new shell functions (`task`, `atelier`) are active.

---

## When all else fails

If the doctor passes but tasks still fail or atelier behaves unexpectedly:

1. **Capture the doctor output:** `atelier-doctor > /tmp/doctor.txt`
2. **Confirm you're on the latest atelier:** `atelier-update` (no-op if you're current).
3. **Find the failing worktree:** look at `IN_PROGRESS.md` to identify the active task; the worktree lives at `~/Work/<project>-worktrees/<task>/`.
4. **Read the most recent task log:** `cat ~/Work/<project>-worktrees/<task>/.task-log/*.md | tail -200`. The log records each attempt with full agent output.
5. **Check the `blocked` GitHub issues:** `gh issue list --label blocked` shows tasks that hit the retry budget.
6. **Open a bug report:** https://github.com/AkaLab-Tech/atelier/issues/new — paste the doctor output and the last task log entry.

---

## Reset everything (nuclear option)

If atelier is in a state you cannot unwind from the steps above, you can wipe and reinstall. Your project files and any `.claude/` folders inside your projects are **not** touched.

```bash
atelier-uninstall --purge          # removes ~/.claude-work entirely (atelier's config root)
rm -rf ~/atelier                   # removes the downloaded source
git clone https://github.com/AkaLab-Tech/atelier ~/atelier
cd ~/atelier
./install.sh
```

After re-install, re-register each project with `atelier /atelier:setup-project <path>` (idempotent — won't overwrite existing files). Confirm the registry with `atelier-list-projects` once you're done.

### Less drastic: remove just one project

If only one project is broken and the rest of atelier is healthy, you don't need to nuke everything. Run:

```bash
atelier-remove-project <path>           # deregister; keep files
atelier-remove-project <path> --purge   # also strip the .gitignore / .npmrc atelier-additions
```

Then re-run `atelier /atelier:setup-project <path>` if you want to start fresh on that project.

---

## Decision broker (M4.26, v0.9.0+)

### atelier made a strategic decision I disagree with

**Symptom:** the PR's `## Autonomous decisions taken` section shows atelier picked an option for a catalogued category (e.g. `oversize-handling: open-anyway`) that you would have decided differently.

**Cause:** your project's `.atelier.json` `decisionPolicy` has that category set to `"auto"`, and the broker's evaluator agent picked the option. The choice is logged with a rationale; the choice is not a bug — it's the broker doing exactly what the policy said.

**Fix:**

1. **For this PR specifically**: revert the autonomous decision by hand (e.g. close the PR and split the task; or merge but address the choice in a follow-up). The decision was logged; the PR body has the rationale you can challenge.
2. **For future tasks in this project**: set the offending category to `ask` (or to a fixed option id you prefer) in `<project>/.atelier.json`. Either edit the file directly:

   ```json
   {
     "decisionPolicy": {
       "byCategory": {
         "oversize-handling": "ask"
       }
     }
   }
   ```

   Or run `/atelier:set-policy oversize-handling` from inside an atelier session and pick `[s]ask`.
3. **For this category in every project**: if the catalog's `default` is wrong for your context across all projects, open an issue at https://github.com/AkaLab-Tech/atelier/issues. The catalog is atelier-managed and only the maintainer changes it.

### `/atelier:abort-auto` did not stop atelier from deciding autonomously

**Symptom:** you ran `/atelier:abort-auto` from inside an atelier session and a subsequent strategic decision was still made autonomously.

**Cause (most likely):** you are running the chain in a different worktree than the one where you ran `abort-auto`. The panic flag is **per-worktree** at `<worktree>/.atelier-abort-auto.flag` — by design, so parallel chains in sibling worktrees don't accidentally panic each other.

**Fix:** check which worktree you are actually in:

```bash
git rev-parse --show-toplevel
ls -la .atelier-abort-auto.flag
```

If the flag is not in the worktree where the chain is running, re-run `/atelier:abort-auto` from there. If it IS there but the broker still decided autonomously, this is a real bug — capture the entry in `<worktree>/.task-log/decisions.jsonl` (look for `source` not equal to `"panic"`) and open an issue with that entry verbatim.

### `task --policy=auto` didn't make atelier fully autonomous

**Symptom:** ran `task --policy=auto` but atelier still asked the operator at some point during the chain.

**Cause:** the wrapper flag overrides `decisionPolicy.default`, but it does **not** override per-category fixed values or `byCategory.<category>: "ask"` entries. **Specific beats global.** If you set `oversize-handling: "ask"` in `.atelier.json`, that category will continue to ask even when `--policy=auto` is in effect.

**Fix:**

1. Inspect the project policy: `cat <project>/.atelier.json | jq .decisionPolicy`.
2. Use `--ask-for` for the categories you want asked, and let `--policy` cover the rest. The two are designed to combine: `task --policy=auto --ask-for=merge-conflict-substantive #42`.
3. If you want a clean slate per-invocation, edit `.atelier.json` once and remove the offending per-category entries — those that `task --policy=auto` would override.

### `## Autonomous decisions taken` section is missing from a PR I expected it on

**Symptom:** a task ran under `auto` policy and the resulting PR has no audit section in its body.

**Cause (most likely):** the broker resolved every situation via `mode: ask` or `mode: panic` — both are operator-resolved interactively and produce no autonomous decision to audit. `pr-author` skips the section when the JSONL only contains those modes; restating ask-resolved decisions in the PR body adds noise without adding signal.

**Less likely**: the `<worktree>/.task-log/decisions.jsonl` file is missing or unreadable. Check inside the worktree.

**Fix:** none usually. If you want a section regardless, set at least one category to `auto` or to a fixed option id in `.atelier.json` so a non-ask decision actually gets logged.

### Catalog says my category is missing

**Symptom:** atelier surfaced a strategic decision to you with the rationale *"Category 'X' is not in the atelier catalog yet. Falling back to operator decision."*

**Cause:** the broker hit a situation that does not match any catalogued category. The fallback (asking the operator) is correct; the message is a **growth signal** — atelier's catalog should grow to cover this case.

**Fix:**

1. Resolve the immediate decision yourself, the same way you would pre-broker.
2. Open an issue at https://github.com/AkaLab-Tech/atelier/issues describing the situation: what the agent was about to ask, what the legitimate options were, and what you ended up choosing. The maintainer adds the category in a future version.
