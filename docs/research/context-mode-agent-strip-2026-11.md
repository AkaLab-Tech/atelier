# Can atelier neutralise context-mode's `Agent` rewrite before auto-mode review and re-add its guidance afterwards? (#725)

Date: 2026-11-05. Claude Code 2.1.318 (probed; the refusal this spike targets was first seen on 2.1.317, see `docs/research/agent-input-hooks-2026-11.md`). context-mode 1.0.169 (installed from `~/.claude-work/plugins/cache/context-mode/context-mode/1.0.169`; its own tools announce that v2.1.3 is available, which was not tested). Main loop Sonnet 5.5 under `--permission-mode auto`, direct Anthropic API.

Question: context-mode's `PreToolUse` hook (matcher `Agent`) appends a `<context_window_protection>` block to every subagent prompt (and rewrites `subagent_type` `Bash` to `general-purpose`). In an interactive auto-mode session Claude Code refuses the first dispatch because a hook changed the input after the server-side review. Could an atelier hook make the final input equal the reviewed one, and could the guidance then reach the subagent through a channel that runs after the review? This is a spike: it measures and recommends, changes no script, hook, setting or plugin file, and commits nothing but this document. context-mode stayed enabled and untouched (except in the arms that disable it per run through `--settings`).

**Read the counts as a direction, not a rate.** Every arm has n=3 to 5. The classifier is non-deterministic.

## Headline

The approach works in this configuration, with one structural caveat (a timing race, below).

1. **Claude Code compares the input by value, not by presence** (P1, verified). A hook that returns `updatedInput` byte-identical to the model's input was accepted first time in 5 of 5 interactive runs; the baseline with context-mode's real rewrite was refused in 5 of 5.
2. **Matching hooks run in parallel on the same original input and the last one to finish wins** (P2, verified: 32 of 35 runs match "last finisher wins"; the 3 misses had end times within 0.5 ms). No hook sees another's `updatedInput`; there is no merge and no error. So atelier's hook is not ordered after context-mode's by any rule; it takes effect only if it finishes later, which it can guarantee only by waiting. context-mode's hook takes about 70 ms; a 400 ms hold won in every run.
3. **Strip works** (P3, verified): with context-mode enabled, a hook that returns the original input (held 700 ms) got 0 refusals in 10 of 10 interactive runs (identity 5, strip-by-text 5), against 5 of 5 refused without it. context-mode's append is discarded entirely.
4. **`SubagentStart` `additionalContext` is delivered to the subagent** (P4, verified on 2.1.318): the nonce and the routing block reached the subagent in 5 of 5 `-p` runs (0 of 5 in the control), and the subagent's first `ctx_execute` after the `ToolSearch` bootstrap worked in 5 of 5. The hook payload carries `agent_type` with the `atelier:` prefix, so it can be scoped.
5. **The text comes from the installed plugin at runtime**, byte-equal to what context-mode appends (verified). Nothing is vendored.

What the approach does not remove: (a) the race in point 2; (b) a hook that edits what the model wrote is refused once even if the edit is "right": stripping a block the model itself carried was refused 3 of 3 and the re-issue of the stripped input was accepted 3 of 3 (P3d); (c) context-mode's same-class rewrite on its own `ctx_execute` calls (cwd injection), seen once in a subagent report (P4-1), is untouched by this design.

## Method

Harness of `docs/research/auto-mode-chain-2026-10-26.md` and `agent-input-hooks-2026-11.md`, extended with an interactive arm. All probe material lives in a scratch directory outside the repo and is reproduced inline under "Reproduce".

