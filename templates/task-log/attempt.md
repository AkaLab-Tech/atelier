<!--
  Per-attempt failure log template (PLAN.md §8).

  Written by the `retry-with-logs` skill (invoked from `task-orchestrator`)
  every time a specialist agent attempt fails. One file per attempt, stored
  at `<worktree>/.task-log/<ISO-timestamp>-<NN>.md` where `<NN>` is the
  attempt number (01..06) zero-padded so the directory listing sorts
  naturally.

  Subsequent attempts MUST read prior logs (oldest → newest) before
  retrying, so the *new* attempt has the full history of what was tried,
  what failed, and what the prior attempts concluded. Keep each section
  terse — these get injected verbatim into the next attempt's context.

  Delete this top comment when filling the file in; everything below the
  `---` separator is the actual log payload.
-->

---

# Attempt <NN> — <ISO-timestamp UTC>

**Specialist:** `<implementer | tester | e2e-runner | pr-author | reviewer>`
**Phase reset before this attempt:** <yes | no>   <!-- yes only on attempts 04..06 -->
**Branch / worktree:** `<branch>` at `<worktree-abs-path>`

## Initial hypothesis

<One paragraph. What does the specialist believe is the problem before starting
this attempt? On attempt 01 this is the task itself ("implement M4.1 retry
logic"). On attempts 02..06 this is what changed since the prior failure
("attempt 01 missed that the regex needs a lookahead — try a positive
lookahead now").>

## Actions taken

<Bullet list. The concrete commands run, files edited, agents delegated to,
tests executed. Each bullet is one verifiable action. Avoid prose.>

- ...
- ...
- ...

## Final error

<The literal failing output: test name + assertion, lint rule + line, type
error, CI step that broke, reviewer verdict + the one finding that tripped
auto-merge. Quote the relevant 5–20 lines verbatim — do not paraphrase. If
the failure is an exception, include the stack frame that matters.>

```
<paste error output here>
```

## Reasoning on what went wrong

<One paragraph. The specialist's *post-mortem* of this attempt. Two parts:
(a) why the initial hypothesis was wrong (or right but insufficient), and
(b) what the next attempt should try differently. Be concrete: "try X
because Y" — never "investigate further".>

## Next attempt should

<One bullet per concrete instruction for the next attempt. The retry loop
reads these as the seed of the next attempt's hypothesis. Empty this
section only on attempt 06 (hard stop — no next attempt).>

- ...
- ...
