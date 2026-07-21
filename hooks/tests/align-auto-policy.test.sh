#!/usr/bin/env bash
#
# Regression test for #30 — /atelier:align auto-policy awareness.
#
# Asserts that `commands/align.md` encodes the auto-policy contract introduced
# in #30 so that a future careless edit that silently drops or contradicts these
# invariants fails CI.
#
# Contract invariants asserted:
#   Group 1 — Policy awareness (Step 1b reads effective policy per member)
#     - Step 1b section present in the command
#     - decisionPolicyDefault field consulted from survey --json output
#     - policy <pol> line consulted from human plan output
#     - decisionPolicy.default referenced by name in policy definitions
#     - "effective policy" concept present
#     - per-member (not global) evaluation stated
#     - Post-Tier-1 override present for same-run --policy auto
#   Group 2 — Conditional gates (no unconditional Tier-3 AskUserQuestion)
#     - Step 2 confirmation gate is conditional on ask policy
#     - Step 2 auto path explicitly skips the confirmation gate
#     - Step 4 Tier-3 ask (interactive) section present
#     - Step 4 Tier-3 auto (autonomous) section present
#     - Unconditional "Never push to or merge" hard rule absent (rule is now ask-scoped)
#   Group 3 — delegated author->review->merge sequence under auto
#     - align delegates the whole sequence to task-orchestrator (mode: non-task-pr)
#     - the orchestrator (not align) dispatches pr-opener -> reviewer -> auto-merge
#     - post-merge: git pull --ff-only fast-forwards operator's local checkout
#     - fast-forward is described as a local pull only (no base-branch push)
#     - a held terminal state is surfaced-and-stopped, not bypassed
#   Group 4 — Spurious permission suggestion absent
#     - align never runs gh pr merge in its own session (permission-deflection intent)
#     - allowed-tools frontmatter does not enumerate a Bash(gh pr merge grant
#     - off-spec AskUserQuestion prohibition for reviewing/merging under auto present
#   Group 5 — ask path preserved (no-regression)
#     - AskUserQuestion offer for the PR still present under ask
#     - never merge under ask: operator merges on their own timeline
#     - print exact per-repo commands on decline (ask path only)
#   Group 6 — Orthogonality: ATELIER_AUTO/--yes is dry-run, not auto autonomy
#     - headless flag described as dry-run / preview path
#     - headless flag described as orthogonal to decisionPolicy
#     - ATELIER_AUTO + align always previews and applies nothing, even with auto policy
#
# Hermetic: greps committed prose only; no network, no jq, no temp dirs.
#
# Run:  hooks/tests/align-auto-policy.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALIGN_MD="$REPO_ROOT/commands/align.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
# Passes when the fixed string is present in the file; fails otherwise.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label>
# Passes when the fixed string is ABSENT from the file; fails otherwise.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------------
# Group 1: Policy awareness — Step 1b reads effective policy per member
# ---------------------------------------------------------------------------

chk_prose "$ALIGN_MD" '## Step 1b — resolve effective policy per member' \
  "policy-awareness: Step 1b section present in command"

chk_prose "$ALIGN_MD" 'decisionPolicyDefault' \
  "policy-awareness: decisionPolicyDefault field consulted from survey --json output"

chk_prose "$ALIGN_MD" 'policy <pol>' \
  "policy-awareness: policy <pol> line consulted from human plan output"

chk_prose "$ALIGN_MD" 'decisionPolicy.default' \
  "policy-awareness: decisionPolicy.default referenced by name in policy definitions"

chk_prose "$ALIGN_MD" 'effective policy' \
  "policy-awareness: effective policy concept present"

chk_prose "$ALIGN_MD" 'per-member' \
  "policy-awareness: per-member (not global) evaluation stated"

chk_prose "$ALIGN_MD" '**Post-Tier-1 override:**' \
  "policy-awareness: Post-Tier-1 override present for same-run --policy auto"

# ---------------------------------------------------------------------------
# Group 2: Conditional gates — no unconditional Tier-3 AskUserQuestion
# ---------------------------------------------------------------------------

chk_prose "$ALIGN_MD" '**Under `ask` policy:** confirm with `AskUserQuestion`' \
  "conditional-gate: Step 2 confirmation gate is conditional on ask policy"

chk_prose "$ALIGN_MD" '**Under `auto` policy:** skip the confirmation gate' \
  "conditional-gate: Step 2 auto path explicitly skips the confirmation gate"

chk_prose "$ALIGN_MD" '### Tier 3 under `ask` (interactive)' \
  "conditional-gate: Step 4 Tier-3 ask (interactive) section present"

chk_prose "$ALIGN_MD" '### Tier 3 under `auto` (autonomous)' \
  "conditional-gate: Step 4 Tier-3 auto (autonomous) section present"

