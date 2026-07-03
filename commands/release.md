---
description: Cut a version release for a project through the independent pr-author → reviewer → auto-merge chain — the command never authors or merges the bump PR from its own turn.
argument-hint: "[<version>|major|minor|patch] [--project <path>] [--all] [--yes|-y]"
allowed-tools: Read, Bash(atelier-release:*), Bash(git fetch:*), Bash(git tag:*), Bash(git push origin v*), Bash(git describe:*), Bash(git log:*), Bash(git rev-parse:*), Bash(gh pr view:*), Skill, Task, AskUserQuestion
---

You are running the `/atelier:release` slash command. Cut the **next** SemVer release for one project (per [PLAN.md §14](PLAN.md), design decision recorded in §14.9) by driving the same independent chain every other atelier PR goes through — `pr-author` → `reviewer` → auto-merge. **This command never authors, reviews, or merges the bump PR from its own turn.** Authoring and review are always two separate `Task` dispatches, exactly as for an ordinary task.

User input: `$ARGUMENTS` (optional) — may carry, in any order:
- an explicit override: `major`, `minor`, `patch`, or a literal `X.Y.Z` / `vX.Y.Z` version (overrides the inferred bump);
- `--project <path>` (default: the repo root of the operator's current checkout, `git rev-parse --show-toplevel`);
- `--all` — **reserved for #44, not implemented here** (see step 1);
- `--yes` / `-y` — non-interactive consent, same convention as `/atelier:next-task`.

## Interaction mode (read once at the start)

Before doing anything that would otherwise pause for operator input, decide whether you are running in **non-interactive** mode. You are non-interactive if **any** of these is true:

- `$ARGUMENTS` contains the literal token `--yes` (surrounded by whitespace or string boundaries).
- `$ARGUMENTS` contains the literal token `-y` (surrounded by whitespace or string boundaries — not embedded in another flag).
- The environment variable `ATELIER_AUTO` is set to any non-empty value. Probe with `env | grep -E '^ATELIER_AUTO='`.

If none of those is true, you are **interactive**. In non-interactive mode, **never** use `AskUserQuestion` — auto-resolve per the per-step rule documented inline. `interactive: false` (or the equivalent prose) must be propagated into **every** `Task` dispatch this command makes (`implementer`, `pr-author`, `reviewer`), so a specialist never stalls waiting for input that will not come in a headless run.

## Steps

### 1. Parse arguments and refuse `--all`

Strip `--yes` / `-y` before parsing the rest. If `--all` is present, **stop immediately** — do not proceed to any other step, do not create a worktree, do not dispatch anything:

```text
✗ /atelier:release --all is not implemented yet (#44) — resolve and release one project at
   a time: /atelier:release [<version>|major|minor|patch] --project <path>
```

Extract the remaining override token (if any) and `--project <path>` (if any).

### 2. Resolve the target project and fetch

Resolve `<project>`: the `--project <path>` value if given, else `$(git rev-parse --show-toplevel)` from the operator's current checkout. This command operates directly on `<project>`'s own `main` branch and `origin` remote — it is **not** itself run from inside a task worktree, and it does not touch the operator's working tree beyond a `fetch`.

```bash
git -C <project> fetch origin main
```

This refreshes `origin/main` so the resolution step reads the freshest merged history — a recently-merged PR may have shipped commits that change the inferred bump.

### 3. Resolve the next version — `scripts/atelier-release resolve`

Run the pure helper (never hand-roll version math here):

```bash
atelier-release resolve --project <project> [<override>]
```

Read its JSON stdout and its exit code:

- **Exit 2** — usage error (bad override, missing `jq`, `<project>` not a git repo, etc.). Surface the stderr message verbatim and stop. No chain is dispatched.
- **Exit 0, `noop: true`** — nothing to release. Print `"Nothing to release since <last_tag>"` (or "since the beginning of history" if `last_tag` is `null`) and stop. This is a clean terminal state, not an error — **no chain is dispatched.**
- **Exit 1, `refuse_reason` set** — the helper refused (dirty working tree at `<project>`, local `main` behind `origin/main`, or the resolved `next_version` does not advance past `current`). Surface `refuse_reason` verbatim and stop. **No chain is dispatched** — never work around a refusal by retrying with a different override without telling the operator why the first one failed.
- **Exit 0, `noop: false`** — proceed to step 4 with `current`, `next_version`, `inferred_bump`, `unreleased_commits`, and `pr_body_lines` from the JSON.

### 4. Confirm with the operator

Display a short summary: `current` → `next_version` (`inferred_bump` or the explicit override), and the count of `unreleased_commits`.

- **Interactive mode:** ask explicitly via `AskUserQuestion`: *"Cut release v<next_version>?"*. On no, stop — nothing else runs.
- **Non-interactive mode:** log a single line `auto-releasing v<next_version> (non-interactive)` and proceed. The operator's `--yes` / `-y` (or `ATELIER_AUTO=1`) **is** the consent.

### 5. Create the release worktree — `git-wt` skill

Invoke the `git-wt` skill (or `git wt switch <branch> --from origin/main` directly, scoped to `<project>`) to create a worktree for branch **`task/release-<next_version>`** — **never** `release/*` or `hotfix/*`. `pr-flow` and the permission matrix ([PLAN.md §3](PLAN.md)) refuse pushes to `release/*` / `hotfix/*` outright (they are treated as protected branches), so the release bump must ride a `task/*`-shaped name to be pushable at all. Capture the absolute worktree path the skill prints — every following step is scoped to it.

A release has **no** roadmap/board item, so there is no tracking-file move to make in this step — unlike `/atelier:next-task` step 6, this command never edits `ROADMAP.md` / `IN_PROGRESS.md` (or calls `moveTask`) for the release branch.

### 6. Bump the version — `implementer` dispatch (`Task`)

This command carries no `Edit` / `Write` tool — it cannot touch `.claude-plugin/plugin.json` (or the equivalent version file) itself, and would not even if it could: the bump is a specialist's deliverable like any other code change. Dispatch the `atelier:implementer` agent via `Task` with a narrow briefing:

- `worktree_path`: the absolute path from step 5.
- The **only** change to make: set `.claude-plugin/plugin.json`'s `.version` field (or the project's equivalent version manifest) to `<next_version>`. No other files.
- `interactive: <bool>` from this command's interaction mode.

