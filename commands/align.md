---
description: Align every registered atelier project/workspace to the installed atelier in one pass — version-drift resync + decision policy (Tier 1, applied by atelier-align), §5 ROADMAP adoption + legacy IN_PROGRESS reset (Tier 2, via /adopt-roadmap), and one commit-to-base PR per changed repo (Tier 3). Surveys read-only first; applies nothing without confirmation (or pre-consent via `auto` policy).
argument-hint: "[<workspace-slug>] [--policy <auto|ask>]"
allowed-tools: Bash(atelier-align:*), Bash(atelier-setup-project:*), Bash(git:*), Bash(gh:*), Read, AskUserQuestion, SlashCommand, Task
---

You are running `/atelier:align` — the one-pass project/workspace aligner. It
converges every registered project to the installed atelier across three tiers.
Survey first; under `ask` policy never apply without a confirmation gate; under
`auto` policy run autonomously per pre-consent; never push directly to a base
branch.

## Interaction mode

**Non-interactive** if `$ARGUMENTS` has `--yes`/`-y` or `$ATELIER_AUTO` is set:
print the plan and stop — apply nothing (Tier 1/2/3 all touch files or remotes).
This headless flag is a **dry-run / preview** path and is **orthogonal** to
`decisionPolicy.default`. `ATELIER_AUTO + align` always previews and applies
nothing, regardless of each member's policy setting.

## Step 1 — survey (read-only)

```bash
atelier-align $ARGUMENTS --plan
```

(Pass a `<workspace-slug>` through to scope to one workspace; default is every
registered project.) Relay the report. It lists each project's needs: `resync`
(version drift `↻`), `policy` (if `--policy` given), `adopt-section5` (foreign
ROADMAP), `maybe-reset-inprogress`, `restore` (partial config), `unregister`
(missing dir). Note: the sanctioned High/Med/Low layout is **not** flagged for §5.

## Step 1b — resolve effective policy per member

Before applying anything, determine the **effective policy** for each member. This
governs whether confirmation gates fire in Step 2 and Step 4.

- Read `decisionPolicyDefault` from `atelier-align --json` output (field
  `decisionPolicyDefault` per project), or from the `policy <pol>` line in the
  human plan output.
- **Post-Tier-1 override:** if this same run passes `--policy auto` in
  `$ARGUMENTS`, members being set to `auto` are governed by `auto` for Tier 2/3 of
  this same run — they do not yet have `auto` in their `.atelier.json`, but this
  run's intent already authorizes autonomous behaviour for them.
- Effective policy is **per-member**: a mixed-policy workspace keeps `ask` members
  interactive and runs `auto` members autonomously. Never collapse per-member
  policies to a single global value — gate each member on its own effective policy.

Effective policy values:
- **`auto`** — operator has pre-consented via `decisionPolicy.default=auto`; skip
  confirmation gates for this member.
- **`ask`** (or any other value, or unknown/`?`) — use the interactive confirmation
  gates below, exactly as today.

If `$ATELIER_AUTO` is set or `--yes`/`-y` is in `$ARGUMENTS`, this step is moot —
stop after Step 1 (headless preview; nothing will be applied).

## Step 2 — Tier 1: mechanical (resync drift + policy)

**Under `ask` policy:** confirm with `AskUserQuestion` (apply Tier 1 now? include
policy=auto?) before applying. **Under `auto` policy:** skip the confirmation gate
— the operator has pre-consented.

In a mixed-policy workspace, ask before processing any member whose effective
policy is `ask`; proceed without asking for members whose effective policy is
`auto`.

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
open one PR per repo:

- Resolve the base branch (prefer `dev` if `origin/dev` exists, else the default
  branch). Use a **temporary worktree** so the operator's checkout is untouched:
  `git -C <repo> worktree add -b chore/atelier-align <tmp> origin/<base>`, copy in
  the changed `.atelier.json` / settings / adopted tracking, and commit
  (Conventional Commits, **no AI attribution**). Authoring the PR itself (push +
  `gh pr create`) happens per the effective policy below, then remove the
  temporary worktree once the PR is open.

Then, **per the member's effective policy**:

### Tier 3 under `ask` (interactive)

**Offer** (via `AskUserQuestion`) to open the PR for each repo — push the branch
and run `gh pr create --base <base>` inline in this session. Do **not** merge —
the operator merges on their own timeline. If the operator declines, print the
exact per-repo commands instead. Do **not** push directly to the base branch.

