---
name: decision-broker
description: Resolve a STRATEGIC decision for an atelier task — a situation where multiple legitimate options exist and one must be chosen. Use this skill whenever a specialist agent (`task-orchestrator`, `pr-author`, `unblocker`, etc.) is about to ask the operator a question with options like "fix-first / override / abort", whenever the catalog has an entry for the situation, or whenever an agent says "we have a choice to make about <X>". The skill reads `.atelier.json`'s `decisionPolicy`, the catalog at `agents/decision-broker/catalog.json`, and the panic flag at `<worktree>/.atelier-abort-auto.flag`, then either returns the chosen option directly (when the operator has set a fixed answer), dispatches to the right risk-level broker agent (when policy is `auto`), or instructs the caller to ask the operator (when policy is `ask` or the panic flag is set). Logs every decision to `<worktree>/.task-log/decisions.jsonl`. Triggers on phrases like "should we", "options are", "the operator will need to choose", or any AskUserQuestion that would surface a multi-option strategic call.
---

# decision-broker

The skill that turns "the agent should ask the operator about X" into "the agent decides X autonomously, OR asks the operator with full context, OR uses the operator's prescribed answer — whichever the project's policy says".

This skill is the **only** entry point an agent should use for strategic decisions. The static permission matrix is the safety net for what is FORBIDDEN; the safety hooks are the safety net for what is UNSAFE; this skill is the policy layer for what is AMBIGUOUS.

## What this skill produces

A single structured result the caller acts on:

```text
mode:         direct | auto | ask | panic
category:     <catalog category id>
choice:       <option.id> | null (only when mode=ask)
rationale:    <human prose, always present>
confidence:   high | medium | low | null (only when mode=direct or mode=ask)
model:        haiku | sonnet | opus | null (only when mode=auto)
logged_to:    <worktree>/.task-log/decisions.jsonl
```

The caller dispatches:

- `mode: direct` — the policy was a fixed option id (e.g. `"baseline-conflict": "fix-first"`). The skill returned that. Carry it out.
- `mode: auto` — the broker agent picked. Carry out `choice` and surface `rationale` to the operator via the PR body.
- `mode: ask` — fall back to `AskUserQuestion` with the catalog's options and the broker's framing.
- `mode: panic` — the operator hit `/atelier:abort-auto` mid-session. Behave as `mode: ask` until the flag clears.

## Inputs the caller MUST provide

The calling agent invokes this skill with a structured briefing:

```text
category:     <catalog category id, e.g. "baseline-conflict">
context:      <200–500 tokens of relevant task state: task id + title,
              branch, specific symptom that triggered the decision,
              failing output or diff snippet if applicable>
worktree:     <absolute path to the task worktree>
project_root: <absolute path to project root, for reading .atelier.json
              and accessing the operator's policy>
```

If the caller cannot fill any of these, it must `AskUserQuestion` the operator directly without invoking the skill — the skill is not a substitute for missing context.

## Resolution algorithm

The skill resolves in this order; the first hit wins:

### Step 1 — Panic flag

Read `<worktree>/.atelier-abort-auto.flag`. If the file exists (any contents), return:

```text
mode:       panic
category:   <as-provided>
choice:     null
rationale:  "Operator activated /atelier:abort-auto for this session — all auto decisions are deferred to the operator until the flag is cleared."
```

The skill stops. The caller falls back to `AskUserQuestion`.

### Step 2 — Catalog lookup

Read `agents/decision-broker/catalog.json` (resolved from `$CLAUDE_PLUGIN_ROOT/agents/decision-broker/catalog.json`). Find the entry for `category`. If the category is not catalogued, return:

```text
mode:       ask
category:   <as-provided>
choice:     null
rationale:  "Category '<id>' is not in the atelier catalog yet. Falling back to operator decision. After this PR ships, surface this category to the maintainer so it can be added."
```

The caller falls back to `AskUserQuestion`. Surface the missing category prominently — it is a signal atelier's catalog needs to grow.

### Step 2.5 — Read per-invocation flag overrides

Before reading the project policy, check two env vars set by the `task` shell wrapper when the operator passed `--policy` or `--ask-for`:

- **`ATELIER_POLICY_OVERRIDE`** — if set to `"auto"` or `"ask"`, this value REPLACES `decisionPolicy.default` for THIS invocation. The catalogued category's per-category entry in `.atelier.json` (Step 3 below) is still honored — only the default changes. Conceptually the operator is saying *"for this task, use auto/ask globally unless I've already configured a specific category."*
- **`ATELIER_ASK_FOR`** — if set to a comma-separated list of category ids (e.g. `oversize-handling,scope-creep-detected`), every category in the list is treated as `"ask"` regardless of what `.atelier.json` says. Other categories are unaffected. This is the surgical "I want to be asked about these specific cases" override.