Wait for the dispatch to report the edit is done before proceeding — do not assume it landed.

### 7. Author the release PR — `pr-author` dispatch (`Task`, separate from step 8)

Dispatch the `atelier:pr-author` agent via `Task`. This is a **separate** `Task` call from the `reviewer` dispatch in step 8 — the harness classifier blocks an agent from approving its own PR, and the author identity (`GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/author`) lacks repo-admin, so authoring and reviewing a release bump must stay two independent dispatches exactly as they do for an ordinary task (see [PLAN.md §14.9](PLAN.md)).

The briefing must make explicit that this is a **release PR with no board item**, so `pr-author` runs its normal first-pass flow (push gate → code commit → push → size gate → `gh pr create` → return PR URL) **except step 3 is skipped entirely**: there is no `IN_PROGRESS.md` / `HISTORY.md` entry (and, on a non-`files` backend, no `moveTask` / `appendHistoryEntry` call) to make for a release, so there is nothing to move. State this explicitly in the briefing prose — it is **not** the same thing as `pr-author`'s existing `follow_up: true` re-push mode (which also skips `gh pr create`, because in that mode the PR already exists); a release PR is opened for the first time, so `gh pr create` still runs. Do **not** edit `agents/pr-author.md` to add a formal flag for this — the per-dispatch briefing carries the instruction, the same way `task-orchestrator` carries one-off contextual instructions (e.g. `plan_storage` mode) to specialists without a dedicated flag per agent file.

Also pass, so the PR body is self-documenting:
- `branch`: `task/release-<next_version>`.
- The commit message: `chore(release): v<next_version>`.
- The PR body's shipped-changes section, pre-populated from `pr_body_lines` (step 3's JSON) — one bullet per unreleased commit, so the PR auto-lists exactly the commits/PRs this release ships without `pr-author` having to re-derive it.
- `interactive: <bool>` from this command's interaction mode.

Wait for `pr-author` to return the PR URL (or `oversized` / gate-red) before proceeding. On `oversized` or gate-red, stop and surface it — do not retry silently or push a tag.

