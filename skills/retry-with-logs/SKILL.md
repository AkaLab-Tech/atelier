---
name: retry-with-logs
description: >-
  Materialize the fixed retry budget from PLAN.md §8 (3 attempts → reset
  worktree → 3 more attempts → hard stop) and persist a structured failure
  log for every attempt at `<worktree>/.task-log/<ISO-timestamp>-<NN>.md`.
  ALWAYS load this skill when a specialist agent (`implementer`, `tester`,
  `e2e-runner`, `pr-author`, `reviewer`) returns a failure to
  `task-orchestrator`, when the operator says "retry", "try again",
  "what went wrong last time?", or when the orchestrator needs to decide
  between *retry inside this worktree*, *reset the worktree and retry*,
  and *hard stop / escalate to `unblocker`*. The skill counts existing
  logs, writes the next attempt log from the template at
  `templates/task-log/attempt.md`, returns the structured next-action
  decision, and refuses to extend the budget past 6 total attempts.
  Trigger even when the operator does not say "retry-with-logs"
  explicitly — any phrasing about a failed specialist attempt belongs
  here.
---

# retry-with-logs

The executable form of [PLAN.md §8](PLAN.md)'s failure-recovery policy. The
specialist agents (`implementer`, `tester`, `e2e-runner`, `pr-author`,
`reviewer`) decide whether *their* attempt produced a working artifact;
this skill decides whether **another attempt is allowed at all**, and if
so, whether the worktree needs to be reset first. Two separate decisions.

The budget is **hard-coded**: 3 attempts → reset → 3 attempts → hard stop.
The orchestrator MUST NOT extend it silently. The skill refuses to issue
a `continue` or `reset` decision past the 6th attempt — at that point the
only valid next action is `hard-stop`, which hands off to the `unblocker`
agent.

## Preconditions

- The caller (`task-orchestrator` or a specialist via the orchestrator)
  has the absolute path of the task's worktree. The skill writes inside
  `<worktree>/.task-log/`.
- `templates/task-log/attempt.md` exists at the plugin root — the skill
  reads the template via `$CLAUDE_PLUGIN_ROOT/templates/task-log/attempt.md`.
- The failing specialist's structured output (the verbatim error, what
  it tried, what it concluded) is available — without it, the log is
  worthless and the skill refuses to write a placeholder.

If any precondition is missing, **stop and report** — do not write a half-
empty log file.

## The budget, restated

| Attempts | What runs | What happens on failure |
| --- | --- | --- |
| **01, 02, 03** | The specialist retries inside the *same* worktree, with all prior `.task-log/*.md` injected as context. | Write attempt log, return `continue`. After attempt 03 fails, the next decision is `reset`. |
| **(between 03 and 04)** | `git wt rm <branch> --force` (after operator confirmation if the worktree is dirty), then `git wt switch <branch>` to recreate from updated base. Logs survive — they live in `.task-log/`, which is **not** wiped, see below. | N/A — this is a state transition, not an attempt. |
| **04, 05, 06** | Same specialist retries inside the *fresh* worktree, still seeded with **all** logs (01..03 from the pre-reset attempts + the new ones). | Write attempt log, return `continue`. After attempt 06 fails, the only valid next decision is `hard-stop`. |
| **07+** | **Forbidden.** The skill refuses to issue any `continue` or `reset` past attempt 06. | Return `hard-stop` and hand off to `unblocker`. |

### Why logs survive a reset

The `.task-log/` directory must outlive the worktree reset, otherwise
attempts 04..06 cannot read what went wrong in attempts 01..03 and the
retry loop loses memory. Two mechanisms are acceptable, in order of
preference:

1. **Copy out, copy back.** Before `git wt rm`, copy `.task-log/` to a
   temporary location (`/tmp/atelier-task-log-<task-id>/`). After
   `git wt switch` recreates the worktree, copy it back into the new
   worktree. This is the default — it works for any project layout.