Both env vars are empty strings when the operator did not pass the flags — treat empty as "not set". The `task` wrapper sets the env vars unconditionally with empty values so the resolution does not have to test for unset.

If `ATELIER_ASK_FOR` contains the current `category`, return `mode: ask` immediately with rationale: *"Operator passed `--ask-for=<list>` which includes this category."*

`ATELIER_POLICY_OVERRIDE` only takes effect after Step 3 has consulted `.atelier.json` and found NO `byCategory.<category>` entry — see the precedence note at the end of Step 3.

### Step 3 — Read project policy

Read `<project_root>/.atelier.json`. Locate `decisionPolicy.<category>`. Three possible shapes:

- **Fixed option id** (e.g. `"fix-first"`) → `mode: direct`. Verify the id is in the catalog entry's `options[]`. If not, return `mode: ask` with a warning rationale ("Project policy specifies '<id>' but catalog does not list it as an option — falling back to operator"). **Note**: a fixed value here is NOT overridden by `ATELIER_POLICY_OVERRIDE` — the operator already configured a specific answer for this category, the wrapper flag is global, specific beats global.
- **`"auto"`** → continue to Step 4.
- **`"ask"`** → return `mode: ask`. Caller falls back to `AskUserQuestion`.
- **Missing** → check `ATELIER_POLICY_OVERRIDE` first. If set to `"auto"` → continue to Step 4 (as if the per-category value were `"auto"`). If set to `"ask"` → return `mode: ask`. If unset, check `decisionPolicy.default`. If that is also missing, treat as `"ask"`. This is the conservative fallback for projects that haven't run the setup-project policy step.

Precedence summary, highest to lowest:

1. Panic flag (Step 1).
2. `ATELIER_ASK_FOR` mentions the category (Step 2.5).
3. `decisionPolicy.byCategory.<category>` in `.atelier.json` (this step).
4. `ATELIER_POLICY_OVERRIDE` (this step, when byCategory missing).
5. `decisionPolicy.default` in `.atelier.json`.
6. Conservative fallback: `ask`.

### Step 4 — Dispatch to the right broker agent

The catalog entry's `riskLevel` selects the agent:

- `low` → `decision-broker-low-risk` (Haiku 4.5)
- `medium` → `decision-broker-medium-risk` (Sonnet 4.6)
- `high` → `decision-broker-high-risk` (Opus 4.8)

Hand off the catalog entry and the caller's `context` block via the `Task` tool, with the agent's `subagent_type` set to the chosen broker. The agent returns the JSON shape documented in its own prompt.

### Step 5 — Log

After resolution, append to `<worktree>/.task-log/decisions.jsonl` (one JSON object per line):

```json
{
  "ts": "<ISO 8601>",
  "category": "<id>",
  "mode": "<direct|auto|ask|panic>",
  "choice": "<option.id or null>",
  "rationale": "<prose>",
  "confidence": "<high|medium|low or null>",
  "model": "<haiku|sonnet|opus or null>",
  "source": "<policy:fixed | policy:auto | policy:ask | policy:missing | panic | catalog:missing>",
  "duration_ms": <int>,
  "cost_usd_estimate": <float>
}
```

The `pr-author` agent reads this file when composing the PR body — see the "Autonomous decisions taken" section there.

## Hard refusals

- **Never act on the chosen option.** The skill returns the choice; the caller carries it out. Crossing that line collapses the broker's auditability.
- **Never invent options.** The choice must come from the catalog entry's `options[]`. If the broker agent returns something else, log it as an error and fall back to `mode: ask`.
- **Never read or modify the operator's `.atelier.json` other than the `decisionPolicy` section.** Stay narrowly scoped to your contract.
- **Never recurse.** If a broker agent's reasoning itself needs a strategic decision, it falls back to `choice: "ask"` — the skill does not call itself.

## How to invoke

A specialist that was about to `AskUserQuestion` for a strategic call invokes this skill instead. Conceptually:

```text
1. Build the briefing (category + context + worktree + project_root).
2. Invoke the decision-broker skill with the briefing.
3. Switch on the returned mode:
   - direct or auto → carry out `choice`, log it.
   - ask or panic   → AskUserQuestion the operator with the catalog's
                      options and the skill's rationale as preamble.
4. After acting, append the actual outcome to the .task-log/decisions.jsonl
   record (e.g. "operator accepted | operator overrode → fix-first").
```

The pre-existing `AskUserQuestion` flow stays intact — the broker just intercepts the cases the catalog covers.

## Where this skill is wired in

Specialists that integrate the broker in v0.9.0:

- `task-orchestrator` — `baseline-conflict`, `oversize-handling`, `scope-creep-detected`.
- `pr-author` — `oversize-handling` (last-chance check), `merge-conflict-tracking` (during the same-PR IN_PROGRESS → HISTORY move).
- `unblocker` — `merge-conflict-substantive` (during hard-stop rebase attempts).

Other specialists invoke the broker organically when they encounter a catalogued category.
