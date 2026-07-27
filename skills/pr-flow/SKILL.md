---
name: pr-flow
description: >-
  Drive a green worktree to an open pull request — branch → commit → push → PR
  — and return the PR URL. ALWAYS load this skill before running any of
  `git add`, `git commit`, `git push`, or `gh pr create` on an atelier task,
  including dry-runs and walkthroughs: the `operator-rules.md` SessionStart
  hook only summarises PLAN.md §6 policy, while this skill carries the
  executable detail — exact HEREDOC commit-message template, exact `gh pr
  create` body shape (Summary / Test plan / Tracking), exact ordered command
  sequence, exhaustive hard-refusal list, and the `IN_PROGRESS.md` →
  `HISTORY.md` tracking move that must land in the same PR. Use this skill
  whenever the user wants to ship/finalise/PR a change, invokes
  `/atelier:finish-task`, says "open the PR", "push my work", "ship this", "finish
  the task", or anywhere the `pr-author` agent needs the recipe. Enforces
  push and PR gates from PLAN.md §6 (push only to `origin task/<id>-<slug>`,
  Conventional Commits). Refuses protected-branch pushes, `--force`,
  `--no-verify`, `Co-Authored-By` attribution, and marking the PR
  auto-merge-ready (that gate needs the `reviewer` agent). Trigger
  even when the user does not say "PR" explicitly — any phrasing about
  shipping the change belongs here.
---

# pr-flow

A skill for turning a finished change in a per-task worktree into an open pull request, exactly the way PLAN.md §6 prescribes.

## Preconditions

Do not run this skill if any of these are true — instead, stop and report what's missing:

- Not on a branch named `task/<id>-<slug>`. (Other branch names are denied by the global push rules.)
- The push gate (lint + typecheck + unit + integration tests) is not green. Run `safe-commit` first to verify; do **not** push otherwise.
- The current worktree's branch is `main`, `master`, `develop`, `staging`, or matches `release/*` or `hotfix/*`. These are protected and accept no pushes from agents.
- There is no entry for this task in `IN_PROGRESS.md`. The flow assumes the orchestrator already moved the block here when the task started.

## The flow

Apply each step in order. Use `Bash` for git/gh; never edit `package.json` or other denied files in this flow.

### 1. Stage only the files that belong to this task

Use explicit paths, not `git add -A` / `git add .`:

```sh
git add <path1> <path2> …
git status --short
```

If `git status` shows anything you did not mean to commit (stray temp files, `.task-log/`, IDE droppings), unstage it. The push is non-revocable enough that a tight stage is worth the extra second.

### 2. Compose the commit message — Conventional Commits

Format:

```text
<type>(<scope>): <subject>

<body>
```

- `type` ∈ `feat | fix | chore | docs | refactor | test | perf | build | ci`.
- `scope` is the area touched (`plugin`, `install`, `hooks`, `agents`, project-area, etc.). Skip the parens entirely when no scope makes sense.
- `subject` is imperative (`add`, `fix`, `remove` — not `added`/`fixed`).
- The **body** is non-optional for atelier tasks. It cites:
  - The roadmap entry being closed (e.g. `Closes #<task-id>`).
  - The acceptance criteria, in 1–3 bullets.
  - For dependency additions: the PLAN.md §4 justification (self-question + ≥2 alternatives compared + why this choice).

**Always pass the message via a HEREDOC** so multi-line bodies survive shell quoting. **Always prefix `git commit` with `GIT_CONFIG_GLOBAL=$ATELIER_CONFIG_DIR/git-identity.conf`** so the commit's Author / Committer fields match the atelier-author GitHub identity (dual-gh-id), not the operator's personal global git config:

```sh
GIT_CONFIG_GLOBAL="$ATELIER_CONFIG_DIR/git-identity.conf" git commit -m "$(cat <<'EOF'
feat(reports): add CSV export at /reports

Closes #42.

- Button "Export" downloads the active-filtered view as CSV.
- Filter state preserved via the existing useReportFilters() hook.
EOF
)"
```

The identity file is written at install time by `install.sh` Phase B (`phase_b_capture_atelier_git_identity`) — `[user] name = AtelierAuthor` + `email = <id>+<login>@users.noreply.github.com`. The env-var prefix scopes the override to this single `git` invocation; the operator's `~/.gitconfig` is never modified. If the file is missing (shouldn't be — `/atelier:doctor` flags it), commits fall back to the operator's global identity, which works but mixes attribution with the atelier-author push token; surface a `warn` to the operator and continue.

### 3. Size gate — `atelier-pr-size-check` before the tracking move and before the push

The gate runs here, on the code commit alone: it is local-only (`git diff <base>...<branch>`, no network, no PR object), so this is the earliest point at which it can run at all — and running it before step 4 is what keeps the OVERSIZE path coherent, because the task's `IN_PROGRESS.md` entry is still active and can carry the `[OVERSIZE]` marker. Once step 4 has moved that entry to `HISTORY.md` there is nothing left to mark.

```sh
atelier-pr-size-check --branch task/<id>-<slug> --base main --project <worktree>
```

The tool reads `<worktree>/.atelier.json` (or built-in defaults) and applies the AND-gate over post-exemption counts. Exit codes:

