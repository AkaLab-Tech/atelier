---
description: Align every registered atelier project/workspace to the installed atelier in one pass — version-drift resync + decision policy (Tier 1, applied by atelier-align), §5 ROADMAP adoption + legacy IN_PROGRESS reset (Tier 2, via /adopt-roadmap), and one commit-to-base PR per changed repo (Tier 3). Surveys read-only first; applies nothing without confirmation.
argument-hint: "[<workspace-slug>] [--policy <auto|ask>]"
allowed-tools: Bash(atelier-align:*), Bash(atelier-setup-project:*), Bash(git:*), Bash(gh:*), Read, AskUserQuestion, SlashCommand
---

You are running `/atelier:align` — the one-pass project/workspace aligner. It
converges every registered project to the installed atelier across three tiers.
Survey first; never apply without confirmation; never push to a base branch.

## Interaction mode

**Non-interactive** if `$ARGUMENTS` has `--yes`/`-y` or `$ATELIER_AUTO` is set:
print the plan and stop — apply nothing (Tier 1/2/3 all touch files or remotes).

## Step 1 — survey (read-only)

```bash
atelier-align $ARGUMENTS --plan
```

(Pass a `<workspace-slug>` through to scope to one workspace; default is every
registered project.) Relay the report. It lists each project's needs: `resync`
(version drift `↻`), `policy` (if `--policy` given), `adopt-section5` (foreign
ROADMAP), `maybe-reset-inprogress`, `restore` (partial config), `unregister`
(missing dir). Note: the sanctioned High/Med/Low layout is **not** flagged for §5.

## Step 2 — Tier 1: mechanical (resync drift + policy)

Confirm with `AskUserQuestion` (apply Tier 1 now? include policy=auto?). On yes:

```bash
atelier-align $ARGUMENTS --apply --policy <auto|ask> --yes
```

This resyncs drifted projects (`atelier-setup-project --reconfigure`) and sets
`decisionPolicy.default` — **working-file** writes. For `restore` projects, run
`/atelier:setup-project <path>`; for `unregister`, suggest
`atelier-remove-project <path>` (operator-confirmed).

## Step 3 — Tier 2: content (§5 adoption, judgment)

For each project the survey marked `adopt-section5` (genuinely foreign — never
High/Med/Low), drive adoption (interactive, one at a time): `cd <path>` then
`/adopt-roadmap --format atelier` (or `/atelier:onboard-workspace <slug>` to do a
whole workspace's members at once). For `maybe-reset-inprogress`, `Read` the
`IN_PROGRESS.md` and offer `/adopt-roadmap` only if it's a legacy multi-task
tracker (Phase 3a classification). Never rewrite tracking files yourself.

## Step 4 — Tier 3: commit to base (one PR per changed repo)

Tier 1/2 changed **working files**; they only take effect once committed to each
repo's base branch (`next-task` reads `origin/<base>`; the broker reads
`.atelier.json` from the per-task worktree). For each repo with pending changes,
**offer** (via `AskUserQuestion`) to open one PR per repo:

- Resolve the base branch (prefer `dev` if `origin/dev` exists, else the default
  branch). Use a **temporary worktree** so the operator's checkout is untouched:
  `git -C <repo> worktree add -b chore/atelier-align <tmp> origin/<base>`, copy in
  the changed `.atelier.json` / settings / adopted tracking, commit (Conventional
  Commits, **no AI attribution**), push the branch, `gh pr create --base <base>`,
  then remove the worktree.
- Do **not** push to the base branch directly; do **not** merge — the operator
  merges. If the operator declines, print the exact per-repo commands instead.

## Step 5 — report

Summarize per project: resynced / policy-set / adopted / PR-opened / skipped, and
what still needs the operator (merge the base PRs, fill `TODO` placeholders in
adopted roadmaps). Remind: restart open sessions / `exec zsh` if shellrc changed.

## Hard rules

- **Survey before apply; confirm before any write.** Headless prints the plan only.
- **Never** rewrite tracking files inline (that is `/adopt-roadmap`'s job), never
  push to or merge a base branch, never nag the sanctioned High/Med/Low layout.
- **No AI attribution** in commits/PRs (atelier convention).
- Reuse `atelier-align` (survey + Tier 1), `/adopt-roadmap` / `/atelier:onboard-workspace`
  (Tier 2), and the temp-worktree PR flow (Tier 3) — do not reimplement them.
