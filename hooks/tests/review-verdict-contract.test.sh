#!/usr/bin/env bash
#
# Regression test for #436 (unit #407b) — the reviewer publishes its verdict
# as a head-sha-bound COMMENTED review by default; `--approve` is opt-in
# (`autoMerge.reviewerApprovalMode: "approve"`).
#
# Contract asserted (prose + JSON; the helper that parses the verdict,
# `atelier-review-verdict`, has its own test from #407a):
#   - agents/reviewer.md: v1 marker + Decision/Head/Auto-merge block, default
#     `verdict` mode posts `--comment` via `--body-file .task-log/tmp/review-body.md`,
#     a denied `--approve` is terminal (never re-posted as a comment), and the
#     old "degrade to an advisory comment on denial" fallback is gone.
#   - templates/atelier.template.json + .atelier.json: three modes, default "verdict".
#   - agents/task-orchestrator.md: `verdict: approve (<sha>)` status, and
#     classifier-blocked scoped to approve mode.
#   - PLAN.md / operator-rules.md / CLAUDE.md mention the verdict mechanism.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REVIEWER="$REPO_ROOT/agents/reviewer.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
TEMPLATE_JSON="$REPO_ROOT/templates/atelier.template.json"
ATELIER_JSON="$REPO_ROOT/.atelier.json"
PLAN="$REPO_ROOT/PLAN.md"
OPRULES="$REPO_ROOT/operator-rules.md"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label> — passes when present.
chk_prose() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 — token '$2' not found in $1"; fi
}
# chk_absent <file> <fixed-string> <label> — passes when absent.
chk_absent() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then fail "$3 — stale token '$2' still in $1"; else pass "$3"; fi
}
# chk_jq <file> <jq-filter> <expected> <label>
chk_jq() {
  local got
  got="$(jq -r "$2" "$1" 2>/dev/null)"
  if [ "$got" = "$3" ]; then pass "$4"; else fail "$4 — got '$got', expected '$3' ($1)"; fi
}

echo "== agents/reviewer.md =="
chk_prose "$REVIEWER" '<!-- atelier-reviewer-verdict/v1 -->' "reviewer: v1 verdict marker"
chk_prose "$REVIEWER" 'Decision: approve | request-changes' "reviewer: Decision line in verdict block"
chk_prose "$REVIEWER" 'Head: <40-hex head sha diffed>' "reviewer: Head (40-hex sha) line in verdict block"
chk_prose "$REVIEWER" 'Auto-merge: yes | no' "reviewer: Auto-merge line in verdict block"
chk_prose "$REVIEWER" 'absent field → `"verdict"`' "reviewer: absent mode defaults to verdict"
chk_prose "$REVIEWER" '`reviewerApprovalMode: "verdict"` (default)' "reviewer: verdict mode is the default"
chk_prose "$REVIEWER" 'gh pr review <NN> --comment --body-file <worktree>/.task-log/tmp/review-body.md' \
  "reviewer: verdict mode posts --comment via --body-file .task-log/tmp/review-body.md"
chk_prose "$REVIEWER" 'gh pr review <NN> --approve --body-file <worktree>/.task-log/tmp/review-body.md' \
  "reviewer: approve mode still documents --approve via --body-file"
chk_prose "$REVIEWER" '`reviewerApprovalMode: "approve"`** (opt-in' "reviewer: approve mode is opt-in"
chk_prose "$REVIEWER" '`reviewerApprovalMode: "advisory"`' "reviewer: advisory mode documented"
chk_prose "$REVIEWER" 'Auto-merge: no — advisory mode' "reviewer: advisory mode never auto-merges"
chk_prose "$REVIEWER" 'never** retry the denied `--approve` as a `--comment` review' \
  "reviewer: never retry a denied --approve as a comment"
chk_prose "$REVIEWER" 'the denial is **terminal**' "reviewer: approve-mode denial is terminal"
chk_prose "$REVIEWER" 'Return `classifier-blocked` with the denial tag verbatim' \
  "reviewer: denial returns classifier-blocked verbatim"
# Old fallback wording (pre-#407b): denial degraded to an advisory comment.
chk_absent "$REVIEWER" 'Instead, degrade to an advisory comment carrying the exact same body' \
  "reviewer: old degrade-to-comment-on-denial fallback removed"
chk_absent "$REVIEWER" 'Degrade to the advisory `--comment` review and return `classifier-blocked`' \
  "reviewer: old 'designed fallback' rule removed"
chk_absent "$REVIEWER" 'absent field → `"approve"`' "reviewer: old approve default removed"

echo "== templates/atelier.template.json + .atelier.json =="
for f in "$TEMPLATE_JSON" "$ATELIER_JSON"; do
  rel="${f#"$REPO_ROOT"/}"
  chk_jq "$f" '.autoMerge.reviewerApprovalMode' 'verdict' "$rel: reviewerApprovalMode default is \"verdict\""
  for m in verdict approve advisory; do
    if jq -r '.autoMerge._comment' "$f" 2>/dev/null | grep -qF "\"$m\""; then
      pass "$rel: _comment enumerates mode \"$m\""
    else
      fail "$rel: _comment does not enumerate mode \"$m\""
    fi
  done
done
chk_prose "$TEMPLATE_JSON" 'atelier-reviewer-verdict/v1' "template: _comment names the v1 marker"

echo "== agents/task-orchestrator.md =="
chk_prose "$ORCH" 'verdict: approve (<sha>)' "orchestrator: reports 'verdict: approve (<sha>)'"
chk_prose "$ORCH" 'This only occurs in `autoMerge.reviewerApprovalMode: "approve"` mode' \
  "orchestrator: classifier-blocked scoped to approve mode"
chk_prose "$ORCH" 'atelier-review-verdict' "orchestrator: sha comes from atelier-review-verdict"
chk_prose "$ORCH" 'held: reviewer approval blocked by auto-mode classifier — human merge required' \
  "orchestrator: held surface string preserved"

echo "== PLAN.md / operator-rules.md / CLAUDE.md =="
chk_prose "$PLAN" 'head-sha-bound verdict review' "PLAN.md: gate describes head-sha-bound verdict review"
chk_prose "$PLAN" 'This applies to `approve` mode only (#407b)' "PLAN.md: classifier-blocked scoped to approve mode"
chk_prose "$PLAN" 'never re-posts the denied approval as a comment' "PLAN.md: denied approval never re-posted"
chk_prose "$OPRULES" 'atelier-reviewer-verdict/v1' "operator-rules.md: names the v1 marker"
chk_prose "$OPRULES" '`autoMerge.reviewerApprovalMode: "approve"` only' "operator-rules.md: self-approval veto scoped to approve mode"
chk_prose "$OPRULES" 'never re-posted as a comment' "operator-rules.md: denial never re-posted"
chk_prose "$CLAUDE_MD" 'head-sha-bound verdict review' "CLAUDE.md: gate line names the verdict review"
chk_prose "$CLAUDE_MD" 'atelier-review-verdict' "CLAUDE.md: gate line names atelier-review-verdict"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "review-verdict-contract (#436): all assertions passed."
  exit 0
else
  echo "review-verdict-contract (#436): $fails assertion(s) failed."
  exit 1
fi