2. **Commit the logs to the branch.** If the project layout allows it
   (e.g., `.task-log/` is gitignored at the project root but the branch
   tip already has them committed, which is rare), `git wt rm` will not
   delete them because they live on the branch. This is *not* the
   default — most projects gitignore `.task-log/`.

The skill uses option 1 unless the orchestrator explicitly says otherwise.

## How to run

**Invariant — read this once and hold it:** the skill is invoked **after a
specialist attempt has already failed**. The orchestrator hands you the
failure. The just-failed attempt is the one whose log you are about to
write (Step 3). The pre-existing files in `.task-log/` are logs of the
attempts that failed *before* this one — they do not yet include the
just-failed attempt.

Apply the steps in order. Stop and report at the first failure.

### Step 1 — Count existing logs

```bash
ls -1 "<worktree>/.task-log/" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}-[0-9]{2}\.md$' | wc -l
```

Let `count` be the number returned and `N = count + 1` be the
**just-failed attempt number** (i.e., the attempt whose log Step 3
will write). N is in `1..6` for a healthy task; `N > 6` means an
earlier attempt should already have triggered `hard-stop`.

Sanity-check:

- If `N > 6` (i.e., 6 or more logs are already on disk), **refuse** —
  return `hard-stop` immediately, do not write another log. The
  orchestrator must hand off to `unblocker`.
- If `N == 1` and the failing specialist's first invocation has already
  completed (i.e., this is genuinely a *failure*, not a fresh task),
  proceed. If `N == 1` and the specialist has not even started yet, the
  skill should not have been invoked — return `not-applicable`.

### Step 2 — Build the filename

```text
<worktree>/.task-log/<YYYY-MM-DDTHHMMSS>-<NN>.md
```

- `<YYYY-MM-DDTHHMMSS>` is the current UTC time, formatted to be
  filesystem-safe and lexicographically sortable. Compute with
  `date -u +"%Y-%m-%dT%H%M%S"`.
- `<NN>` is the attempt number from Step 1, zero-padded to 2 digits
  (`01`..`06`).

Example: `.task-log/2026-05-19T143012-04.md` is attempt 04 (i.e., the
first attempt *after* the worktree reset), captured on 2026-05-19 at
14:30:12 UTC.

### Step 3 — Write the log

```bash
mkdir -p "<worktree>/.task-log"
cp "$CLAUDE_PLUGIN_ROOT/templates/task-log/attempt.md" "<filename>"
```

Then fill in the template's placeholders. The five sections from
`templates/task-log/attempt.md` are mandatory; an empty section is
worse than no log — the next attempt has no signal to act on. Source
the content from the failing specialist's structured output:

| Template section | Source |
| --- | --- |
| `Specialist` | The agent name returned by `Task` (e.g., `implementer`). |
| `Phase reset before this attempt` | `no` for attempts 01..03, `yes` for 04..06 (the orchestrator knows). |
| `Branch / worktree` | The worktree path captured at task start. |
| `Initial hypothesis` | The specialist's plan at the start of *this* attempt. For attempts 02..06, that plan was informed by prior logs; quote which prior log conclusion shaped it. |
| `Actions taken` | The specialist's actual actions (file edits, commands, sub-agent invocations). |
| `Final error` | The verbatim 5–20 lines of the failure output. **Never paraphrase.** |
| `Reasoning on what went wrong` | The specialist's post-mortem (why the hypothesis was insufficient + what to try next). |
| `Next attempt should` | Concrete bullets. Empty only when this is attempt 06 (no next attempt). |

If the specialist returned an unstructured failure (just "it crashed"),
the orchestrator MUST re-invoke the specialist with a fresh `Task` call
and an explicit "return a structured failure" instruction, then write
the log from *that* output. Skipping this step produces a log the next
attempt cannot use.

### Step 4 — Compute the next-action decision

`N` is the **just-failed attempt** (from Step 1). The decision answers:
*given that attempt N just failed, what happens next?* The table is the
single source of truth — if any other phrasing in this document seems
to disagree, this table wins.

