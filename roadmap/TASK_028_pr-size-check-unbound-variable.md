# TASK_028 — `atelier-pr-size-check` aborts under `set -u` (`repo_flag[@]` unbound) and counts 0/0 in PR mode

**Type:** `bug` · **Priority:** P2 · **Estimate:** `~TODO`

**Problem.** In PR mode, `scripts/atelier-pr-size-check` prints `repo_flag[@]: unbound variable` and then reports **0 lines / 0 files** — its `gh` invocation appears to abort under `set -u` (an array referenced with `"${repo_flag[@]}"` while empty/unset) before it fetches the diff. Surfaced 2026-06-23 by the `reviewer` agent while gating PR #236.

**Impact.** The auto-merge size guardrail (PLAN.md §6 / `skills/auto-merge`) relies on this script to detect oversize PRs (`>200 lines` AND `>10 files` after exemptions). When the script silently counts 0/0, the size guardrail can **never trip in PR mode** — an oversize PR could pass the size axis on a false 0/0 reading. (On #236 the gate cleared on the file-count axis regardless, so the bad reading was harmless there — but it would misreport on a genuinely large PR.)

**Scope (sketch).**
- Reproduce: run `scripts/atelier-pr-size-check` in PR mode against a real PR with `set -u` active; confirm the `repo_flag[@]: unbound variable` abort and the 0/0 output.
- Fix the empty-array expansion (e.g. `"${repo_flag[@]+"${repo_flag[@]}"}"` or initialise `repo_flag=()`), so the `gh` diff fetch runs and real line/file counts are returned.
- Add a hermetic `hooks/tests/*.test.sh` asserting PR mode returns a non-zero count for a fixture diff and does not emit an unbound-variable error under `set -u`.

**Acceptance.** `atelier-pr-size-check` in PR mode returns the true line/file counts (no `unbound variable`, no false 0/0) under `set -u`, so the auto-merge size guardrail evaluates correctly on large PRs. Covered by a regression test in the structural suite.