### Tier 3 under `auto` (autonomous)

Delegate the base-PR authoring to the **`pr-opener` agent** (via `Task`) — one
dispatch per repo — instead of running `gh pr create` inline in this session:
hand it `repo` (owner/name), `worktree` (the temporary worktree path), `base`,
`head` (`chore/atelier-align`), `title`, and `body`. `pr-opener` runs the push
gate, pushes the branch, and opens the PR under the author identity, then
returns the PR URL; it does not remove the temporary worktree (do that once its
PR URL comes back). Delegating the authoring this way means this session never
ran `git push` / `gh pr create` for the PR itself, so the `reviewer` dispatch in
step 1 below runs from a clean, non-authoring actor and does not trip the
auto-mode classifier's self-approval block. Then drive each opened base PR
through the guardrailed merge path — **in this order, per repo**:

1. **Review:** invoke the `reviewer` agent (via `SlashCommand`) against the PR.
   The reviewer checks the commit content and posts an approval or requests changes.
2. **Merge:** invoke `/atelier:auto-merge` against the PR. The skill evaluates the
   six PLAN.md §6 guardrails and, when all pass, runs
   `gh pr merge --squash --delete-branch`. Do **not** ask the operator to confirm
   the merge — the guardrails ARE the authorization (see `skills/auto-merge`
   § "Authorization model — the gate IS the consent"). If `auto-merge` returns
   `held`, surface the held reason and stop waiting; do **not** bypass the
   guardrail, do **not** call `gh pr merge` directly, and do **not** prompt the
   operator to merge manually.
3. **Fast-forward the operator's local checkout:** after the PR merges, run
   `git -C <repo> pull --ff-only` on the operator's checkout of the base branch.
   Tier 3 used a throwaway worktree, leaving the operator's local checkout behind
   `origin/<base>`; this pull brings it up to date. This is a **local pull only** —
   do **not** push to the base branch.

## Step 5 — report

Summarize per project: resynced / policy-set / adopted / PR-opened / PR-merged
(auto) / local-pulled (auto) / skipped. Under `auto`: confirm each base PR was
merged and the operator's local checkout fast-forwarded — no manual merge chore
remains. Under `ask`: remind the operator to merge the offered base PRs. In both
cases: remind about restarting open sessions / `exec zsh` if shellrc changed, and
filling `TODO` placeholders in adopted roadmaps.

## Hard rules

- **Survey before apply; headless (`--yes` / `$ATELIER_AUTO`) prints the plan
  only.** The headless flag is a dry-run axis independent of `decisionPolicy`.
  `ATELIER_AUTO + align` always previews and applies nothing, even when every
  member's policy is `auto`.
- **Never** rewrite tracking files inline (that is `/adopt-roadmap`'s job), never
  nag the sanctioned High/Med/Low layout.
- **No AI attribution** in commits/PRs (atelier convention).
- Reuse `atelier-align` (survey + Tier 1), `/adopt-roadmap` /
  `/atelier:onboard-workspace` (Tier 2), and the temp-worktree PR flow (Tier 3) —
  do not reimplement them.
- **Under `ask`: never push to or merge a base branch.** The operator merges on
  their own timeline; print exact per-repo commands if they decline the PR offer.
- **Under `auto`: Tier 3 base PRs merge only through `/atelier:auto-merge`** (the
  six PLAN.md §6 guardrails + `gh pr merge --squash --delete-branch`). Never push
  directly to the base branch. Never call `gh pr merge` outside of the `auto-merge`
  skill. If `auto-merge` holds, surface the held reason and stop — do not bypass it.
- **Never suggest adding a `gh pr merge` permission rule.** `Bash(gh:*)` is already
  granted in align's `allowed-tools` frontmatter — the merge command is permitted
  by design. Raising a permission question here is a false signal that wastes the
  operator's attention.
- **Under `auto`, never emit an off-spec `AskUserQuestion` about reviewing or
  merging a base PR.** Reviewing is the `reviewer` agent's job; merging is the
  `auto-merge` skill's job. Any `AskUserQuestion` gate about these under `auto` is
  a contract violation regardless of phrasing ("shall I merge?", "confirm before
  main?", "OK to land this?" are all the same violation).