```text
Just-failed attempt N == 1 → continue   (next: attempt 02 in same worktree)
Just-failed attempt N == 2 → continue   (next: attempt 03 in same worktree)
Just-failed attempt N == 3 → reset      (then: attempt 04 in fresh worktree)
Just-failed attempt N == 4 → continue   (next: attempt 05 in fresh worktree)
Just-failed attempt N == 5 → continue   (next: attempt 06 in fresh worktree)
Just-failed attempt N == 6 → hard-stop  (no further attempt allowed)
Just-failed attempt N >= 7 → impossible (Step 1 already refused)
```

Worked examples to lock the semantics:

| `count` of files in `.task-log/` | `N = count + 1` (just-failed) | Decision |
| --- | --- | --- |
| 0 | 1 | `continue` |
| 1 | 2 | `continue` |
| 2 | 3 | `reset` |
| 3 | 4 | `continue` |
| 4 | 5 | `continue` |
| 5 | 6 | `hard-stop` |
| 6 or more | 7+ | `hard-stop` (refused at Step 1) |

### Step 5 — Report

Return the structured output below. The orchestrator consumes it
verbatim; downstream consumers (the eventual `unblocker` agent, the
operator) read this report rather than parsing the raw filesystem.

## Structured output

```text
== retry-with-logs report ==

Task worktree:  <abs-path>
Attempt:        <NN> / 06
Log written:    <relative-path-from-worktree>
Logs to date:   <count> file(s)
                <oldest-relative-path>
                ...
                <newest-relative-path>

Failing specialist:  <implementer | tester | e2e-runner | pr-author | reviewer>
Failure summary:     <one-line; the orchestrator can read the log for detail>

Decision: continue | reset | hard-stop

<if continue>
Next step:  re-invoke <specialist> with all .task-log/*.md as context.
            The new attempt is number <NN+1> / 06.
</if>

<if reset>
Next step:  preserve .task-log/ outside the worktree (copy to
            /tmp/atelier-task-log-<branch>/), then
            `git wt rm <branch> --force` and `git wt switch <branch>` to
            recreate from updated base. Restore .task-log/. Then re-invoke
            <specialist>. The new attempt is number 04 / 06.
</if>

<if hard-stop>
Next step:  hand off to the `unblocker` agent. Do NOT retry. Do NOT
            extend the budget.
</if>
```

## Hard refusals

- **Never** silently extend the budget past 6 attempts. If the orchestrator
  re-invokes the skill after a `hard-stop`, the skill returns `hard-stop`
  again, with the same log list.
- **Never** write a log with empty mandatory sections. An unusable log is
  worse than no log — it pollutes the next attempt's context.
- **Never** delete or rewrite a prior `.task-log/*.md` file. Each attempt
  is an immutable record.
- **Never** name a log file with a non-UTC timestamp. Reset-and-retry
  spans days/timezones; UTC is the only safe choice.
- **Never** skip the reset between attempts 03 and 04. The reset is the
  whole point of the 6-attempt budget being split 3+3 — without it,
  attempts 04..06 are just three more `continue`s and the policy is
  meaningless.
- **Never** force-remove a dirty worktree at reset without operator
  confirmation. The dirty state is itself a signal that something
  unexpected happened mid-attempt; surface it.
- **Never** write the log under any directory other than
  `<worktree>/.task-log/`. The `unblocker` agent and `/resume-task`
  both rely on this fixed location.

## Why this skill exists

PLAN.md §8 is a one-paragraph rule that, if left to the orchestrator's
free interpretation, will drift the first time an attempt is ambiguous
("the specialist *almost* succeeded, do we count it?"). This skill
collapses the rule to a finite-state machine: count files, pick a
decision from a table, write a log. The orchestrator stops *deciding*
the retry policy and starts *executing* it. That single move is what
makes the 6-attempt budget auditable and what lets `unblocker`
trust that the log directory is a complete record.
