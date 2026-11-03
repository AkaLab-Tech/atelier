# Does auto mode refuse `Agent` dispatches whose input a plugin hook rewrites? (#688, epic #687)

Date: 2026-11-03. Claude Code 2.1.317, `claude -p --permission-mode auto`, direct Anthropic API. Main-loop model `claude-opus-5-5`, auto-mode classifier model `claude-sonnet-5[1m]` (both read from the debug file and the JSON `modelUsage`; the plan assumed a Sonnet main loop, the measured one is Opus). context-mode 1.0.169 (`~/.claude-work/plugins/cache/context-mode/context-mode/1.0.169/`), atelier loaded with `--plugin-dir` from the task worktree.

Question (#687a): the epic reports that every `Agent` dispatch is refused with "The server-side auto mode classifier gave no verdict for Agent: a hook changed this call's input after auto mode reviewed it", because context-mode's `PreToolUse` hook appends a `<context_window_protection>` block to the prompt. Which of three fixes holds: (a) atelier pre-appends the block so the hook has nothing new to add, (b) a second hook or a permission rule neutralises the hook, (c) the caller re-issues the hook-produced input once? This document only measures and decides; it changes no script, hook, setting or plugin file.

**Read the counts as a direction, not a rate.** Every cell has n=5 and the classifier is non-deterministic (method and caveats as in `docs/research/auto-mode-chain-2026-10-26.md`, whose harness is reused unchanged).

**Headline.** The refusal did **not** reproduce in any of 75 runs with a rewriting hook under `-p` (V1 20, V2 20, V3 5, V4 30): not at top level, not nested, not with the block pre-appended. Under `-p` in 2.1.317 the hook runs first and the classifier then reviews the hook-produced input, so there is nothing to mismatch. The H1/H2 split the epic wanted to read from V2 therefore cannot be made from this data (see "Final choice"). What the runs do show: the hook is not idempotent (it appends even when the block is already there), its rewrite is what puts a general `Agent` dispatch under classifier review at all (V7), and `permissionDecision: allow` removes that review (V4).

## Mechanism as measured

| Fact | Source |
|------|--------|
| context-mode registers `pretooluse.mjs` for `Agent` among many matchers | `hooks/hooks.json:64` (`"matcher": "Agent"`) |
| The `Agent` branch computes `updatedInput = { ...toolInput, [prompt]: prompt + subagentBlock }` with no check for an existing block | `hooks/core/routing.mjs:894-915` |
| The block is built by `createRoutingBlock(t, { includeCommands: false, toolSearchBootstrap: true })`; the hook answers with `hookSpecificOutput.updatedInput` and no `permissionDecision` | `hooks/core/routing.mjs:905-912`, `hooks/core/formatters.mjs:38-47` |
| No setting turns the append off; the only off switch is disabling the plugin | read of the plugin, no option found |
| Under `-p` the debug file orders: `PreToolUse:Agent ... finished`, then `[auto-mode] new action being classified: tool=Agent actionChars=N`. `N` is the post-hook size: 4,979 for the plain brief, 9,651 for a brief that already carried the block (V2(i)), 209 for the scratch hook's mark-only input (V4) | debug files, all cells |

The refusal text is in the 2.1.317 binary (`strings`). The variant for this case reads: the call "gave no verdict ... a hook changed this call's input after the model wrote it, so the review was of different input from what would run ... Issue the call again once, as this conversation records it; if it is denied again, the hook changes it each time, so do not issue it again". A second variant says: "The hook produced this input: ... In your next response, issue the call once more with exactly that input so auto mode reviews it ... If it is denied again, do not retry". Claude Code itself therefore prescribes exactly one re-issue (inferred reading of binary text, not a run). The same binary contains a speculative, server-side classifier path (`tengu_violin_speculative_classifier`, `CLAUDE_CODE_REMOTE_TOOLS_SPECULATIVE_CLASSIFIER`); setting that variable to 1 under `-p` changed nothing (one probe, no refusal, no debug mention). That path is the likely source of the production refusal and is not reachable from `-p` here (inferred).

## Harness

`claude -p --permission-mode auto --plugin-dir <worktree> --settings <file> --debug-file <log> --output-format json`, from a scratch git repo (one commit, no `.atelier.json`), `GH_CONFIG_DIR` pointing at an empty directory, `GH_TOKEN`/`GITHUB_TOKEN` empty, a 110 s alarm per run (150 s for the specialist cells, 300 s for V3). User-level plugins load, so context-mode is active unless a cell says otherwise. The main loop is told to call `Agent` once with a given brief, byte for byte; the brief is shaped like `commands/next-task.md` §8 (task id, facts, cwd, acceptance) for a trivial docs task. Nested cells: the brief tells a first-level `general-purpose` agent to do the inner dispatch. Observables: classification lines, any "no verdict" text, `permission_denials` in the JSON output, and the subagent transcript JSONL (the first user message is the exact input received, block occurrences counted). The main-loop transcript's `Agent` `tool_use` input is the input before the hook ran; it was compared to the expected text in the V2 cells (equal in 14 of 15 top-level V2 runs, the 15th had one extra trailing character; in the nested V2 cell the inner call was compared: 4 of 5 equal, 1 contained the text; no effect on counts). The scratch repo, `--settings` files, scratch plugin, debug logs and transcripts are outside the repository and not committed. No user setting was edited; context-mode stayed enabled for every cell except V4(alone) and V7, where a per-run `--settings` file set `enabledPlugins` for the registry key `context-mode@context-mode` to false.

## V1: baseline, plain brief

"First-attempt accepted" counts runs (of 5) in which the first `Agent` call ran with no refusal. "Block" is the number of `<context_window_protection>` blocks in the received first user message.

| Cell | Dispatch | First-attempt accepted | Classified | Refused "no verdict" | Block received |
|------|----------|------------------------|------------|----------------------|----------------|
| V1 top | `general-purpose`, from top level | 5 / 5 | 5 / 5 | 0 | 1 (5 of 5) |
| V1 nested | `general-purpose` -> `general-purpose` | 5 / 5 | 10 calls / 10 | 0 | 1 at both levels |
| V1 top, specialist | `atelier:tester`, from top level | 1 / 5 | 5 / 5 | 0 | 1 (the one that ran) |
| V1 nested, specialist | `general-purpose` -> `atelier:tester` | 5 / 5 | 10 calls / 10 | 0 | 1 at both levels |

Counts: 0 of 20 runs produced the "no verdict" refusal. The four specialist-top denials are classifier denials tagged `[Instruction Poisoning]` after stage 2 (`stage=xml_s2` in 4 of 4), a different refusal from the one in #687; the same brief nested was accepted 5 of 5, so this looks like the brief shape (a "make no tool calls, reply DONE" instruction to a named specialist), not the hook (V7 below ran the same brief with no classifier call at all). It is reported because it shows the 2026-10-26 intermittent-denial pattern is still present when the hook is on.

## V2: H1 vs H2, first dispatch pre-appended

The brief carries the text appended before the call, then the hook runs on it. (i) is the byte-identical block from V5; (ii) is that block with one space removed from the indentation of the second line; (iii) is an empty `<context_window_protection></context_window_protection>` tag.

| Cell | Level | First-attempt accepted | Refused "no verdict" | Blocks carried in the call | Blocks received |
|------|-------|------------------------|----------------------|----------------------------|-----------------|
| (i) byte-identical block | top level | 5 / 5 | 0 | 1 | 2 (5 of 5) |
| (i) byte-identical block | nested, inner dispatch | 5 / 5 | 0 | 1 | 2 at both levels (5 of 5) |
| (ii) one whitespace change | top level | 5 / 5 | 0 | 1 | 2 (5 of 5) |
| (iii) empty tag | top level | 5 / 5 | 0 | 1 | 2 (5 of 5) |

Counts: 25 of 25 first attempts accepted, 0 refusals. The hook appended a second block in every case, including the byte-identical one, so the received input was never equal to the carried input and was still accepted. The classifier reviewed the post-hook input (`actionChars` 9,651 in (i)). Pre-appending therefore does not make the hook "leave the input unchanged", and no run shows a benefit of pre-appending, because the plain brief was accepted too (V1).

## V3: nested dispatch, three levels, block accumulation

Shape: the top level dispatches a coordinator (level 1) whose brief embeds, byte for byte, the level-2 brief, which embeds the level-3 brief; each embedded brief also carries the block(s) a re-issue would carry (#683 shape: the specialist brief already contains blocks, the hook appends another). The instruction to the dispatcher is one verbatim re-issue of the quoted input if refused. n=5.

| Level | Blocks carried in the dispatch call | Blocks received | Classified / accepted first time | Re-issues needed |
|-------|--------------------------------------|-----------------|-----------------------------------|------------------|
| top level -> level 1 | 3 | 4 (5 of 5) | 5 / 5 | 0 |
| level 1 -> level 2 | 3 | 4 (5 of 5) | 5 / 5 | 0 |
| level 2 -> level 3 | 2 | 3 (5 of 5) | 5 / 5 | 0 |

Counts: carried 3/3/2 and received 4/4/3 in all 5 runs, so the hook added exactly one block at every hop. Attempts to converge were 1 for every call, 15 of 15 calls accepted first time, 0 re-issues, 0 refusals. The block count never stabilises at 1 (one more than carried at every hop), which is the idempotency gap the epic names; it does not make the input drift in a way that blocks the call. Length of the level-1 input: about 19.4 KB with 4 blocks.

Discarded designs, so the cell is not read as cherry-picked (n=5 each): (1) a brief telling each level to forward its whole received message with the level number raised: 2 of 5 classifier-denied (one `[Create Unsafe Agents]`), 1 refused by the model itself before any call, 1 completed, 1 hit the 110 s cap; (2) a brief telling each level to copy every block it received: 3 of 5 denied by the classifier at the top-level call (two `[Auto-Mode Bypass]`, one untagged), 2 hit the cap; (3) the final design run with the harness alarm left at 110 s by a script bug: 5 of 5 hit the cap, no verdict; rerun at 300 s is the table above. Self-replicating briefs are classifier triggers in their own right, independent of the hook.

### The #683 record in `dispatch-denials.jsonl`

`${ATELIER_STATE_DIR:-~/.local/state/atelier}/dispatch-denials.jsonl` has 57 lines. It holds two records dated after 2026-11-01: the 2026-11-02T14:56:28Z denial (command `plan-task`, agent `planner`, task `683`, tag `[Auto-Mode Bypass]`, attempt 1, 6-line inline prompt, session role `plan`) and its outcome (`redispatch`, re-issue `accepted`). Each denial record carries date, project, command, agent, task, tag, attempt, a prompt copy path and sha256, line count, prompt form, session role and prior denials in the session; each outcome carries the operator's choice and whether the re-issue was accepted. What it lacks: the #683 `tester` hold from inside `task-orchestrator` is not in the log at all (the log is written by the top-level operator flow, not by sub-agents), and no record carries the "no verdict" text, a hook name or a block count. So the log cannot confirm or refute either "the re-issue never stabilises" or "one re-issue is accepted".

## V4: can an atelier hook or a permission rule neutralise the context-mode hook? (closes (b) only)

A scratch plugin (second `--plugin-dir`, temp dir) registers a `PreToolUse` `Agent` hook that returns `updatedInput` with the prompt plus the line `[V4-SCRATCH-HOOK-MARK]`. Cell 1: that only. Cell 2: also `permissionDecision: allow`. Cell 3: no hook decision, `--settings` rule `permissions.allow: ["Agent(general-purpose)"]`. "With context-mode" is the real setup (both hooks load); "alone" disables context-mode as in V7. n=5 per cell.

| Cell | context-mode | Classifier ran / allowed | "no verdict" | Input that ran |
|------|--------------|--------------------------|--------------|----------------|
| 1 `updatedInput` only | on | 5 / 5 | 0 | context-mode's: block in 5 of 5, scratch mark in 0 of 5 |
| 1 `updatedInput` only | off (alone) | 5 / 5 | 0 | scratch mark in 5 of 5 |
| 2 `updatedInput` + `permissionDecision: allow` | on | 0 / 0 (never classified) | 0 | context-mode's: block in 5 of 5, mark in 0 of 5 |
| 2 `updatedInput` + `permissionDecision: allow` | off (alone) | 0 / 0 (never classified) | 0 | scratch mark in 5 of 5 |
| 3 allow rule `Agent(general-purpose)`, no hook decision | on | 5 / 5 | 0 | context-mode's, scratch mark in 0 of 5 |
| 3 allow rule `Agent(general-purpose)`, no hook decision | off (alone) | 5 / 5 | 0 | scratch mark in 5 of 5 |

Findings (verified at n=5 unless marked): (1) matching hooks run in parallel on the original input and one `updatedInput` wins; with both loaded the winner was context-mode's in 5 of 5 (its hook finished later, about 92 ms against 61 ms; "last finisher wins" is inferred, a race this size cannot be separated from plugin order at n=5), so an atelier hook cannot undo or pre-empt the append; (2) a hook-level `permissionDecision: allow` removes classifier review entirely (0 of 10 classified); (3) a settings allow rule does not (10 of 10 still classified). The "no verdict" refusal was not reproduced in this cell either, so "does an allow decision avoid it" is not measurable under `-p`; what is measured is that it avoids the classifier.

## V5: the rendered block is the appended text (deterministic)

`hooks/routing-block.mjs` was imported with Node and `createRoutingBlock(t, { includeCommands: false, toolSearchBootstrap: true })` called with `createToolNamer("claude-code")` from `hooks/core/tool-naming.mjs`. The output is 4,637 bytes (it begins with a newline), sha256 `17f62075...`. Compared with the suffix the real hook appended to the prompt in the V1 first-level transcript: `cmp` reports no difference; the same text was byte-identical in 5 of 5 V1 transcripts (received input equals brief plus render); a second render gave an identical result. So the block can be rendered from the installed context-mode, never vendored, and equals what the hook appends (verified).

Side effects of the import: the mtime and size of every file under the context-mode cache directory (about 6,460 files) and the mtime, size and sha256 of `~/.claude-work/settings.json` were captured before and after two renders; the lists are identical. A first attempt of the same check differed in one file, `node_modules/better-sqlite3/build/Release/better_sqlite3.node`, because a live context-mode MCP server of another session touched it while the V3 runs were finishing; the check was repeated with no run in flight and is identical. `hooks/pretooluse.mjs` was never executed (it would self-heal and rewrite config); only `routing-block.mjs` and `tool-naming.mjs` were imported, and the former only builds strings and a static default export.

## V7: context-mode disabled

Per-run `--settings` file with `enabledPlugins` `context-mode@context-mode: false` (key taken from `~/.claude-work/plugins/installed_plugins.json`); user settings not edited.

| Cell | Accepted | Classifier ran | Refused | Block received |
|------|----------|----------------|---------|----------------|
| `general-purpose`, top level | 5 / 5 | 0 / 5 | 0 | 0 (message length 184) |
| `general-purpose` -> `general-purpose` | 5 / 5 | 0 / 5 | 0 | 0 at both levels |
| `atelier:tester`, top level (same brief as V1 specialist) | 5 / 5 | 0 / 5 | 0 | 0 |
| `general-purpose` -> `atelier:tester` | 5 / 5 | 0 / 5 | 0 | 0 at both levels |

Counts: 20 of 20 dispatches ran with no classifier call and no refusal. This differs from the 2026-10-26 expectation (classified in 35 of 35 dispatches, with the hook on): with context-mode off the classifier does not review these `Agent` dispatches at all in 2.1.317 under `-p`, and with it on every dispatch is reviewed (V1: 30 of 30 classifier calls). The hook's rewrite is what brings the call under review (verified for these two subagent types at n=5; the mechanism is not testable here). Two consequences: the "no verdict" exposure exists only when a rewriting hook is present, and V4 cell 2 is what removes review, which is why (b) is a #457 bypass.

## Observed in production, not a controlled run (2026-11-03)

- #684 chain: from `task-orchestrator`, the first dispatch of `tester`, `pr-author` and `reviewer` each got "no verdict" and one verbatim re-issue of the hook-produced input was accepted; the same for the planner -> `task-decomposer` dispatch. This is the operator-reported record; the refusals themselves are not in the denial log.
- #688 chain, this task, 2026-11-03: `task-orchestrator`'s first dispatch of `implementer` was refused with "no verdict ... a hook changed this call's input"; the hook-produced input carried one `<context_window_protection>` block appended to the brief; one verbatim re-issue of that input was accepted.
- The input this task's own orchestrator received from the `/next-task` top level carried one `<context_window_protection>` block at the end (a first dispatch from the top level: one block, as in V1).
- Block counts in 29 sub-agent first messages in the operator's session transcripts dated 2026-11-02 and 2026-11-03 (`~/.claude-work/projects/-Users-mike-Work-atelier/`): 24 carry 1 block, 4 carry 2 (`pr-author`, `implementer`, and two `task-orchestrator` dispatches), 1 carries 3 (`implementer`). Counts above 1 are consistent with the hook adding one block per pass, as in V3. The transcripts do not record whether a given input followed a refusal, so a 2-block record cannot be attributed to a #684 re-issue.
- Resolution of the conflict with the #687 body ("the input never stabilises"): V3 shows the count grows by one per pass but every re-issued input was accepted the first time it was reviewed; the production record (one re-issue accepted, in each of four dispatches) agrees. "Never stabilises" is true of the count and false of acceptance, so the #683 tester hold was not caused by drift. Its cause is not determinable from the records (not in the denial log; probably a non-identical re-issue or a stop under the #457 rule, as the epic suspected).

## Options compared

| Option | What it does | Evidence | Verdict |
|--------|--------------|----------|---------|
| (a) pre-append the block | atelier renders the block (V5) and puts it in the brief | V2: 25 of 25 first attempts accepted, but plain briefs are accepted as well (V1); the hook appends again in every case (received blocks 2 for byte-identical, one-space-different and empty-tag inputs), so the received input still differs from the carried one; costs 4.6 KB per dispatch to get a second block | Set aside (product lead, 2026-11-03) while the hook is not idempotent |
| (b) neutralise the hook | second hook or permission rule | V4: hooks race and context-mode's `updatedInput` won 5 of 5; `permissionDecision: allow` removes classifier review (0 of 10 classified), which is a bypass of #457; an allow rule leaves review untouched (10 of 10) | Rejected |
| (c) one verbatim re-issue | on "a hook changed this call's input", re-issue the hook-produced input once, then stop with a distinct held reason | V3: 15 of 15 calls accepted when reviewed; 0 re-issues were needed in `-p`; production 2026-11-03: one re-issue accepted in all 4 recorded refusals; Claude Code's own refusal text prescribes exactly one re-issue | Chosen (product lead, 2026-11-03); the only option with a production data point |

Why (b) is rejected, citing V4: an atelier hook cannot undo context-mode's append (parallel hooks, its rewrite won 5 of 5), and the only mechanism that avoids the classifier, `permissionDecision: allow`, takes atelier dispatches out of review (0 of 10 classified), which is the class of change #457 forbids. A permission allow rule does not help (10 of 10 still reviewed).

## Final choice

By the epic rule read literally: V2(i) was accepted first time 10 of 10 (top level and nested), so the rule's letter gives H1 and "(a) main + (c) fallback". That reading is not safe: the rule assumed the plain dispatch is refused first and the pre-appended one is not, and V1 shows the plain dispatch is also accepted first time (0 of 20 refusals under `-p`). H1 and H2 predict the same outcome in every cell here, so V2 does not separate them, and the production refusal path (server-side review, not reachable under `-p` in 2.1.317, inferred) was not exercised. The data supports:

- **(c) as the single mechanism**: needed in production, safe in every measured case, prescribed by Claude Code's refusal text, one re-issue only.
- **(b) rejected.**
- **(a) set aside**: no measured benefit, a guaranteed second block, a ~4.6 KB brief cost per dispatch, and it needs a render helper tied to context-mode's internals. It stays set aside while context-mode's Agent hook is not idempotent.

**Decision (product lead, 2026-11-03): the final choice is (c) alone**, one verbatim re-issue of the hook-produced input, then stop with a distinct held reason. Reason: it is the only path observed to work in production (the #684 chain and this task's own implementer dispatch). (a) pre-append is set aside while context-mode's Agent hook is not idempotent. The rule was settled by decision rather than measurement because V2 could not separate H1 from H2 under `-p`: the refusal did not reproduce, so no first-attempt refusal existed to compare against.

## Decisions recorded

- The #457 exception (product lead, 2026-11-03) is limited to the "a hook changed this call's input" refusal and to one verbatim re-issue of the hook-produced input; every other denial keeps the operator-answer rule; no stripping of an existing block before the re-issue.
- context-mode is rejected as a declared dependency of atelier (product lead, 2026-11-03): third-party, separate marketplace, self-upgrading and self-healing (its `pretooluse.mjs` rewrites config), it reroutes tools for every session, and Claude Code plugin dependency support is unverified. atelier detects an enabled plugin with an `Agent`-matching `PreToolUse` hook and records a tested range instead.
- Proposed tested range for #689: Claude Code 2.1.317 with context-mode 1.0.169, recorded as "last verified" not as a gate; the detection helper should warn, not block, outside it, and the doctor should record both versions. The block text and the hook are version-specific (V5 renders from the installed copy each time).
- The 2026-11-03 finding that disabling a rewriting hook removes classifier review of these dispatches (V7) is recorded as an observation for #689/#690; it is not a proposal to disable context-mode, which stays enabled.

## Draft only: upstream idempotency issue (not filed; operator decision 2026-11-03; nothing is published outside AkaLab)

Title: Agent PreToolUse routing appends the subagent block unconditionally; make it idempotent

`hooks/core/routing.mjs` (v1.0.169, the `canonical === "Agent"` branch, lines 894-915) appends `createRoutingBlock(...)` to the subagent prompt and returns `updatedInput`, without checking whether the prompt already contains the block. A prompt that already carries `<context_window_protection>` (byte-identical, whitespace-changed or an empty tag) receives a second block; across nested dispatches the count grows by one per hop (measured 1, 2, 3, 4). Impact: about 4.6 KB of duplicated context per dispatch, and a caller that includes the block up front cannot produce an input the hook leaves unchanged, which matters wherever a host reviews the input before the hook runs. Proposed fix: skip the append when the prompt already contains `<context_window_protection>` and return no modification in that case (the `Bash` to `general-purpose` rewrite still has to happen). Environment: Claude Code 2.1.317, context-mode 1.0.169.

## Hypotheses

| # | Hypothesis | Status | Evidence |
|---|-----------|--------|----------|
| H1 | A pre-appended block is accepted on the first attempt where a plain one is refused | not testable under `-p`: both are accepted (0 of 40 refusals in V1/V2) | V1, V2 |
| H2 | Only a re-issue matching the hook-produced input is accepted | not testable under `-p` (no refusal to re-issue from); consistent with Claude Code's refusal text and production | V3, binary text |
| H3 | The context-mode hook is not idempotent | verified | V2 (received blocks 2 for byte-identical, one-space, empty-tag), V3 (one more per hop), `routing.mjs:894-915` |
| H4 | The rendered block equals the appended text and rendering has no side effects | verified (n=1 plus repeats; 5 of 5 transcripts) | V5 |
| H5 | Under `-p`, the classifier reviews the post-hook input | verified | `actionChars` 4,979 / 9,651 / 209 |
| H6 | The production refusal comes from a server-side review that precedes hooks | inferred (binary text, `tengu_violin_speculative_classifier`) | not reachable under `-p` |
| H7 | A second hook cannot override context-mode's rewrite; one `updatedInput` wins | verified as a direction (5 of 5); last-finisher rule inferred | V4 |
| H8 | `permissionDecision: allow` removes classifier review; an allow rule does not | verified (0 of 10 vs 10 of 10 classified) | V4 |
| H9 | Disabling context-mode removes classifier review of these dispatches | verified for `general-purpose` and `atelier:tester` (0 of 20 classified vs 30 of 30 with it on) | V7, V1 |
| H10 | A single verbatim re-issue converges | verified where measurable (15 of 15 first-time acceptance, 0 re-issues needed); production 4 of 4 | V3, #684 |
| H11 | The block count stabilises at 1 | false (one more per pass), but acceptance does not depend on it | V3, transcripts |

## Reproduce

Needs a scratch git repo, an empty `GH_CONFIG_DIR`, and for each run: `claude -p --permission-mode auto --plugin-dir <worktree> --settings <file> --debug-file <log> --output-format json -- "<prompt>"` where the prompt tells the main loop to call `Agent` once with a given `subagent_type` and the brief between markers. Count with `grep -c 'being classified: tool=Agent'`, `grep -ci 'no verdict'`, `permission_denials` in the JSON, and the first line of each `<session>/subagents/*.jsonl` under `~/.claude-work/projects/<scratch path>/` (count `<context_window_protection>`). V4 needs a scratch plugin whose `hooks/hooks.json` matches `Agent` and runs a script printing `{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{...}}}` (plus `"permissionDecision":"allow"` for cell 2). V5 needs a Node script importing `hooks/routing-block.mjs` and `hooks/core/tool-naming.mjs` by absolute path; compare with `cmp` against the suffix of a V1 subagent's first message; never run `hooks/pretooluse.mjs`. V7 and V4 "alone" need a `--settings` file `{"enabledPlugins":{"context-mode@context-mode":false}}`. Not tested: interactive (non-`-p`) sessions, the server-side review path, other Claude Code or context-mode versions.