# The old unconditional hard rule said "**Never** push to or merge a base branch"
# without a policy qualifier. It is now "**Under `ask`: never push to or merge"
# (lowercase, ask-scoped). Assert the bare unconditional capital-N form is gone.
chk_absent "$ALIGN_MD" '**Never** push to or merge' \
  "conditional-gate: unconditional Never-push-to-or-merge hard rule absent (now ask-scoped only)"

# ---------------------------------------------------------------------------
# Group 3: reviewer -> auto-merge -> base-pull sequence under auto
# ---------------------------------------------------------------------------

chk_prose "$ALIGN_MD" 'mode: non-task-pr' \
  "auto-sequence: align delegates via mode: non-task-pr"

chk_prose "$ALIGN_MD" 'task-orchestrator' \
  "auto-sequence: task-orchestrator agent named as the delegation target"

chk_prose "$ALIGN_MD" 'The orchestrator — not align — dispatches `pr-opener` → `reviewer` → the' \
  "auto-sequence: orchestrator (not align) dispatches pr-opener -> reviewer -> auto-merge"

chk_prose "$ALIGN_MD" 'git -C <repo> pull --ff-only' \
  "auto-sequence: git pull --ff-only command present for local fast-forward"

chk_prose "$ALIGN_MD" '**local pull only**' \
  "auto-sequence: fast-forward is a local pull only (no push to base branch)"

chk_prose "$ALIGN_MD" '**delegated, but held on branch-protection**' \
  "auto-sequence: held terminal state is surfaced as delegated-but-held, not bypassed"

# ---------------------------------------------------------------------------
# Group 4: Spurious permission suggestion absent
# ---------------------------------------------------------------------------

chk_prose "$ALIGN_MD" 'Align never runs `gh pr merge` in its own session and does not need it' \
  "permission-deflection: hard rule stating align never runs/needs gh pr merge in its own session is present"

# allowed-tools is now an enumerated minimum-necessary list (no blanket
# Bash(gh:*)). The spurious improvisation this guards against is enumerating a
# Bash(gh pr merge:*) grant directly in that list — merging is delegated to
# task-orchestrator -> auto-merge, which runs under per-worktree settings
# (Bash(gh pr merge*) lives in templates/settings.template.json, not here).
# Scope the check to the allowed-tools frontmatter line itself, since the Hard
# rules prose now legitimately references `Bash(gh pr merge*)` when describing
# where that grant actually lives.
ALLOWED_TOOLS_LINE="$(grep -m1 '^allowed-tools:' "$ALIGN_MD")"
if printf '%s' "$ALLOWED_TOOLS_LINE" | grep -qF 'Bash(gh pr merge'; then
  fail "permission-deflection: allowed-tools frontmatter enumerates a Bash(gh pr merge grant — should be absent"
else
  pass "permission-deflection: allowed-tools frontmatter does not enumerate a Bash(gh pr merge grant"
fi

chk_prose "$ALIGN_MD" '**Under `auto`, never emit an off-spec `AskUserQuestion` about reviewing or' \
  "permission-deflection: prohibition on off-spec AskUserQuestion about reviewing/merging under auto present"

# ---------------------------------------------------------------------------
# Group 5: ask path preserved (no-regression)
# ---------------------------------------------------------------------------

chk_prose "$ALIGN_MD" '**Offer** (via `AskUserQuestion`) to open the PR for each repo' \
  "ask-regression: AskUserQuestion PR offer still present under ask path"

chk_prose "$ALIGN_MD" 'the operator merges on their own timeline' \
  "ask-regression: never merge under ask — operator merges on own timeline"

chk_prose "$ALIGN_MD" 'print exact per-repo commands if they decline the PR offer' \
  "ask-regression: print exact per-repo commands on decline (ask path)"

# ---------------------------------------------------------------------------
# Group 6: Orthogonality — ATELIER_AUTO/--yes is dry-run, not auto autonomy
# ---------------------------------------------------------------------------

chk_prose "$ALIGN_MD" '**dry-run / preview**' \
  "orthogonality: headless flag described as dry-run / preview path"

chk_prose "$ALIGN_MD" '**orthogonal** to' \
  "orthogonality: headless flag described as orthogonal to decisionPolicy"

# This token is on a single line in the Hard rules section (line ~142) and
# confirms ATELIER_AUTO applies nothing even when every member's policy is auto.
chk_prose "$ALIGN_MD" '`ATELIER_AUTO + align` always previews and applies nothing, even when every' \
  "orthogonality: ATELIER_AUTO + align always previews even with every member auto"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "align-auto-policy (#30): all assertions passed."
  exit 0
else
  echo "align-auto-policy (#30): $fails assertion(s) failed."
  exit 1
fi