### 8. Independent review — `reviewer` dispatch (`Task`, separate from step 7)

Dispatch the `atelier:reviewer` agent (Opus, fresh context) via `Task` against the PR URL/number from step 7. This is always a **second, independent** `Task` dispatch — never the same subagent turn as step 7, and never approved by this command itself. `reviewer` runs under `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/reviewer`, a distinct GitHub identity from the author, so its `gh pr review --approve` lands as a real, separate approval that `reviewDecision` reflects.

### 9. Auto-merge — `atelier:auto-merge` skill

Once `reviewer` has posted its verdict, invoke the `atelier:auto-merge` skill against the PR. It evaluates the six guardrails from [PLAN.md §6](PLAN.md) and squash-merges only when all pass. `.claude-plugin/plugin.json` is not on the auto-merge "never merge" forbidden-path list, so a clean release bump merges the same way any other small PR does — no special-casing needed here. If the skill reports `held: <reason>`, stop and surface the hold; **do not push a tag against an unmerged PR.**

Capture the **merge commit SHA** and the PR number from the skill's output — step 10 needs the SHA.

### 10. Push the annotated tag — only after merge

**Never** push the tag before this point. Once (and only once) step 9 confirms the PR is merged:

```bash
git -C <project> fetch origin main
git -C <project> tag -a v<next_version> <merge-sha> -m "atelier v<next_version>"
git -C <project> push origin v<next_version>
```

The tag targets the **merge commit SHA** captured in step 9, not whatever `origin/main` resolves to at push time (a race with another concurrent merge could otherwise tag the wrong commit). `Bash(git tag -a v*)` and `Bash(git push origin v*)` are allowlisted in `templates/settings.template.json` specifically for this step — both patterns are anchored on the literal `v` + version and cannot match a branch push (atelier branches are always `task/*`), and neither is shadowed by the `Bash(git push * main|master|develop|staging)` deny rules, which require a literal protected branch name as the final token.

### 11. Print the operator update recipe

After the tag is pushed, print the standard three-step recipe so the operator can pick up the new version:

```text
✓ Released v<next_version> (was v<current>) — PR #<NN> merged, tag v<next_version> pushed.

  To pick up the update:
    claude plugin marketplace update akalab-tech
    claude plugin update atelier@akalab-tech
    atelier-update
```

## Output

End the command with the block from step 11, or — for any terminal state reached earlier (step 1's `--all` refusal, step 3's noop/refusal, step 4's operator decline, step 7's oversized/gate-red) — that state's own message **is** the command's output. Report exactly which step stopped and why; the operator decides whether to resume.

## Hard refusals

- **Never** implement `--all` — refuse per step 1 and point to #44 (`scripts/atelier-release enumerate` is a documented stub, not a working feature).
- **Never** author, review, or merge the bump PR from this command's own turn. This command carries no `Edit`/`Write` tool and no `gh pr merge`/`gh pr review` in its `allowed-tools` — the version bump is `implementer`'s deliverable, the PR is `pr-author`'s, the review is `reviewer`'s, and the merge is the `atelier:auto-merge` skill's, each a separate `Task`/`Skill` dispatch.
- **Never** let the same `Task` dispatch both author and review the PR — steps 7 and 8 are always two separate calls, matching the two distinct GitHub identities (`gh/author` vs `gh/reviewer`) the harness classifier and repo permissions require.
- **Never** ride the release bump on `release/*` or `hotfix/*` — `pr-flow` and the permission matrix refuse pushes to those names outright. The branch is always `task/release-<version>`.
- **Never** push the `vX.Y.Z` tag before `atelier:auto-merge` confirms the PR is merged. Tagging an unmerged commit (or a stale `origin/main` HEAD instead of the actual merge SHA) would point the tag at the wrong commit.
- **Never** edit `agents/pr-author.md` to add a formal "no board item" flag for this — carry the "skip step 3, no tracking move applies" instruction in the per-dispatch briefing prose, exactly as other one-off contextual instructions reach specialists today.
- **Never** silently retry `scripts/atelier-release resolve` with a different override after a refusal — surface the `refuse_reason` to the operator (or, non-interactively, to the log) and stop.