- **0** within budget → continue to step 4.
- **1** OVERSIZE → **do NOT open the PR**, and **do not run step 4** — the task is not done, so its tracking entry must not move to `HISTORY.md`. Prepend the `[OVERSIZE]` marker to the task's heading in `<worktree>/IN_PROGRESS.md` (skip this edit on a project whose tracking lives in a backend rather than in files) and commit it as `chore(tracking): mark #<id> [OVERSIZE] — see size-check output`; then still run step 5 so the branch reaches `origin` and the operator can open the PR by hand. Surface the tool's stdout (including the suggested slice boundaries) back to the caller (`pr-author` agent or the operator). The marker rides the task branch, whose PR is never opened — landing an operator-visible marker on the base branch is `task-orchestrator`'s step 8. Opening the PR in this oversized shape would only consume a `reviewer` cycle and land at the auto-merge gate as held.
- **2** error → fail loudly (typical causes: `jq` / `gh` missing, malformed `.atelier.json`).

The count here is code-only in the literal sense — step 4's commit does not exist yet, so nothing bookkeeping can be counted. That does **not** mean the budget exempts bookkeeping: `DEFAULT_EXEMPT` covers lockfiles, generated files, tests and migrations, not `IN_PROGRESS.md` / `HISTORY.md`, so the `--pr`-mode run later (reviewer / auto-merge, on the pushed branch) counts the tracking commit too and lands slightly above this verdict. This gate is the cheap early check, not the authoritative one — a near-budget pass here can still be held there. A project that genuinely wants its tracking files out of the count sets its own `prSize.exempt` in `.atelier.json`. Deferring the check entirely to `auto-merge` would be too late (the reviewer already spent their cycle).

### 4. Move tracking — same commit set, not a follow-up

The `roadmap-tracking-flow` convention (this repo, single-file layout) and the operator-facing PLAN.md §5/§6 both require `IN_PROGRESS.md` and `HISTORY.md` to be updated **inside this PR**, not in a follow-up commit on the protected branch after merge. Do one of:

- **(preferred)** add a separate commit on this same branch that removes the block from `IN_PROGRESS.md` and appends a new entry to `HISTORY.md`. The PR number is known after step 6; pre-fill it with the predicted next number, and reconcile after the PR is open if it differs.
- amend the previous commit if the tracking edit was forgotten — only if that commit has not yet been pushed.

The `HISTORY.md` entry follows the existing template:

```markdown
### <task-id> — <short title> — YYYY-MM-DD
**PR:** [#NN](<repo>/pull/NN)

<1–2 sentence framing of why this PR existed.>

**Delivered:**
- <bullet>
- <bullet>

**Tests:** <one-line summary of validation done>.

**Follow-ups:** (optional)
- <bullet>
```

### 5. Push only to `origin task/<id>-<slug>`

```sh
git push -u origin task/<id>-<slug>
```

If the current branch name does not start with `task/`, stop — the static permissions matrix and the global rules will reject it anyway. Never use `--force` and never bypass hooks (`--no-verify`, `--no-gpg-sign`) without explicit operator authorisation. This step runs on the OVERSIZE path too (carrying the code commit + the marker commit), so the branch is on `origin` either way; only step 6 is skipped.

### 6. Open the PR with `gh pr create`

```sh
gh pr create \
  --base main \
  --head task/<id>-<slug> \
  --title "<type>(<scope>): <subject>" \
  --body "$(cat <<'EOF'
## Summary

- <bullet 1>
- <bullet 2>

## Test plan

- [x] <push gate item that ran green>
- [x] <push gate item that ran green>
- [ ] <anything still pending — say so explicitly>

## Tracking
- `ROADMAP.md`: <task-id> block removed.
- `IN_PROGRESS.md`: empty (was <task-id> mid-PR).
- `HISTORY.md`: new entry under `## YYYY-MM`, references this PR as `#<predicted-number>`.
EOF
)"
```

The title must be **under 70 characters** (GitHub truncates anything longer in lists). Keep the body's `## Summary` to 1–3 bullets; details belong in commit messages, not PR descriptions.

### 7. Report the PR URL

Return:

```text
commit:     <short-sha> <subject>
branch:     origin task/<id>-<slug>
PR:         <url>
tracking:   IN_PROGRESS → HISTORY updated in this PR
```

## Hard refusals

These are non-negotiable — surface a clear error and stop:

- Push to `main`, `master`, `develop`, `staging`, `release/*`, `hotfix/*`.
- `--force` push of any kind.
- `--no-verify` to skip pre-commit hooks, unless the operator explicitly says "skip hooks once because <reason>".
- Adding `Co-Authored-By: Claude` (or any agent attribution) to the commit message or PR body. The operator has opted out.
- Marking the PR ready for auto-merge. Auto-merge requires the `reviewer` agent to approve through the `auto-merge` skill; `pr-flow` only opens a normal PR.
- Touching `package.json`, `pnpm-lock.yaml`, `.github/workflows/**`, `Dockerfile`, `docker-compose*` from this flow. Those changes belong elsewhere and must be called out in the PR description so reviewers and the `auto-merge` skill know this PR is human-only.

