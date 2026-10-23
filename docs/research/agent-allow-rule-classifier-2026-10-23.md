# Does an `Agent(...)` allow rule skip the auto-mode classifier? (#590)

Date: 2026-10-23. Claude Code 2.1.309 (`claude -p`, Opus 5.5 main loop, Sonnet 5 classifier, direct Anthropic API).
Question (#590, related #457): can `permissions.allow` entries for `atelier:task-orchestrator` and `atelier:planner` stop the auto-mode classifier from denying those dispatches with `[Auto-Mode Bypass]`?

**Gate 1 (auto mode) result: FAIL.** The rule syntax works, but in auto mode the rule does not take the dispatch out of the classifier. Plan amendment 1 then moved each project to a single session without auto mode (`defaultMode: acceptEdits`); **gate 2 (below) passes**, so the template change ships for that configuration.

## Method

Scratch project (empty git repo, no `.atelier.json`), atelier loaded with `--plugin-dir <worktree>` so agents are namespaced `atelier:*`. Rules were injected with `--settings <file>` (flag scope). Project-scoped `permissions.allow` entries are dropped in an untrusted workspace under `-p` (debug line `Dropped 1 project-scoped permissions.allow entry - workspace not yet trusted`), so two early runs (B1, B2) were discarded as confounded.

Observable for "did the classifier run on this call": the `--debug-file` line `[auto-mode] new action being classified: tool=Agent` (plus `classifier_request_started ... tool=Agent`). The prompt was a `/atelier:plan-task`-shaped brief: dispatch `atelier:planner` with facts only (task id, title, plan path), stop after it returns.

## Results

| # | Claim | Status | Evidence |
|---|-------|--------|----------|
| a1 | `Agent(<type>)` is the current rule spelling; a deny rule `Agent(atelier:planner)` blocks the dispatch | verified (2.1.309) | Tool result: `Agent type 'atelier:planner' has been denied by permission rule 'Agent(atelier:planner)' from projectSettings.` Docs (permissions.md, "Agent (subagents)") document `Agent(AgentName)`. |
| a2 | `Task(...)` is an accepted alias of `Agent(...)` | verified | Deny `Task(atelier:planner)` blocked the dispatch; the message cites the normalized `Agent(atelier:planner)` rule. |
| a3 | Plugin agents match by namespaced name only | verified | Deny `Agent(planner)` (bare) did NOT block `atelier:planner` (the planner ran). A bare-name rule is a no-op for plugin agents. |
| a4 | `Agent(atelier:*)` wildcard on the agent name | verified: not matched | Deny `Agent(atelier:*)` did not block the dispatch. The wildcard form documented applies to parameters (`Agent(model:*)`), not names. |
| a5 | Rule is parsed and enforced from flag scope | verified | Deny via `--settings` in auto mode removed `atelier:planner` from the available agent types (run S1). |
| b1 | An allow rule for the exact agent is dropped or ignored by auto mode | verified (behaviour), docs confirm | Docs (permission-modes.md): "On entering auto mode, broad allow rules ... are dropped: ... `Agent` allow rules." |
| b2 | With `Agent(atelier:planner)` allowed, the dispatch still goes to the classifier | verified, n=3 (+1 variant) | Runs B3, B4, B5: each shows `[auto-mode] new action being classified: tool=Agent` and a classifier request (about 2.2 s). Run T1 with `Task(atelier:planner)` and `Agent(atelier:task-orchestrator)` allowed: classified as well. |
| b3 | Baseline (no rule) also reaches the classifier | verified, n=3 | Runs A1, A2, A3: identical classifier line. |
| b4 | Allow rule changes the classifier's verdict | not testable here | All 7 samples (3 baseline, 4 with rule) were allowed. The brief was benign, and the #457 denials are intermittent, so a denial-rate comparison would need many more samples than a go/no-go gate justifies. Not needed: the rule does not bypass the classifier, which decides the gate. |
| b5 | Positive control (a narrow `Bash(...)` allow skips the classifier) | inconclusive | Bash probes (`echo`, `curl -sI`, `git config`) were never classified even without a rule, so they could not discriminate. Recorded for honesty; the Agent result above stands on the docs statement plus 4 allow-arm samples. |
| c | How this squares with operator-rules' "allow-rules short-circuit the classifier" claim | inferred | The claim is true for narrow Bash rules (docs: step 1 of the decision order), but `Agent` allow rules are on the documented drop list, so the claim does not extend to subagent dispatch. Same shape as the `[Self-Approval]` exception (#38): a matching rule does not remove the classifier from the path. Not run live, since it needs a real PR authored by `pr-author`. |

## Gate 2: `defaultMode: acceptEdits` (plan amendment 1)

Same setup as gate 1 (scratch project, `claude -p`, `--plugin-dir <worktree>`, rules via `--settings`), with `--permission-mode acceptEdits` and `"defaultMode": "acceptEdits"` in the settings file. Same `/atelier:plan-task`-shaped brief dispatching `atelier:planner`. Arm A: `allow: ["Agent(atelier:planner)", "Agent(atelier:task-orchestrator)"]`. Arm B: no Agent rules. Runs GA1 to GA3, GB1 to GB3. Under `-p` a permission prompt cannot be answered, so a prompt would surface as an `Agent` entry in `permission_denials`.

| Arm | n | `[auto-mode] ... classified` lines | classifier requests | `Agent` entries in `permission_denials` | dispatch outcome | permission decision (`permissionDecisionMs`) |
|-----|---|------|------|------|------|------|
| A (rules) | 3 | 0, 0, 0 | 0, 0, 0 | 0, 0, 0 | planner ran in 3/3 | 2, 1, 0 ms |
| B (no rules) | 3 | 0, 0, 0 | 0, 0, 0 | 0, 0, 0 | planner ran in 3/3 | 1, 1, 1 ms |

| # | Claim | Status | Evidence |
|---|-------|--------|----------|
| d1 | In `acceptEdits`, an `Agent(atelier:planner)` dispatch is not evaluated by the auto-mode classifier (rules present) | verified (2.1.309), n=3 | No `new action being classified: tool=Agent` and no `classifier_request_started` in any arm-A debug log; `tool=Agent ... permissionDecisionMs` of 0 to 2 ms. |
| d2 | No permission prompt appears for the dispatch with the rules present | verified (2.1.309), n=3 | No `Agent`/`Task` entry in `permission_denials`; the planner ran and returned. (The inner planner's own `Bash` calls show denials in every arm, under `-p`; those are unrelated to the dispatch and identical in both arms.) |
| d3 | Arm B (no rules) behaves the same in `acceptEdits` | verified (2.1.309), n=3 | Identical result: not classified, no prompt. So in `acceptEdits` the rule is not what removes the classifier or the prompt; it makes the pre-authorization explicit and independent of the default mode's Agent handling. |
| d4 | `Agent(atelier:task-orchestrator)` allow in `acceptEdits` | inferred | Only `atelier:planner` was dispatched live; the rule shape is identical (syntax verified in a1 to a5) and the mode behaviour is not agent-specific. |
| d5 | Behaviour in auto mode | verified (gate 1) | Still classified; `Agent` allow rules are dropped on entering auto mode (b1, b2). |

## Consequences

- Gate 1 alone would have blocked the change; with gate 2 passing, `templates/settings.template.json` gets exactly `Agent(atelier:task-orchestrator)` and `Agent(atelier:planner)`, described in `scripts/atelier-permission-diff` and recorded in `PLAN.md` §3, `operator-rules.md` and `docs/troubleshooting.md`.
- In auto mode a dispatch denial (`[Auto-Mode Bypass]`) stays a terminal held state (#457 flow), as today.
- Also note (docs): "Before a subagent starts, the delegated task description is evaluated" by the classifier, which is a different check than the permission rule, so even a surviving rule would not cover it.
- If a later Claude Code release stops dropping `Agent` allow rules in auto mode, re-run runs B3 to B5 (debug line `[auto-mode] new action being classified: tool=Agent` absent means the rule works). Only then reopen #590 with the spelling established here: namespaced, exact, `Agent(atelier:planner)` and `Agent(atelier:task-orchestrator)`.