- **`-p` arms**: `claude -p --permission-mode auto --settings <probe.json> --output-format json --debug-file <log>`, prompt on stdin, from a scratch git repo.
- **Interactive arms**: the same flags without `-p`, driven through a pseudo-terminal (`pty_run.py`) that waits for the TUI, types a prompt, presses Enter and records the screen text. The working directory is the (already trusted) task worktree, because a scratch directory raises the folder-trust dialog, whose default is "No, exit" and which was not accepted (it would write trust state into the operator's config). The dispatched subagent is told to reply with one word and use no tools; nothing was written to the worktree (`git status --short` empty before and after).
- **Why both**: `-p` does not reproduce the refusal. In the 2.1.318 binary (`strings`), the server-side review path has a fallback: "after the server reviewed the response a hook rewrote this call's input ... the local classifier judges this one call". That line appears in every `-p` debug log (P0) and the local classifier then reviewed and allowed the call. The refusal text "gave no verdict ... a hook changed this call's input after the model wrote it ... and no other review of it was available" applies when there is no local review. Interactive sessions showed it, rendered in the TUI as `Not run · auto mode's check had no usable answer` on the first `Agent` call, after which the model re-issued the call itself.
- **Refusal count (interactive)**: presence of `Not run · auto mode` in the screen text of the run, plus the number of `PostToolUse` probe lines (one per executed dispatch). **Refusal count (`-p`)**: `permission_denials` in the JSON result (and the debug log).
- **Interactive limits**: the TUI redraws garble free text (letters dropped), so subagent answers could be read legibly in only some interactive runs (P4: 2 of 5); the `-p` repeat of P4 is the source for those counts. The server-side classifier is non-deterministic and the harness cannot count refusals of calls inside a subagent.
- `atelier-dispatch-denial record` was used for the refusals caused by context-mode's real hook (I0 and B0). It is synthetic data from a spike: `--command task-orchestrator --agent implementer --task 725`, prompt copy = the probe dispatch line. Refusals caused by my own probe hooks (P3d) are not recorded there.

## Results per arm

"Refused" counts runs whose first `Agent` call was refused. "Ran" counts executed dispatches (`PostToolUse` lines or the subagent's answer).

| Arm | Mode | Hooks in play | n | Refused | Notes |
|-----|------|---------------|---|---------|-------|
| P0 baseline | `-p` | context-mode on, log-only `PostToolUse` capture | 5 | 0 | `permission_denials` empty in 5 of 5; debug shows the "local classifier judges this one call" fallback; received prompt length 4,665 = 28 + 4,637 (the block) |
| I0 baseline | interactive | same | 5 | 5 | verbatim: `Not run · auto mode's check had no usable answer`; the model re-issued once in 5 of 5 and the re-issue ran (received length 4,665). Denial refs `20261105T183303Z`, `-2`, `-3`, `-4`, `-5` (outcome `auto-reissue`, `accepted`) |
| B0 baseline, `subagent_type: Bash` | interactive | same | 3 | 3 | re-issue ran in 2 of 3 with `subagent_type` rewritten to `general-purpose` (prompt length 4,674); the third was not re-issued by the model. Refs `20261105T183303Z-6` (outcome `held`), `20261105T183309Z`, `20261105T183309Z-2` (`auto-reissue`, `accepted`) |
| P1 value-or-presence | interactive | context-mode **off**, probe `PreToolUse` returns `updatedInput` = stdin `tool_input` | 5 | **0** | input hash before the hook equals the hash `PostToolUse` saw in 5 of 5; all ran first time |
| P1c control | interactive | context-mode off, no hook | 5 | 0 | |
| P2A0 | `-p` | context-mode on, `--settings` hook S and plugin hook PLA, both tag the prompt, no delay | 5 | 0 | block survived in 5 of 5 (both tags lost) |
| P2A1 | `-p` | same, S held 400 ms | 5 | 0 | S's tag survived 5 of 5, block gone |
| P2A2 | `-p` | same, PLA held 400 ms | 5 | 0 | PLA's tag survived 5 of 5, block gone |
| P2B0 / P2B1 | `-p` | context-mode off, two probe plugins A and B, `--plugin-dir` order A,B then B,A, no delay | 5 + 5 | 0 | winner varied with the sub-millisecond finish order, not with load order (see ordering) |
| P2B2 | `-p` | same, A held 400 ms | 5 | 0 | A won 5 of 5 |
| P2C0 / P2C1 | `-p` | context-mode off, two `--settings` hooks, as two entries / as one entry | 5 + 5 | 0 | same: finish order decides, declaration order does not |
| P3a strip (identity) | interactive | context-mode on, hook returns the original input unchanged, held 700 ms | 5 | **0** | received length 52 (brief only, no block) in 5 of 5; baseline I0 was 5 of 5 refused |
| P3b strip (by text) | interactive | context-mode on, hook removes every exact copy of the runtime block text from the prompt, restores nothing else, held 700 ms | 5 | **0** | received length 52 in 5 of 5; 0 copies found to remove |
| B3 strip, `Bash` type | interactive | as P3b | 3 | 0 | `subagent_type` stays `Bash` and Claude Code answers `Agent type 'Bash' not found` in 3 of 3 (see "Bash restore") |
| P3d strip, brief carries 1 copy | interactive | as P3b | 3 | 3 | first call (4,643 chars with one copy) refused; the hook removed 1 copy; the model re-issued the stripped input (hash equals the hook's output) and it ran, 3 of 3 |
| P3 offline, 0/1/2 copies | unit | the strip logic fed synthetic stdin | 5 cases | n/a | 0, 1, 2 copies, 2 copies with text between, and `Bash` + 1 copy: no copy left in any, `subagent_type` unchanged |
| P4p re-add | `-p` | strip hook (400 ms) + `SubagentStart` hook returning a nonce line + the runtime block | 5 | 0 | subagent printed the nonce in 5 of 5, saw `<context_window_protection>` in 5 of 5, `ctx_execute` after the bootstrap printed `CTXOK` in 5 of 5 |
| P4pc control | `-p` | strip hook only | 5 | 0 | nonce `NONE` 5 of 5, tag absent 5 of 5, `CTXOK` 5 of 5 (so the subagent can use `ctx_*` without the block, but is not told to) |
| P4 interactive | interactive | as P4p | 5 | 0 | main-loop dispatch not refused in 5 of 5; subagent answers legible in 2 of 5 (P4-1, P4-5): nonce correct, tag seen, `CTXOK`; the other 3 garbled by the TUI |
| P4s scoping | `-p` | `SubagentStart` matcher `atelier:.*` | 3 + 3 | 0 | fired for `atelier:tester` in 3 of 3 (nonce delivered), not for `general-purpose` in 3 of 3 |

Totals: 61 `-p` runs and 44 interactive runs. Denial refs used: `20261105T183303Z` (and `-2` to `-6`), `20261105T183309Z`, `20261105T183309Z-2`. Before-baseline in the same file: 112 records with `hook = context-mode` from 2026-11-03T21:26Z to 2026-11-05T18:09Z, 109 with an accepted re-issue (118 after the 6 records of this spike).

## Answers to the verification questions

### Does Claude Code compare by value or by presence of a hook rewrite? (P1)

By value (verified, interactive n=5, 0 refused; P1c control 0 of 5). With context-mode disabled for the run, a `PreToolUse` `Agent` hook returned `hookSpecificOutput.updatedInput` equal to the `tool_input` it received. The dispatch was accepted first time in 5 of 5 and the input hash before and after the hook matches in the probe log. The strip approach is therefore not ruled out. The binary's two refusal strings (`strings` on 2.1.318) are consistent with this: both talk about the review "of different input from what would run".

### How are `PreToolUse` hooks from two plugins (and settings) ordered and merged for one event/matcher? (P2)

- **Parallel** (verified): two hooks of different sources (a `--settings` hook and a `--plugin-dir` plugin) started within 0 to 10 ms of each other in all 15 runs of P2A and within 12 ms in P2B and P2C.
- **No chaining** (verified): in every run both probes logged the same input hash (40 of 40), so a later hook never saw an earlier hook's `updatedInput`.
- **No merge, no error** (verified): the final prompt carried at most one probe tag in 40 of 40 runs (none when context-mode won, never two), and no run raised an error.
- **Which `updatedInput` wins**: the hook that finishes last (verified, 32 of 35 runs agree with the process-end timestamps; the 3 exceptions have end gaps under 0.5 ms, below what the in-process timestamp can resolve). With a 400 ms hold the held hook won 15 of 15 (P2A1 5, P2A2 5, P2B2 5), including over context-mode's real hook (whose block disappeared whenever a probe was held). Under ties the winner is arbitrary and unrelated to declaration order or `--plugin-dir` order (P2B0 and P2B1 both gave a mix; P2C0 and P2C1 likewise).
- **Stable across runs?** The ordering rule is; the winner under a tie is not.
- **Can atelier's hook reliably take effect after context-mode's?** Only by finishing later. There is no ordering guarantee to rely on. context-mode's hook measured about 70 ms offline (8 runs, 68 to 71 ms) and about 90 ms in the earlier research; a 400 ms hold won every time (P4p, P4 interactive, 10 of 10 with the block gone) and 700 ms did in P3 (10 of 10). The residual risk is a host so loaded that context-mode takes longer than the hold; the result is the old behaviour (one refusal, one re-issue), not a new failure.

### Does `SubagentStart` `additionalContext` reach the subagent on 2.1.318? (P4)

Yes (verified). Nonce plus the runtime block: delivered 5 of 5 under `-p`, absent 0 of 5 in the control; the subagent quoted the nonce and confirmed the `<context_window_protection>` text; 2 of 5 interactive runs were legible and agree. The `SubagentStart` stdin carries `session_id`, `transcript_path`, `cwd`, `scratchpad_dir`, `prompt_id`, `agent_id`, `agent_type`, `hook_event_name` (the 2.1.309 list plus `scratchpad_dir`). `agent_type` is `atelier:tester` for plugin agents, so a matcher `atelier:.*` scopes the hook to atelier agents (fired 3 of 3, not for `general-purpose` 3 of 3). The skill or agent-definition include candidates and other injection points were not tested because the first candidate delivered. The first `ctx_execute` call after `ToolSearch` worked in 5 of 5 `-p` runs; in one interactive run (P4-1) the subagent reported that its own first `ctx_execute` was refused once because context-mode's MCP hook adds a `cwd` field after review, and ran on the re-issue. That is the same refusal class on a different call and is not addressed here.

### Can the guidance be read from the installed plugin at runtime? (step 6)

Yes (verified). The one-liner under "Reproduce" resolves the install path from `installed_plugins.json` under `$ATELIER_CONFIG_DIR` (falling back to the newest cache directory), imports `hooks/routing-block.mjs` and `hooks/core/tool-naming.mjs` and prints `createRoutingBlock(createToolNamer("claude-code"), { includeCommands: false, toolSearchBootstrap: true })`: 4,637 bytes, sha256 `17f6207535d97f9cbab408a843b82ffea8556eee709bc4528f0d598c1373a977`. Byte-equality: (a) run offline through `hooks/pretooluse.mjs` with a synthetic Agent input, the appended suffix equals the render (comparison `true`); (b) in the live runs P2A0 (5 of 5) the input Claude Code passed to `PostToolUse` contains the render as an exact substring and its length is the brief plus 4,637 (P0: 4,665 = 28 + 4,637). Nothing is committed: this document quotes the hash, length and command only.

Running `pretooluse.mjs` offline is something the earlier research avoided (it self-heals and rewrites config under the cache dir). Here it was run 9 times with `CLAUDE_PLUGIN_ROOT` set; no file under `~/.claude-work` outside session projects changed in the 15 minutes spanning those runs (`find -newermt` empty; `hooks/hooks.json`, `installed_plugins.json` and `settings.json` mtimes unchanged). A follow-up test must use a fake plugin root, not the real one.

**If the signature or exports change** (verified for the two failure shapes that could be simulated): a missing module makes `node` exit non-zero (`ERR_MODULE_NOT_FOUND`), and a thrown error from `createRoutingBlock` exits non-zero. The hook must treat any non-zero exit, empty output or missing install path as "context-mode not usable": print nothing, exit 0 (fail open; the strip hook then leaves the input untouched and adds no delay; the `SubagentStart` hook adds nothing), and let the doctor report it as "unhandled". An added or renamed option that is silently ignored would produce a block that differs from what context-mode appends; the strip-by-text fallback would then miss copies (they stay in the carried input) while the identity path is unaffected. A doctor self-check can compare the render with a real hook's output on a fake input in a temp copy of the plugin root.

### Does it cover every copy of the block, and `subagent_type` Bash to `general-purpose`? (P3)

- **Copies** (verified offline, plus live for one copy): the strip removed 0, 1 and 2 copies (also 2 with text between them) completely. Live, a brief carrying one copy was refused once (3 of 3) because removing it is itself a change to what the model wrote, and the re-issue of the stripped input ran (3 of 3). The palabrium double-block shape arises when the model re-issues a hook-produced input that already carries a block and the hook appends another; with the strip winning, the hook-produced input stays clean, so that shape does not recur (inferred; a live run with two copies was not made).
- **Bash restore**: the identity output keeps `subagent_type: Bash` (B3 and the unit case). In 2.1.318 that type does not exist (`Agent type 'Bash' not found. Available agents: ...` in 3 of 3), so context-mode's rewrite was masking an error for ad hoc `Bash` dispatches. Atelier dispatches only `atelier:*` and `general-purpose` agents, so no chain dispatch is affected; the hook must not re-map `Bash` itself (any value change is refused, per P1).

## Hypotheses

| # | Hypothesis | Status | Evidence |
|---|------------|--------|----------|
| H1 | Claude Code accepts a hook-modified-then-restored input (value comparison) | verified | P1 5 of 5 accepted; I0 5 of 5 refused |
| H2 | `-p` reproduces the refusal | verified false | P0 0 of 5, fallback to local review in the debug log |
| H3 | Matching hooks are chained (a later hook sees an earlier `updatedInput`) | verified false | same input hash in 40 of 40 runs |
| H4 | Several `updatedInput` are merged or raise an error | verified false | never two tags in 40 of 40 |
| H5 | The last hook to finish wins | verified | 32 of 35; misses under 0.5 ms; 15 of 15 with a 400 ms gap |
| H6 | An atelier hook is guaranteed to run after context-mode's by load order | verified false | order within a tie is arbitrary (P2B, P2C) |
| H7 | A hold of 400 ms is enough on this host | verified (this host, idle) | context-mode 68 to 71 ms; 20 of 20 wins at 400 or 700 ms |
| H8 | The same hold is enough on a loaded host | not testable here | no controlled load; degradation is the old refusal plus one re-issue |
| H9 | Strip with context-mode on removes the refusal | verified | P3a and P3b 0 of 10 against I0 5 of 5 |
| H10 | `SubagentStart` `additionalContext` reaches the subagent | verified | P4p 5 of 5, control 0 of 5 |
| H11 | `agent_type` allows scoping to `atelier:*` | verified | P4s 3 of 3 and 0 of 3 |
| H12 | The routing text can be rendered at runtime, byte-equal | verified | cmp-equivalent checks above |
| H13 | A render signature change fails closed | verified for module-missing and throw | simulated with a fake root |
| H14 | Stripping a block the model carried avoids a refusal | verified false | P3d refused 3 of 3, re-issue accepted 3 of 3 |
| H15 | Two carried copies are removed live | inferred | unit test removes 2; no live run with 2 |
| H16 | context-mode 2.x keeps the same hook shape | not testable | 1.0.169 only; v2.1.3 announced |
| H17 | The skill/agent-definition include or other injection points are needed | not tested | SubagentStart delivered |
| H18 | The hold is acceptable latency | inferred | +400 ms per Agent dispatch, once |
| H19 | Refusals of context-mode's `ctx_execute` cwd rewrite are removed | verified false (out of scope) | seen in P4-1, not addressed |

## Verdict and follow-up plan

The approach works. Recommended: implement it, keep one verbatim re-issue as the fallback for the race, and do not pursue the `claude -p` specialist route or a scoped `autoMode` rule (the latter cannot affect a server-side review of rewritten input and `permissionDecision: allow` removes review, which `agent-input-hooks-2026-11.md` already rejects as a #457 bypass).

Follow-up tasks (to be filed by the product lead, not by this spike):

1. `hooks/strip-context-mode-agent-block.sh`, `PreToolUse` matcher `Agent`: if no usable context-mode install is found (shared resolver, same one-liner), exit 0 at once with no output and no delay. Otherwise read stdin, compute the original `tool_input` with every exact copy of the runtime block removed (identity when none), print `hookSpecificOutput.updatedInput` and exit 0 after holding until at least 400 ms have elapsed since it started (wall-clock based hold, not a fixed sleep after work). On any error: fail open (no output, exit 0).
2. `hooks/readd-context-mode-block.sh`, `SubagentStart` matcher empty (context-mode covered all subagents): print `hookSpecificOutput.additionalContext` with the runtime block (same resolver and fail-open rules). Scoping to `atelier:.*` is possible and verified; the recommendation is to cover every subagent, as context-mode did.
3. Two entries in `hooks/hooks.json`.
4. Hermetic tests `hooks/tests/strip-context-mode-agent-block.test.sh` and `hooks/tests/readd-context-mode-block.test.sh` on a fake context-mode plugin root fixture (never the real cache): 0, 1 and 2 copies, `Bash` type unchanged, missing or broken install fails open without delay, hold duration at least the threshold, output JSON shape.
5. Doctor: extend `check_agent_input_hooks()` in `scripts/atelier-doctor` and `atelier-agent-input-hooks detect` to report "neutralised by atelier" when both hooks are registered and a render self-check passes, and "unhandled" otherwise (including a failing render or an untested context-mode version range).
6. `docs/troubleshooting.md`: rewrite the "Agent dispatch refused: a hook changed this call's input" entry around the new hooks. The recovery text of #712 (one verbatim re-issue, then held) is rewritten around them: the re-issue stays only as the fallback for the timing race and for non-context-mode hooks, and the "subagents receive the appended block twice" wording goes away.
7. Known limits to carry into the plan: the race on a loaded host (H8), `ctx_execute` cwd-rewrite refusals inside subagents (H19), context-mode 2.x (H16), and `Bash` as `subagent_type` no longer being masked.

## Reproduce

Scratch dir `S` (not in the repo). A scratch git repo with one commit (made with `git commit-tree`) is the `-p` working directory. Interactive arms use the task worktree as working directory.

Runtime render (step 6), writes the block to stdout:

```bash
CM=$(node -e 'const f=(process.env.ATELIER_CONFIG_DIR||process.env.HOME+"/.claude")+"/plugins/installed_plugins.json";try{const e=JSON.parse(require("fs").readFileSync(f)).plugins["context-mode@context-mode"];console.log(e[0].installPath)}catch(e){}')
[ -d "$CM" ] || CM=$(ls -d "${ATELIER_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/context-mode/context-mode/*/ | sort -V | tail -1)
cd "$CM" && node --input-type=module -e 'import {createRoutingBlock} from "./hooks/routing-block.mjs"; import {createToolNamer} from "./hooks/core/tool-naming.mjs"; process.stdout.write(createRoutingBlock(createToolNamer("claude-code"),{includeCommands:false,toolSearchBootstrap:true}))' > "$S/block.txt"
wc -c "$S/block.txt"; shasum -a 256 "$S/block.txt"
```

`probe.js <label> <mode> [delay_ms]`, used for every probe hook (modes `log`, `identity`, `strip`, `tag`, `nonce`):

```js
#!/usr/bin/env node
const fs=require('fs'),crypto=require('crypto');
const [label,mode,delay]=process.argv.slice(2);
const t_start=String(process.hrtime.bigint());
if(delay)Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,Number(delay));
const inp=JSON.parse(fs.readFileSync(0,'utf8'));
const sha=s=>crypto.createHash('sha256').update(s).digest('hex').slice(0,16);
const ti=inp.tool_input;
const block0=process.env.PROBE_BLOCK_FILE?fs.readFileSync(process.env.PROBE_BLOCK_FILE,'utf8'):'';
const rec={label,mode,event:inp.hook_event_name,t_ns:String(process.hrtime.bigint()),wall:Date.now(),pid:process.pid};
if(ti){rec.input_sha=sha(JSON.stringify(ti));rec.subagent_type=ti.subagent_type;rec.prompt_len=(ti.prompt||'').length;rec.prompt_head=(ti.prompt||'').slice(0,40);rec.prompt_tail=(ti.prompt||'').slice(-60);rec.has_block=block0&&(ti.prompt||'').includes(block0);rec.tags=((ti.prompt||'').match(/\[TAG:[^\]]*\]/g)||[]);}
if(inp.hook_event_name==='SubagentStart'){rec.start_keys=Object.keys(inp);rec.agent_type=inp.agent_type;}
let out=null;
const block=block0;
if(inp.hook_event_name==='PreToolUse'){
  if(mode==='identity') out={hookSpecificOutput:{hookEventName:'PreToolUse',updatedInput:ti}};
  else if(mode==='strip'){
    const u={...ti};let p=u.prompt||'',n=0;
    if(block){while(p.includes(block)){p=p.replace(block,'');n++;}}
    u.prompt=p;rec.removed=n;
    if(process.env.PROBE_RESTORE_TYPE) u.subagent_type=process.env.PROBE_RESTORE_TYPE;
    out={hookSpecificOutput:{hookEventName:'PreToolUse',updatedInput:u}};rec.out_sha=sha(JSON.stringify(u));
  } else if(mode==='tag'){
    const u={...ti,prompt:(ti.prompt||'')+` [TAG:${label}]`};
    out={hookSpecificOutput:{hookEventName:'PreToolUse',updatedInput:u}};rec.out_sha=sha(JSON.stringify(u));
  }
}
if(inp.hook_event_name==='SubagentStart'&&mode==='nonce'){
  out={hookSpecificOutput:{hookEventName:'SubagentStart',additionalContext:`PROBE-NONCE ${process.env.PROBE_NONCE}\n`+block}};
}
rec.out=out?'yes':'none';rec.t_start_ns=t_start;rec.t_end_ns=String(process.hrtime.bigint());
fs.appendFileSync(process.env.PROBE_LOG||'/dev/null',JSON.stringify(rec)+'\n');
if(out)process.stdout.write(JSON.stringify(out));
```

`run.sh <arm> <n> <settings.json> [claude args]` (`-p`; macOS has no `timeout`, so `perl alarm`):

```bash
export PROBE_LOG=$S/logs/$arm-$n.probe.jsonl PROBE_BLOCK_FILE=$S/block.txt
cd $S/repo
printf "%s" "$PROMPT" | perl -e "alarm 150; exec @ARGV" claude -p --permission-mode auto --settings $set --output-format json --debug-file $S/logs/$arm-$n.debug "$@" > $S/logs/$arm-$n.json
```

Default `PROMPT`: `Call the Agent tool exactly once with subagent_type general-purpose, description probe, and prompt: Reply with the single word OK. Do not use any tools. After it returns, print its answer verbatim.`

`pty_run.py <arm> <n> <settings.json>` (interactive driver): `pty.fork()`, `chdir` to `$PTY_CWD`, exec `claude --permission-mode auto --settings <file> --debug-file <log>` with a 50x160 window, wait for the TUI to go quiet, abort if the text contains `Enter to confirm` (trust dialog), type `$PROMPT`, press Enter (`\r`), read until the screen has been quiet for 12 s or `$PTY_MAX` s (default 150), save the ANSI-stripped screen. Refusal check: `grep -q "Not run · auto mode" <screen>`.

Settings files (`$POST` is `"PostToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"node $S/probe.js post-capture log"}]}]`):

```jsonc
// P0 / I0: baseline, context-mode on
{"hooks":{ $POST }}
// P1: value-or-presence, context-mode off, identity
{"enabledPlugins":{"context-mode@context-mode":false},
 "hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"node $S/probe.js identity identity"}]}], $POST }}
// P1c: same without the PreToolUse entry
// P2A: context-mode on, hook S from settings plus plugin PLA via --plugin-dir $S/plug-A
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"node $S/probe.js S tag ${PROBE_DELAY_S:-0}"}]}], $POST }}
// P2B: context-mode off, --plugin-dir $S/plug-A --plugin-dir $S/plug-B (order swapped for B1; PROBE_DELAY_A=400 for B2)
{"enabledPlugins":{"context-mode@context-mode":false},"hooks":{ $POST }}
// P2C0: two entries; P2C1: two hooks in one entry (labels S1, S2, tag, no delay), context-mode off
{"enabledPlugins":{"context-mode@context-mode":false},
 "hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"node $S/probe.js S1 tag 0"}]},
                        {"matcher":"Agent","hooks":[{"type":"command","command":"node $S/probe.js S2 tag 0"}]}], $POST }}
// P3a: strip by identity, held 700 ms, context-mode on
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"node $S/probe.js strip-identity identity 700"}]}], $POST }}
// P3b / B3 / P3d: strip by text, held 700 ms ("strip" instead of "identity")
// P4 / P4p: strip held 400 ms plus SubagentStart (PROBE_NONCE set per run)
{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"node $S/probe.js strip-blocks strip 400"}]}],
          "SubagentStart":[{"matcher":"","hooks":[{"type":"command","command":"node $S/probe.js readd nonce"}]}], $POST }}
// P4s: SubagentStart only, scoped
{"hooks":{"SubagentStart":[{"matcher":"atelier:.*","hooks":[{"type":"command","command":"node $S/probe.js readd-scoped nonce"}]}]}}
```

Probe plugin `plug-A` (and `plug-B` with label `PLB`): `.claude-plugin/plugin.json` = `{"name":"probeA","version":"0.0.1","description":"probe"}`; `hooks/hooks.json` = `{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"node $S/probe.js PLA tag ${PROBE_DELAY_A:-0}"}]}]}}`.

Prompts that differ from the default: B0 / B3 use `subagent_type Bash` and `Run the shell command echo OK and reply with its output only.`; P3d tells the model to Read `$S/block.txt` and pass `Reply with the single word OK.` followed by the exact file contents; P4 asks the subagent three questions (the first token after a `PROBE-NONCE` line; whether the literal `<context_window_protection>` tag is in its context; load `mcp__plugin_context-mode_context-mode__ctx_execute` with `ToolSearch` and run `echo CTXOK` with it).

Per-run observables: `$S/logs/<arm>-<n>.probe.jsonl` (hook input hashes, start and end nanosecond timestamps, tags, block presence), the JSON result (`permission_denials`, `result`), the debug file, the interactive screen text. Winner check for P2: the surviving `[TAG:<label>]` in the `PostToolUse` line against the label with the largest `t_end_ns`.

Refusal records:

```bash
printf '%s' "<probe dispatch line>" | atelier-dispatch-denial record --project <worktree> --command task-orchestrator --agent implementer --task 725 --tag hook-changed-input --attempt 1 --prompt-file - --session-role unknown --hook context-mode@context-mode
atelier-dispatch-denial outcome --ref <ref> --choice auto-reissue --reissue accepted
```
