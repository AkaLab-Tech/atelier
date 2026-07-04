#!/usr/bin/env bash
#
# Regression test for #43 / #44c — /atelier:release independent-chain contract.
#
# Asserts that `commands/release.md` encodes the invariants that keep the
# release bump PR off the command's own turn, so a future careless edit that
# silently drops or contradicts these invariants fails CI.
#
# #44c retarget: the implementer collapsed the old two-dispatch shape (a
# `pr-author` Task dispatch immediately followed by a separate `reviewer`
# Task dispatch, both from this command's own turn) into a single step-7
# `task-orchestrator` dispatch that owns the whole author -> review -> merge
# coordination one level down (mirroring `/atelier:align`'s Tier 3 `auto`
# delegation). Group 2 below is retargeted accordingly, with `chk_absent`
# guards on the old self-coordination tokens so a regression that reintroduces
# same-turn author+review re-fails this test.
#
# Contract invariants asserted:
#   Group 1 — This command never authors/reviews/merges the bump PR itself,
#             and delegates the whole coordination to task-orchestrator
#     - top-of-file statement that the command never authors/reviews/merges
#       the bump PR from its own turn
#     - matching hard-refusal restatement
#     - top-of-file delegation framing names task-orchestrator and
#       "non-task PR coordination mode"
#     - hard-refusal: never dispatch pr-author/reviewer/auto-merge from this
#       command's own turn — the coordination is delegated to task-orchestrator
#   Group 2 — Author -> review -> merge coordination is ONE delegated Task
#             dispatch to task-orchestrator, not two separate same-turn calls
#     - step 7 header is the single task-orchestrator delegation dispatch
#     - the briefing carries mode: non-task-pr
#     - the briefing carries the author_agent: pr-author hint
#     - OLD tokens (separate pr-author/reviewer Task dispatches from this
#       command's own turn, "two separate calls") are ABSENT — a regression
#       reintroducing same-turn author+review must re-fail this test
#   Group 3 — The annotated tag is pushed only AFTER merge
#     - step 8 (renumbered) is headed "only after merge"
#     - inline "never push the tag before this point" instruction
#     - hard-refusal restatement anchored on task-orchestrator confirming merge
#     - the held/unmerged terminal state also forbids pushing a tag
#   Group 4 — The release branch is task/release-* shaped, never release/*/hotfix/*
#     - step 5 names the branch task/release-<next_version> and forbids release/*|hotfix/*
#     - hard-refusal restatement forbidding release/*|hotfix/*
#
# Hermetic: greps committed prose only; no network, no jq, no temp dirs.
#
# Run:  hooks/tests/release-independent-chain.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_MD="$REPO_ROOT/commands/release.md"

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

[ -f "$RELEASE_MD" ] || { echo "  FAIL: $RELEASE_MD not found"; exit 1; }

# ---------------------------------------------------------------------------
# Group 1: This command never authors/reviews/merges the bump PR itself, and
# delegates the whole coordination to task-orchestrator
# ---------------------------------------------------------------------------

chk_prose "$RELEASE_MD" \
  '**This command never authors, reviews, or merges the bump PR from its own turn.**' \
  "own-turn: top-of-file statement the command never authors/reviews/merges the bump PR"

chk_prose "$RELEASE_MD" \
  "**Never** author, review, or merge the bump PR from this command's own turn." \
  "own-turn: hard-refusal restates never author/review/merge from own turn"

chk_prose "$RELEASE_MD" \
  'This command delegates the whole author→review→merge coordination to `task-orchestrator` (non-task PR coordination mode)' \
  "delegation: top-of-file framing names task-orchestrator and non-task PR coordination mode"

chk_prose "$RELEASE_MD" \
  "**Never** dispatch \`pr-author\`, \`reviewer\`, or \`auto-merge\` from this command's own turn" \
  "delegation: hard-refusal — never dispatch pr-author/reviewer/auto-merge from this command's own turn"

# ---------------------------------------------------------------------------
# Group 2: Author -> review -> merge coordination is ONE delegated Task
# dispatch to task-orchestrator, not two separate same-turn calls
# ---------------------------------------------------------------------------

chk_prose "$RELEASE_MD" \
  '### 7. Delegate author → review → merge coordination — `task-orchestrator` dispatch (`Task`)' \
  "delegated-dispatch: step 7 is the single task-orchestrator coordination dispatch"

chk_prose "$RELEASE_MD" \
  'mode: non-task-pr' \
  "delegated-dispatch: step 7 briefing carries mode: non-task-pr"

chk_prose "$RELEASE_MD" \
  'author_agent: pr-author' \
  "delegated-dispatch: step 7 briefing carries the author_agent: pr-author hint"

# Regression guards: the OLD same-turn two-dispatch shape must be gone. A
# careless edit that reintroduces a same-turn pr-author + reviewer pairing
# must re-fail this test.
chk_absent "$RELEASE_MD" \
  '`pr-author` dispatch (`Task`, separate from step 8)' \
  "delegated-dispatch: OLD same-turn pr-author dispatch header is absent"

chk_absent "$RELEASE_MD" \
  'Independent review — `reviewer` dispatch (`Task`, separate from step 7)' \
  "delegated-dispatch: OLD same-turn reviewer dispatch header is absent"

chk_absent "$RELEASE_MD" \
  'two separate calls' \
  "delegated-dispatch: OLD 'steps 7 and 8 are always two separate calls' phrasing is absent"

# ---------------------------------------------------------------------------
# Group 3: The annotated tag is pushed only AFTER merge
# ---------------------------------------------------------------------------

chk_prose "$RELEASE_MD" \
  '### 8. Push the annotated tag — only after merge' \
  "tag-after-merge: step 8 (renumbered) headed 'only after merge'"

chk_prose "$RELEASE_MD" \
  '**Never** push the tag before this point.' \
  "tag-after-merge: inline instruction never to push the tag before this point"

chk_prose "$RELEASE_MD" \
  '**Never** push the `vX.Y.Z` tag before `task-orchestrator` confirms the PR is merged (step 7'"'"'s terminal report).' \
  "tag-after-merge: hard-refusal anchored on task-orchestrator confirming the merge"

chk_prose "$RELEASE_MD" \
  'stop and surface it exactly as reported. Do not push a tag.' \
  "tag-after-merge: step 7's held/unmerged terminal state also forbids tagging"

# ---------------------------------------------------------------------------
# Group 4: Release branch is task/release-* shaped, never release/*/hotfix/*
# ---------------------------------------------------------------------------

chk_prose "$RELEASE_MD" \
  'for branch **`task/release-<next_version>`** — **never** `release/*` or `hotfix/*`' \
  "branch-shape: step 5 names task/release-<next_version> and forbids release/*|hotfix/*"

chk_prose "$RELEASE_MD" \
  '**Never** ride the release bump on `release/*` or `hotfix/*`' \
  "branch-shape: hard-refusal forbids release/*|hotfix/*"

chk_prose "$RELEASE_MD" \
  'The branch is always `task/release-<version>`.' \
  "branch-shape: hard-refusal restates the branch is always task/release-<version>"

chk_absent "$RELEASE_MD" \
  'branch **`release/' \
  "branch-shape: no branch is ever advertised in the release/* shape"

chk_absent "$RELEASE_MD" \
  'branch **`hotfix/' \
  "branch-shape: no branch is ever advertised in the hotfix/* shape"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "release-independent-chain (#43/#44c): all assertions passed."
  exit 0
else
  echo "release-independent-chain (#43/#44c): $fails assertion(s) failed."
  exit 1
fi
