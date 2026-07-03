#!/usr/bin/env bash
#
# Regression test for #43 — /atelier:release independent-chain contract.
#
# Asserts that `commands/release.md` encodes the invariants that keep the
# release bump on the same independent pr-author -> reviewer -> auto-merge
# chain every other atelier PR goes through, so a future careless edit that
# silently drops or contradicts these invariants fails CI.
#
# Contract invariants asserted:
#   Group 1 — This command never authors/reviews/merges the bump PR itself
#     - top-of-file statement that the command never authors/reviews/merges
#       the bump PR from its own turn
#     - matching hard-refusal restatement
#   Group 2 — Authoring and review are two separate Task dispatches
#     - step 7 (pr-author) is explicitly marked separate from step 8
#     - step 8 (reviewer) is explicitly marked separate from step 7
#     - hard-refusal: the same Task dispatch never does both
#   Group 3 — The annotated tag is pushed only AFTER merge
#     - step 10 is headed "only after merge"
#     - inline "never push the tag before this point" instruction
#     - hard-refusal restatement anchored on atelier:auto-merge confirming merge
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
# Group 1: This command never authors/reviews/merges the bump PR itself
# ---------------------------------------------------------------------------

chk_prose "$RELEASE_MD" \
  '**This command never authors, reviews, or merges the bump PR from its own turn.**' \
  "own-turn: top-of-file statement the command never authors/reviews/merges the bump PR"

chk_prose "$RELEASE_MD" \
  "**Never** author, review, or merge the bump PR from this command's own turn." \
  "own-turn: hard-refusal restates never author/review/merge from own turn"

# ---------------------------------------------------------------------------
# Group 2: Authoring and review are two separate Task dispatches
# ---------------------------------------------------------------------------

chk_prose "$RELEASE_MD" \
  '### 7. Author the release PR — `pr-author` dispatch (`Task`, separate from step 8)' \
  "separate-dispatch: step 7 (pr-author) explicitly marked separate from step 8"

chk_prose "$RELEASE_MD" \
  '### 8. Independent review — `reviewer` dispatch (`Task`, separate from step 7)' \
  "separate-dispatch: step 8 (reviewer) explicitly marked separate from step 7"

chk_prose "$RELEASE_MD" \
  '**Never** let the same `Task` dispatch both author and review the PR — steps 7 and 8 are always two separate calls' \
  "separate-dispatch: hard-refusal — same Task dispatch never authors and reviews"

# ---------------------------------------------------------------------------
# Group 3: The annotated tag is pushed only AFTER merge
# ---------------------------------------------------------------------------

chk_prose "$RELEASE_MD" \
  '### 10. Push the annotated tag — only after merge' \
  "tag-after-merge: step 10 headed 'only after merge'"

chk_prose "$RELEASE_MD" \
  '**Never** push the tag before this point.' \
  "tag-after-merge: inline instruction never to push the tag before this point"

chk_prose "$RELEASE_MD" \
  '**Never** push the `vX.Y.Z` tag before `atelier:auto-merge` confirms the PR is merged.' \
  "tag-after-merge: hard-refusal anchored on atelier:auto-merge confirming the merge"

chk_prose "$RELEASE_MD" \
  'do not push a tag against an unmerged PR' \
  "tag-after-merge: step 9 (auto-merge hold) also forbids tagging an unmerged PR"

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
  echo "release-independent-chain (#43): all assertions passed."
  exit 0
else
  echo "release-independent-chain (#43): $fails assertion(s) failed."
  exit 1
fi
