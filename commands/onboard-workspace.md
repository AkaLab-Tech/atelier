---
description: Onboard every member of a workspace into atelier's required tracking shape from one place — detect members whose ROADMAP.md is not PLAN.md §5 (and legacy IN_PROGRESS.md slots) and drive `/adopt-roadmap --format atelier` for each, so the operator does not have to `cd` into each repo. Read-only detection via `atelier-workspace-status`; the only writes are `/adopt-roadmap`'s own, per member, with confirmation.
argument-hint: "[<workspace-slug>] [--yes|-y]"
allowed-tools: Bash(atelier-workspace-status:*), Bash(cd:*), Read, AskUserQuestion, SlashCommand
---

You are running `/atelier:onboard-workspace` — the workspace-level front for tracking adoption. A workspace groups single-repo projects; this command lets the operator normalize all members' tracking from the workspace root instead of running `/adopt-roadmap` per repo. It never rewrites tracking files itself — it detects what needs adoption and delegates each member to `claude-roadmap-tools`'s `/adopt-roadmap`, which owns the transformation.

## Interaction mode (read once)

You are **non-interactive** if `$ARGUMENTS` contains `--yes` / `-y`, or `$ATELIER_AUTO` is set (probe with `env | grep -E '^ATELIER_AUTO='`). Otherwise **interactive**. Adoption is a judgment-heavy content rewrite, so in non-interactive mode **do not run `/adopt-roadmap`** — only print the per-member recommendations and stop.

## Step 1 — resolve the workspace and its members

Run the read-only status helper (it resolves the slug from `$ARGUMENTS`, or from cwd when omitted):

```bash
atelier-workspace-status <slug> --json
```

- Exit `2` → could not resolve a workspace. Tell the operator to pass a slug or `cd` to a workspace root / member, and stop.
- Exit `0` → parse the JSON. Each `members[]` entry carries `token`, `path`, `status`, `inProgress`, and **`roadmapFormat`** (`conforming` | `non-conforming` | `absent`).

Skip any member whose `status` is not `configured` (surface it as needing `/atelier:setup-project` first).

## Step 2 — classify each member

For every configured member, decide what (if anything) it needs:

1. **ROADMAP not §5** — `roadmapFormat == "non-conforming"` (foreign / High-Med-Low layout) or `"absent"`. Its tasks are **not claimable** by `task-discovery` / `/atelier:next-task`. Needs `/adopt-roadmap --format atelier`. (For `absent`, the member likely needs `/atelier:setup-project` instead — flag it, do not adopt a non-existent file.)
2. **Legacy `IN_PROGRESS.md`** — even when `roadmapFormat == "conforming"`: `Read` the member's `IN_PROGRESS.md` and classify as in `/atelier:setup-project` Phase 3a (a legit single active task vs a multi-item / multi-`##` legacy tracker). A legacy tracker needs `/adopt-roadmap` (no `--format` flag needed — its ROADMAP is already §5).
3. **Already clean** — `conforming` ROADMAP + single-slot (or empty) `IN_PROGRESS.md`. Nothing to do.

## Step 3 — present the plan and confirm

Print one line per member: token · path · what it needs (`adopt → §5`, `reset IN_PROGRESS`, `setup-project first`, or `ok`). Then:

- **Interactive:** `AskUserQuestion` — proceed to adopt the flagged members now? (proceed / skip). Let the operator deselect members.
- **Non-interactive:** print the plan and the exact per-member command, then stop. Do not run anything.

## Step 4 — adopt each flagged member (interactive, on approval)

Process members **one at a time**. For each:

1. `cd <member path>` (so `/adopt-roadmap` operates on that repo — it runs at the repo root, on cwd).
2. Invoke `/adopt-roadmap` — with `--format atelier` for the non-§5 case, or bare for the legacy-`IN_PROGRESS`-but-already-§5 case. Let `/adopt-roadmap` run its own interactive plan + confirmation; do not pre-empt it.
3. If `claude-roadmap-tools` is not installed (the command does not resolve), stop and point the operator at `claude plugin install claude-roadmap-tools@akalab-tech` — do not attempt the transformation manually.

Never edit a member's `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` yourself — `/adopt-roadmap` is the sole writer.

## Step 5 — report and next steps

Summarize per member: adopted / reset / skipped / needs-setup. Then remind the operator of the steps this command deliberately does **not** do (they are per-member and judgment- or push-bearing):

- **Fill placeholders** — after `--format atelier`, each adopted ROADMAP has `` `TODO-type` `` / `` `~TODO` `` placeholders to fill in.
- **Commit to base** — `/adopt-roadmap` rewrote each member's **working** tracking files. Because `/atelier:next-task` reads the ROADMAP from `origin/<base>` and the decision broker reads `.atelier.json` from the per-task worktree, each member's adopted files must be **committed and merged to its base branch** before tasks become claimable. Open one PR per member (normal `pr-flow`).
- **Plan tasks** — `/atelier:plan-task <id>` per task to mark it `[ready]`.
- Then claim work from the workspace root with `task` (the member picker) or `/atelier:next-task`.

## Hard refusals

- **Never** rewrite a member's tracking files inline — only `/adopt-roadmap` writes them.
- **Never** run `/adopt-roadmap` in non-interactive mode — adoption is judgment-heavy; print recommendations and stop.
- **Never** push or open PRs from this command — the operator reviews each adoption and ships it via the normal PR flow.
- **Never** adopt a member that is not `configured` — flag it for `/atelier:setup-project` first.
