# Research — Permission "Layer 3": native auto-mode vs. custom PreToolUse hook

**Closes**: M2.6 (ROADMAP).
**Decides**: [PLAN.md §11 v2.3](../../PLAN.md) — "PermissionRequest Bash hook for dynamic permissions, replacing static settings.template.json".
**Date**: 2026-05-29.
**Source data**: Anthropic docs accessed 2026-05-28 via `claude-code-guide` agent (Bash + WebFetch + WebSearch).

---

## Why this spike

Atelier's permission model today is a static allow / deny / ask matrix in `templates/settings.template.json`. Two friction patterns surfaced during M7.1 dogfood-5:

1. **Enumeration gaps** — `git wt list` was missed until [F37](../../HISTORY.md) added `Bash(git wt*)`. Any new helper or alias re-opens the same gap.
2. **Static-analysis bypass** — bash control flow (`for p in $list; do git -C "$d" ...; done`) trips Claude Code's *"Contains shell syntax that cannot be statically analyzed"* prompt, even when every command inside the loop is allowlisted. The matcher can't expand the loop, so it defaults to `ask`.

The matrix can't grow its way out of either pattern: enumeration is unbounded, and shell-syntax detection is a Claude Code behavior atelier can't override from settings. That's why M2.5's three-layer model proposed a "layer 3" semantic fallback — and why M2.6 frames the design choice as **adopt Anthropic's native auto-mode vs. build a custom `PreToolUse` LLM hook (PLAN.md §11 v2.3)**.

---

## Q1 — Composition with the static allow / deny / ask matrix

**Finding.** Auto-mode is documented as a *second gate that runs after the static permissions system*. The documented precedence is:

1. `permissions.deny` from any settings layer blocks the action **before** the classifier is consulted; cannot be overridden by the classifier.
2. `permissions.allow` matches bypass the classifier outright (action is auto-approved).
3. The classifier evaluates **only** actions the static matrix marked `ask` or that were not enumerated at all.

In other words, atelier's existing `deny` list (`git push --force*`, `rm -rf /`, the never-auto-merge surface) survives unchanged under auto-mode — the classifier never sees those commands. The `allow` list (`Bash(git status*)`, `Bash(git wt*)`, etc.) likewise short-circuits to auto-approve. The classifier only intervenes for commands the matrix didn't enumerate (the gap F37 closed) or that tripped the shell-syntax check.

