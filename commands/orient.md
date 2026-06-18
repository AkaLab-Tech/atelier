---
description: Orient the operator at the start of a session — present the single, prioritized "what to do next" for the current directory, derived from its real state (not-configured / multi-repo / inconsistent / open PRs / in-progress / next task to take or plan). Read-only detection; it suggests (and offers to run) the next step, it does not act on its own.
argument-hint: "[<dir>]"
allowed-tools: Bash(atelier-orient:*), SlashCommand, AskUserQuestion, Read
---

You are running `/atelier:orient` — the session orientation. The bare `atelier`
entry point opens with this as its first message; the operator can also run it
any time. Goal: lead with **one** prioritized next step for the target directory,
then offer to do it. Never dump a wall of status.

## Interaction mode (read once)

**Non-interactive** if `$ARGUMENTS` contains `--yes` / `-y`, or `$ATELIER_AUTO` is
set (probe `env | grep -E '^ATELIER_AUTO='`). Otherwise **interactive**. In
non-interactive mode: print the orientation and stop — **never auto-run** the
suggested action (claiming/merging/adopting are operator gates).

## Step 1 — cheap local orientation

Target dir = the first non-flag token in `$ARGUMENTS`, else the cwd. Run:

```bash
atelier-orient "<dir>"
```

This is the fast, offline signal (filesystem only): workspace-root /
multi-repo-parent / not-a-repo / not-configured / partial / in-progress /
ROADMAP layout (§5 → next-task|plan-task · foreign → adopt · High/Med/Low →
manual) + secondary notes (version drift, workspace membership). Its headline is
your **baseline** recommendation.

## Step 2 — layer the remote / PR picture

The cheap helper cannot see open PRs or remote in-progress. **Only when the dir
is a configured project** (not the not-configured / multi-repo / not-a-repo
cases — for those, Step 1's answer already stands), enrich it by running
[`/atelier:status`](status.md) for this project (open `task/*` PRs, in-progress,
blocked, awaiting-review). Reuse it — do not re-implement the `gh` queries here.

## Step 3 — reconcile into one headline

Pick the single highest-priority next step (first match):

1. **Setup / config blockers** (from Step 1): not-a-repo → `git init`;
   multi-repo parent → `/atelier:setup-workspace --discover .`; not-configured /
   partial → `/atelier:setup-project`. *(Nothing else is workable until fixed.)*
2. **A `foreign` ROADMAP** → `/adopt-roadmap --format atelier` (or
   `/atelier:onboard-workspace <slug>` for a member). High/Med/Low → no §5 nag.
3. **An open `task/*` PR needing action** (from Step 2): `request-changes` →
   address it; approved + mergeable → merge (`/atelier:auto-merge`); awaiting
   review → `reviewer`. *(Close out shipped work before claiming new work.)*
4. **A task in progress** → `/atelier:resume-task`.
5. **A `[ready]` task** → `/atelier:next-task` (name it).
6. **Backlog but nothing `[ready]`** → `/atelier:plan-task <id>` (a short ranked
   shortlist of candidates).
7. **Empty backlog** → suggest writing a task / nothing to do.

For a **workspace root**, the headline is the board + router:
`atelier-workspace-status <slug>` and `task` (member picker), plus a one-line
roll-up of which members need onboarding / have work in progress.

## Step 4 — present + offer

- Lead with the **one** headline (the action + the exact command). Add at most a
  short "also:" line for secondary items (drift, other PRs). Keep it tight.
- **Interactive:** offer to run it now via `AskUserQuestion` (do it / not now).
  If yes, dispatch the corresponding command. Respect every downstream gate
  (planning approval, auto-merge guardrails) — orient does not bypass them.
- **Non-interactive:** print the headline + command and stop.

## Hard rules

- **Read-only detection.** The only writes are those of a command the operator
  approves (`/adopt-roadmap`, `/atelier:next-task`, …). Orient itself changes nothing.
- **One headline.** Surface the single most important next step; reveal the rest
  only if asked. Never print a full status dump.
- **Never auto-act in non-interactive mode.** Claiming, merging, adopting, and
  planning approval are operator gates.
- **Reuse, don't reimplement.** Cheap signals come from `atelier-orient`; remote
  signals from `/atelier:status`. Do not duplicate their logic here.