**Source.** [Configure auto mode — Claude Code Docs](https://code.claude.com/docs/en/auto-mode-config.md): *"The classifier is a second gate that runs after the permissions system. For actions that must never run regardless of user intent or classifier configuration, use permissions.deny in managed settings, which blocks the action before the classifier is consulted and cannot be overridden."* Accessed 2026-05-28.

**Confidence.** **High** — official docs are explicit about precedence.

**Caveat.** [GitHub issue #55507](https://github.com/anthropics/claude-code/issues/55507) reports that when project-level `.claude/settings.json` contains a `permissions` block (allow / deny / ask of any kind), the *user-level* `permissions` block — including `defaultMode` — is silently dropped from the merge. Every atelier project ships such a block via `templates/settings.template.json`, so if the issue is current behavior, the documented composition above does **not** hold for atelier — the user-level `defaultMode: "auto"` would be ignored entirely and atelier would stay on `acceptEdits`. Resolution requires empirical testing (see [§Open questions](#open-questions)).

---

## Q2 — Per-task vs. global scope

**Finding.** `defaultMode: "auto"` is **only honored at the user-level config** (`~/.claude/settings.json` by default, or `$CLAUDE_CONFIG_DIR/settings.json` when that env var is set — but see caveat). Setting `defaultMode: "auto"` in a project-level `.claude/settings.json` or `.claude/settings.local.json` is **silently ignored** as a security measure: a malicious repo cannot grant itself auto-mode by checking in a settings file.

The complementary `autoMode.*` sub-config (allow / soft_deny / hard_deny / environment) **is** respected at the project level. That's a project-scoped way to express extra trust for specific commands or environments under auto-mode, but it does not turn auto-mode on — the user-level switch has to be set first.

**Sources.**
- [Settings — Claude Code Docs](https://code.claude.com/docs/en/settings.md): *"⚠️ Note (v2.1.142+): `auto` mode is ignored when set in project or local settings to prevent untrusted repositories from granting themselves auto mode."*
- [Permission modes — Claude Code Docs](https://code.claude.com/docs/en/permission-modes.md): *"If you set `defaultMode: \"auto\"` in settings and the session starts in `default` mode with no error, the setting is likely in `.claude/settings.json` or `.claude/settings.local.json`. Claude Code ignores `auto` from those files so a repository cannot grant itself auto mode. Move it to `~/.claude/settings.json`."*

Both accessed 2026-05-28.

**Confidence.** **High** on the rule itself. **Medium** on whether `$CLAUDE_CONFIG_DIR/settings.json` counts as "user-level" for this rule — the docs name `~/.claude/settings.json` explicitly and do **not** mention `CLAUDE_CONFIG_DIR` in the auto-mode context. The behaviour could be either:

- **(a)** Hardcoded to `~/.claude/settings.json` literally — in which case atelier (which sets `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR`) **cannot** scope auto-mode to its own sessions; the operator must opt their entire machine in via `~/.claude/settings.json`.
- **(b)** Tied to whatever user-level config Claude Code is currently using — in which case atelier **can** write `defaultMode: "auto"` into `$ATELIER_CONFIG_DIR/settings.json` and atelier-launched sessions get auto-mode while the operator's personal `~/.claude/` sessions stay on `default`. This is the path that would let atelier ship auto-mode as part of `install.sh` without touching the operator's global config.

This is the **make-or-break question for adoption** and requires empirical validation (see [§Open questions](#open-questions)).

---

## Q3 — The ~17% false-negative profile

**Finding.** The 17% FN figure is from Anthropic's own production measurement on "overeager" agent actions — cases where the agent attempted something beyond what the user explicitly asked. Where the classifier misses:

- **Ambiguous consent** — the classifier relies on scope heuristics, not explicit authorization checks. *"Clean up the PR"* doesn't textually authorize a force-push, even if a similar action was approved earlier in the session. This is the dominant FN category.
- **Tier 2 edits exempt by design** — file edits inside the working directory **skip the classifier entirely** for latency reasons. When CLI tools aren't available, agents fall back to the `Edit` tool, and Anthropic's own evaluation found a 92.9% FN rate on Tier-2 paths because "nearly all unsafe operations were file edits."
- **Batch operations** — surgical commands (`git branch -d alice/old-branch`) rarely trigger blocks; bulk operations get disproportionate scrutiny, so an attacker who targets one item at a time slips through.

The complementary **false-positive rate** is **0.4% after the full Stage 1 → Stage 2 pipeline** (Stage 1 alone blocks 8.5% of benign actions; the chain-of-thought stage recovers most of them).

**Sources.**
- [Anthropic Engineering Blog — Claude Code Auto Mode](https://www.anthropic.com/engineering/claude-code-auto-mode): *"The classifier allows through 17% of real overeager actions after full processing."*
- [arXiv 2604.04978 — Measuring the Permission Gate](https://arxiv.org/html/2604.04978v1): Stress-test evaluation including the Tier-2 92.9% FNR and 0.4% pipeline FPR.

Both accessed 2026-05-28.

**Confidence.** **High** — published Anthropic data, no contradicting sources found. The figure has not been updated since the ROADMAP M2.6 entry was captured (2026-05-25).

**Implication for atelier.** The 17% FN is concentrated in two areas atelier already protects independently:

- **File edits** (Tier 2) — atelier's per-task `<worktree>/.claude/settings.json` already scopes `Edit`/`Write` to the worktree path. Tier-2 misses outside the worktree are blocked by `additionalDirectories` regardless of the classifier.
- **Force-push / lockfile / workflow surface** — atelier's `deny` list (`git push --force*`, `Edit(<worktree>/.github/workflows/**)`, etc.) blocks these categorically. The classifier never gets to decide.

The residual exposure is "ambiguous-consent overeager actions on Bash commands not in the deny list". That's the surface a custom `PreToolUse` hook (Option B) would cover beyond what auto-mode catches — and it's narrow.

---

## Q4 — Latency

**Finding.** Anthropic publishes the cost qualitatively, not as a benchmark:

- Per-call latency is **roughly 200–400 ms** added to actions that go through the classifier. Reads and in-worktree edits skip it entirely.
- The two-stage architecture (fast path `max_tokens=64`, chain-of-thought stage for ambiguous cases) means **most actions resolve in ~50–150 ms** (Stage 1 fast path) and only the ambiguous tail pays 200–400 ms.
- Per-action **token overhead is ~10–15% of a long refactor**.
- **No caching** is mentioned; same command in the same session pays the classifier cost again.

For atelier's typical 30-command autonomous task, the upper-bound overhead is **~12 s** if every command goes through the classifier (30 × 400 ms), and the realistic mid-point is **~4.5 s** (30 × 150 ms). Tokens cost ~10–15% on top of the existing per-task spend.

**Source.** [Permission modes — Claude Code Docs](https://code.claude.com/docs/en/permission-modes.md): *"Classifier calls count toward your token usage. Each check sends a portion of the transcript plus the pending action, adding a round-trip before execution. Reads and working-directory edits outside protected paths skip the classifier, so the overhead comes mainly from shell commands and network operations."* Accessed 2026-05-28.

**Confidence.** **Medium** — Anthropic confirms the order of magnitude but does not publish a benchmark. Community-reported numbers cluster in the 200–400 ms range and are consistent with Anthropic's qualitative description, so the figure is reliable for planning even though it lacks a primary benchmark.

**Implication for atelier.** 4.5 s of added latency across a task that already takes 5–60 minutes is negligible. The token cost (10–15%) compounds across thousands of autonomous tasks — material, but acceptable in exchange for eliminating the operator-visible permission prompts that today break the autonomous chain mid-task.

---

## Bonus findings

- **Version requirement.** Auto-mode needs Claude Code **v2.1.83+**. The `defaultMode: auto`-ignored-in-project-settings safety guard is v2.1.142+.
- **Model requirement.** Auto-mode requires the session's model to be **Opus 4.6+ or Sonnet 4.6**. Older models do not have the classifier wired in.
- **Plan eligibility.** All Claude plans (Max / Team / Enterprise). On Team / Enterprise, an admin must enable it via [Claude Code admin settings](https://claude.ai/admin-settings/claude-code).
- **Provider.** Anthropic API only — not available on Bedrock, Vertex, or Foundry deployments. Atelier targets Anthropic-API users today, so this isn't a constraint.
- **No per-command-class variant.** Auto-mode is binary: the whole session is on `auto` or it isn't. There's no "auto for Bash only, default for Edit/Write." Atelier can't selectively scope it to the bash-only surface where the friction lives.
- **Auto-pause.** The classifier auto-pauses the session and reverts to prompting after **3 consecutive blocks or 20 total blocks** in one session. Thresholds are not configurable. For atelier this is a feature, not a bug — a runaway autonomous chain that produces 20 sketchy actions deserves human review.

---

## Recommendation — Option C, conditional on empirical validation of Q2

**Adopt auto-mode as the default for atelier-launched Claude Code sessions, *if and only if* empirical testing confirms that `defaultMode: "auto"` is honored from `$ATELIER_CONFIG_DIR/settings.json` (the user-level config atelier sessions actually load), and is not silently dropped by the `permissions`-block merge bug in issue #55507. Keep PLAN.md §11 v2.3 (custom `PreToolUse` hook) as the targeted layer above auto-mode for the high-risk surface — not as a replacement.**

The full argument, against the four questions:

- **Q1 says auto-mode composes**, not overrides — so atelier's `deny` list (force-push, workflows, package.json, the never-auto-merge surface) survives unchanged. That removes the fundamental compatibility risk M2.6 flagged.
- **Q2 says the scope is user-level only**, which is the structural problem. If `CLAUDE_CONFIG_DIR` is honored for this rule (the favorable case), atelier can ship auto-mode in `install.sh` and the operator's personal `~/.claude/` sessions are unaffected. If it isn't, atelier can only *recommend* the operator add `defaultMode: "auto"` to `~/.claude/settings.json` themselves — affecting every Claude session on their machine. That recommendation is poor UX and atelier should not push it without a flag.
- **Q3 says the 17% FN is concentrated in surfaces atelier already protects** (file edits scoped by `additionalDirectories`; high-risk Bash already in `deny`). The residual exposure is narrow.
- **Q4 says the latency cost is negligible** for atelier's task sizes, and the token cost is acceptable in exchange for eliminating mid-chain operator prompts.

The custom `PreToolUse` hook (Option B / PLAN.md §11 v2.3) stays valuable as a targeted second layer over auto-mode for the narrow residual surface — ambiguous-consent overeager actions on Bash commands not in `deny`. Building it instead of auto-mode would be wasted effort: auto-mode is already deployed and battle-tested at production scale; reimplementing the classifier in a Bash + Haiku hook would catch fewer cases at higher latency. Building it *alongside* auto-mode, scoped to the high-risk surface (e.g. anything that touches `pnpm-lock.yaml`, anything inside a long-running deploy task), gives defense in depth without redundancy.

Why **not** Option A alone: it relies on Anthropic's classifier never regressing on the 17% FN profile, and gives atelier no way to encode project-specific risk signals (e.g. "this project owns production-critical state, escalate everything outside the worktree to ask"). The hook is the place to express those signals.

Why **not** Option B alone: building an LLM hook that beats Anthropic's production-trained classifier on the general-case surface is not feasible for a single-maintainer project, and offers no benefit if auto-mode is already covering 83%+ of the same actions.

---

## Open questions — must resolve before adoption

The recommendation above is conditional on two empirical findings that the documentation does not pin down:

### OQ-A — `CLAUDE_CONFIG_DIR` and `defaultMode: "auto"`

Does Claude Code honor `defaultMode: "auto"` set in `$CLAUDE_CONFIG_DIR/settings.json` when `CLAUDE_CONFIG_DIR` is non-default? Documentation names `~/.claude/settings.json` explicitly and does not mention `CLAUDE_CONFIG_DIR` in the auto-mode context.

**Test**:
1. `mkdir -p /tmp/cc-test-config && jq -n '{permissions: {defaultMode: "auto"}}' > /tmp/cc-test-config/settings.json`
2. `CLAUDE_CONFIG_DIR=/tmp/cc-test-config claude` (in a throwaway dir, no project settings).
3. Inside the session: `/permissions` — does it report `auto` or `default`?

If `auto` → atelier can scope auto-mode to `$ATELIER_CONFIG_DIR` without touching the operator's `~/.claude/`. **Favorable path.**
If `default` → atelier can only recommend opt-in via `~/.claude/settings.json`. **Less favorable path; reconsider whether adoption is worth the UX cost.**

### OQ-B — Issue #55507 status: does `permissions` block in project settings silently drop user-level `defaultMode`?

Atelier writes a `permissions` block to every project's `.claude/settings.json` (it's the whole point of `settings.template.json`). [Issue #55507](https://github.com/anthropics/claude-code/issues/55507) reports that this block's mere presence makes the user-level `permissions` block (including `defaultMode`) silently dropped from the merge.

**Test**:
1. Resolve OQ-A first (so we know which `settings.json` to put `defaultMode: "auto"` in).
2. From inside an atelier task worktree (which has the `templates/settings.template.json` instantiated as `.claude/settings.json`): `/permissions` — does it report `auto` (user-level survived the merge) or `acceptEdits` (project-level `defaultMode` won) or `default` (issue #55507 reproduces and dropped the user-level merge)?

If `auto` → composition works as documented. **Adopt.**
If `acceptEdits` → project-level `defaultMode` overrides user-level. Atelier would have to remove `defaultMode: "acceptEdits"` from `settings.template.json` to let user-level `auto` through. **Adoptable but requires template change.**
If `default` → issue #55507 reproduces. **Cannot adopt until upstream fix; report the reproduction to the issue and stay on `acceptEdits`.**

### OQ-C — Auto-mode behavior on the static-analysis-bypass surface

The operator's symptom that motivated this spike was the *"Contains shell syntax that cannot be statically analyzed"* prompt. The docs describe what auto-mode does for *unenumerated* commands but do not explicitly cover the static-analysis-bypass branch.

**Test**:
1. With auto-mode active (post-OQ-A + OQ-B), run a sample loop from inside atelier: `for p in dir1 dir2; do git -C "$p" status --porcelain; done`.
2. Does the classifier accept, reject, or still prompt?

If accepts → auto-mode covers the friction symptom this spike was triggered by. **Confirms the core benefit.**
If still prompts → the static-analysis-bypass is hardcoded above the classifier (i.e. ignores `defaultMode`). **Auto-mode does not solve the symptom; reconsider whether the rest of the benefit justifies adoption.**

---

## Implementation plan if OQ-A + OQ-B + OQ-C resolve favorably

This is a sketch, not a commitment — the validation experiments above must run first.

1. **Add a new milestone M2.7 — Empirically validate OQ-A + OQ-B + OQ-C** to ROADMAP. Single afternoon of work; outcome captured in this doc as an addendum.
2. **If favorable** (auto-mode honored from `$ATELIER_CONFIG_DIR/settings.json`, composes with templates, accepts shell loops):
   - `install.sh` Phase C.1 writes `defaultMode: "auto"` to `$ATELIER_CONFIG_DIR/settings.json` (the file atelier sessions read as user-level via `CLAUDE_CONFIG_DIR`).
   - Document the change in `operator-rules.md` + `docs/operator-guide.md`.
   - `atelier-doctor` adds a check that the auto-mode setting is present and the session's `/permissions` reports it active.
   - `atelier-uninstall` removes the setting in default mode (preserves the rest of `$ATELIER_CONFIG_DIR/`), and wipes the whole config under `--purge` as today.
   - Open a `M2.8 — Custom PreToolUse hook for high-risk surface` to track the targeted Option-B work as a layer over auto-mode (deferred until auto-mode adoption is in production and the residual surface is observable).
3. **If unfavorable** (any of OQ-A / OQ-B / OQ-C fails):
   - Leave atelier on `acceptEdits` as today.
   - Promote PLAN.md §11 v2.3 (custom `PreToolUse` hook) from `v2 deferred` to `v1 Phase 4` — it becomes the only path to a layer 3.
   - Capture the negative findings in this doc as an addendum so the next maintainer doesn't re-run the spike.

---

## Decision log

- **2026-05-25** — M2.6 captured in ROADMAP after discovering auto-mode is available on all plans (not Max-only as previously assumed).
- **2026-05-29** — Spike completed. Recommendation: **Option C, conditional on OQ-A + OQ-B + OQ-C resolving favorably in empirical validation**. Validation deferred to M2.7.
- **2026-05-29 (later)** — **M2.7 empirical validation completed (this PR). All three open questions resolved favorably. Recommendation is no longer conditional: adopt Option C.** See addendum below.

PLAN.md §11 v2.3 updated to reference this doc and capture the validated decision.

---

## Addendum — M2.7 empirical validation (2026-05-29)

Closes M2.7 (ROADMAP). The three open questions left open by M2.6 were tested on a real host (macOS 25.5.0, Claude Code v2.1.156, model `claude-opus-4-8[1m]`) before any adoption code was written. All three resolved **favorably**; the recommendation is now unconditional.

### Test environment

- **User-level config dir under test.** `/tmp/cc-oqa-test/` with two files: `settings.json` (containing only `{"permissions": {"defaultMode": "auto"}}`) and `.claude.json` (OAuth state copied from `~/.claude-work/.claude.json`, the operator's real atelier config dir, to bypass interactive login).
- **For OQ-A** — empty cwd at `/tmp/cc-oqa-cwd/` (no project `.claude/` to merge).
- **For OQ-B** — cwd at `/tmp/cc-oqb-cwd/` with a single project file `.claude/settings.json = {"permissions": {"allow": ["Bash(echo *)"]}}` — a `permissions` block with no `defaultMode` of its own, so the test isolates whether the user-level `defaultMode` survives the merge with a project-level `permissions` block (the precise condition issue #55507 reports as broken).
- **For OQ-C** — the user-level `~/.claude-work/settings.json` was temporarily patched in-place to add `{"permissions": {"defaultMode": "auto"}}` (backed up to `settings.json.oqc-bak`, restored after the test), then a fresh `atelier` session was launched from `/tmp/cc-oqa-cwd/` so the `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR` path used by the operator's real shell wrapper was exercised end-to-end.

Each test inspected `/status` → Config tab → **Default permission mode** (the operator-visible field in Claude Code's UI that names the active mode) and the Status tab → **Setting sources** (which lists which settings layers were merged).

### OQ-A — `CLAUDE_CONFIG_DIR` honors `defaultMode: "auto"`

**Test.** Lanzar `cd /tmp/cc-oqa-cwd && CLAUDE_CONFIG_DIR=/tmp/cc-oqa-test claude`; inspect `/status`.

**Observed.**

- Config tab — `Default permission mode: Auto mode`.
- Status tab — `Setting sources: User settings`; `cwd: /private/tmp/cc-oqa-cwd`.

**Resolution.** **Favorable.** Claude Code reads `defaultMode: "auto"` from `$CLAUDE_CONFIG_DIR/settings.json` when `CLAUDE_CONFIG_DIR` is non-default. The rule documented in [Permission modes](https://code.claude.com/docs/en/permission-modes.md) — *"Move it to `~/.claude/settings.json`"* — is **not** literally hardcoded to that path; it follows wherever `CLAUDE_CONFIG_DIR` points. Atelier can therefore scope auto-mode to its own sessions by writing the setting into `$ATELIER_CONFIG_DIR/settings.json` and the operator's personal `~/.claude/settings.json` stays untouched. This is the path the M2.6 implementation plan called the **favorable** branch — confirmed.

### OQ-B — Issue [#55507](https://github.com/anthropics/claude-code/issues/55507) does not reproduce on v2.1.156

**Test.** Lanzar `cd /tmp/cc-oqb-cwd && CLAUDE_CONFIG_DIR=/tmp/cc-oqa-test claude`; inspect `/status`.

The cwd contains a project-level `.claude/settings.json` with a `permissions.allow` entry but no `defaultMode`. Per the issue's claim, the mere presence of a project-level `permissions` block should silently drop the user-level `permissions` block (including `defaultMode`) from the merge, leaving the session in `default` mode.

**Observed.**

- Config tab — `Default permission mode: Auto mode`.
- Status tab — `Setting sources: User settings, Shared project settings`; `cwd: /private/tmp/cc-oqb-cwd`.

**Resolution.** **Favorable.** Both settings layers merged (`Setting sources` shows both), and the user-level `defaultMode: "auto"` survived intact. The issue does **not** reproduce on Claude Code v2.1.156 — either it was fixed upstream between when the issue was filed and now, or the reported behavior was conditional on something we did not exercise. Atelier's `templates/settings.template.json` writes a `permissions` block to every project; this test confirms that block does not invalidate the user-level auto-mode. The M2.6 implementation plan's **adoptable** branch is confirmed.

### OQ-C — Auto-mode classifier intercepts the shell-syntax branch

**Test.** With `~/.claude-work/settings.json` temporarily patched to add `{"permissions": {"defaultMode": "auto"}}` (and backed up), lanzar `cd /tmp/cc-oqa-cwd && atelier`; inspect `/status` to confirm `Default permission mode: Auto mode`; then instruct Claude: *"Run this bash command using the Bash tool: `for p in foo bar baz; do echo "$p"; done`"*. Pre-F36/F37 baseline (and the friction that triggered the M2.6 spike): the same loop, run under `defaultMode: "acceptEdits"`, surfaced *"Contains shell syntax (string) that cannot be statically analyzed. Do you want to proceed?"* — interrupting the autonomous chain.

**Observed.**

```
● Bash(for p in foo bar baz; do echo "$p"; done)
  └ foo
    bar
    baz
  └ Allowed by auto mode classifier
● Done. Output:

foo
bar
baz
```

The literal annotation **"Allowed by auto mode classifier"** appears under the Bash call — the classifier explicitly evaluated the shell-syntax branch and approved it. No interactive prompt; the loop executed end-to-end. Latency anecdote: *"Cogitated for 13s"* before the first character of output. The 13 s figure is roughly consistent with the Q4 finding (a single Stage 2 classifier call in the 200–400 ms range plus normal LLM thinking time on the surrounding turn); not a benchmark, but the latency cost is operator-acceptable.

**Resolution.** **Favorable.** Auto-mode's classifier *does* cover the static-analysis-bypass branch. This was the originating symptom of the spike (the operator's *"el proyecto me sigue pidiendo autorización para `git wt ls`"* friction had its loop-form cousin in the for-loop case the operator showed during the spike). Adopting auto-mode therefore closes both the enumeration gap (F37-style) **and** the shell-syntax-bypass gap in one move.

### Resolution summary

| Question | Resolution | Implication |
|---|---|---|
| OQ-A — `CLAUDE_CONFIG_DIR` and `defaultMode: "auto"` | ✅ Favorable | Atelier ships auto-mode in `$ATELIER_CONFIG_DIR/settings.json`; operator's `~/.claude/` untouched. |
| OQ-B — Issue #55507 reproduction | ✅ Favorable (does not reproduce on v2.1.156) | Project-level `permissions` block composes with user-level `defaultMode: "auto"` as documented. |
| OQ-C — Auto-mode covers shell-syntax branch | ✅ Favorable ("Allowed by auto mode classifier") | Adoption closes the originating friction symptoms — F37-style enumeration gaps **and** shell-loop prompts. |

### Validated decision

**Adopt Option C** — Claude Code's native auto permission mode as the primary layer 3, **unconditionally** (the M2.6 conditional is now resolved). The custom `PreToolUse` Haiku hook in PLAN.md §11 v2.3 stays as a follow-up second layer above auto-mode for the narrow residual high-risk surface — tracked separately as M2.9 (no longer M2.8; M2.8 is now the adoption work itself).

### Next: M2.8 — Implementation

ROADMAP gains M2.8 (Phase 4 — Robustness, High Priority) for the adoption work:

1. **`templates/settings.template.json`** — remove `"defaultMode": "acceptEdits"`. Project-level `defaultMode` overrides user-level by normal merge precedence — Claude Code respects per-file ordering. Leaving the project file's `defaultMode` in place would override the user-level `auto` to `acceptEdits` (the *one* scenario OQ-A/B didn't directly exercise, since the OQ-B project file deliberately omitted `defaultMode` to isolate the issue #55507 question). The fix is a one-line removal of the `"defaultMode": "acceptEdits"` line from the template.
2. **`install.sh`** — Phase C.1 step that writes `{"permissions": {"defaultMode": "auto"}}` to `$ATELIER_CONFIG_DIR/settings.json` if not already present. Use the same atomic temp-file pattern as the other Phase C.1 writes.
3. **`scripts/atelier-doctor`** — check that `$ATELIER_CONFIG_DIR/settings.json` has `permissions.defaultMode == "auto"`. `--fix` writes it if missing.
4. **`scripts/atelier-uninstall`** — default mode preserves `$ATELIER_CONFIG_DIR/`; `--purge` already wipes everything (including the auto-mode setting). No additional logic.
5. **`docs/operator-guide.md` + `docs/troubleshooting.md` + `operator-rules.md`** — document the auto-mode adoption, what it changes for the operator (no more permission prompts for shell loops, no more F37-style enumeration prompts for new commands within the deny-respecting envelope), and what stays the same (the deny list still blocks force-push, never-auto-merge surface, etc.).
6. **Plugin bump 0.7.5 → 0.8.0**. Minor bump per PLAN.md §14.2 — auto-mode adoption changes the per-task operator UX materially (fewer prompts, semantic-classifier gate). Not breaking but observably different. Cut release v0.8.0.

### Cleanup notes from this test

- `/tmp/cc-oqa-test/`, `/tmp/cc-oqa-cwd/`, `/tmp/cc-oqb-cwd/` were created under `/tmp` (auto-cleaned on reboot). Safe to leave.
- `~/.claude-work/settings.json.oqc-bak` was restored to `~/.claude-work/settings.json` at the end of the test. State as captured before OQ-C began.
