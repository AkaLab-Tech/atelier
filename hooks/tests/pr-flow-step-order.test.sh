#!/usr/bin/env bash
#
# Regression test for #32 (audit#44) — `skills/pr-flow/SKILL.md` step 4 puts the
# tracking commit on the branch that reaches origin.
#
# Root cause as filed: pr-flow ordered the push (then step 3) BEFORE the
# tracking move (then step 4), so the `IN_PROGRESS → HISTORY` commit was
# created after the one and only push and never reached `origin`. Every PR
# opened through the recipe was malformed per the recipe's own convention.
#
# The heading reorder itself landed with #30 (`fix(pr-author): run the size
# gate before the tracking move`). What survived it inside step 4 was the
# pre-reorder prose:
#   1. an `amend the previous commit` fallback, whose guard ("only if that
#      commit has not yet been pushed") could never hold under the OLD order —
#      dead text — and which under the corrected order is worse than dead: it
#      is reachable, and taking it folds the tracking edit into the code commit,
#      producing exactly the single-commit shape `agents/pr-author.md` step 2
#      forbids and step 4 calls non-negotiable.
#   2. a `Do one of:` / `**(preferred)**` framing that presented the separate
#      commit as a preference where the agent file states a requirement.
#   3. no statement anywhere of the ordering invariant audit#44 reported broken.
#      It was encoded only implicitly, in the heading numbers — nothing a future
#      edit could trip over.
#
# Invariants asserted:
#   Group 0 — preconditions: both files exist and are non-empty. An absence
#     assertion over a missing file is vacuously true, so without this the
#     Group 1 guards would report PASS after a rename.
#   Group 1 — the removed alternatives stay removed (regression guards; these
#     are the assertions that fail against the pre-fix text).
#   Group 2 — step 4 states the ordering invariant, the `chore(tracking)`
#     message convention, and the pre-push verification, so the recipe is as
#     complete as the agent file it implements. The three load-bearing tokens
#     are scoped to the step-4 SECTION, not to the file: an agent executing
#     step 4 reads step 4, so prose that drifted elsewhere is prose it never
#     sees.
#   Group 3 — the ordering is asserted STRUCTURALLY, by heading line numbers,
#     not by prose. This is the assertion that would have caught audit#44
#     directly and that keeps catching a re-inversion regardless of wording.
#   Group 4 — cross-file consistency: `agents/pr-author.md` still requires the
#     separate tracking commit and still keeps the tracking files out of the
#     code commit, and its own numbered steps are asserted STRUCTURALLY in the
#     same gate → tracking → push → PR order, so an inversion on the agent side
#     cannot re-open the defect from the other file while the prose still reads
#     correctly.
#
# Hermetic: greps committed prose only — no network, no `gh`, no git mutation,
# no reliance on cwd (paths resolve from BASH_SOURCE) and no shared helpers
# from any sibling test.
#
# Run:  hooks/tests/pr-flow-step-order.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/skills/pr-flow/SKILL.md"
PR_AUTHOR="$REPO_ROOT/agents/pr-author.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label> — passes when the string is present.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label> — passes when the string is absent.
# Fails closed: a missing/unreadable file is a FAIL, not a vacuous pass. Without
# this guard every absence assertion here would report PASS if the file were
# renamed or moved — the regression guards would go silently vacuous, which is
# the same class of defect as the one being pinned.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if [ ! -r "$file" ]; then
    fail "$label — $file is missing or unreadable, so absence proves nothing"
  elif grep -qF "$pattern" "$file"; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

# heading_line <file> <fixed-string> — first matching line number, or empty.
heading_line() {
  grep -nF "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1
}

# chk_in_section <file> <start-anchor> <end-anchor> <fixed-string> <label>
# Passes when the string appears BETWEEN the two anchors — not merely somewhere
# in the file. Placement is load-bearing: an agent executing step 4 reads step 4,
# so an invariant that drifted into another section is an invariant it never sees.
chk_in_section() {
  local file="$1" start="$2" end="$3" pattern="$4" label="$5" s e
  s="$(heading_line "$file" "$start")"
  e="$(heading_line "$file" "$end")"
  if [ -z "$s" ] || [ -z "$e" ] || [ "$s" -ge "$e" ]; then
    fail "$label — cannot bound the section ('$start' at line '$s', '$end' at line '$e')"
  elif sed -n "${s},${e}p" "$file" | grep -qF "$pattern"; then
    pass "$label"
  else
    fail "$label — token '$pattern' is not inside the '$start' section of $file"
  fi
}

# ---------------------------------------------------------------------------
# Group 0: preconditions. Every later assertion is conditioned on these files
# existing; without them the absence guards above would be arguing about
# nothing. Named and loud so a rename shows up as a rename, not as noise.
# ---------------------------------------------------------------------------

for _f in "$SKILL" "$PR_AUTHOR"; do
  if [ -s "$_f" ]; then
    pass "precondition: $(basename "$(dirname "$_f")")/$(basename "$_f") exists and is non-empty"
  else
    fail "precondition: $_f is missing or empty — the assertions below cannot mean anything"
  fi
done

# ---------------------------------------------------------------------------
# Group 1: the pre-fix alternatives are gone from step 4.
# ---------------------------------------------------------------------------

chk_absent "$SKILL" \
  'amend the previous commit' \
  "pr-flow: the amend-the-code-commit fallback is gone (it folds tracking into the code commit)"

chk_absent "$SKILL" \
  '**(preferred)**' \
  "pr-flow: the '(preferred)' framing is gone — the separate commit is required, not preferred"

chk_absent "$SKILL" \
  'Do one of:' \
  "pr-flow: the 'Do one of:' menu is gone — step 4 offers no alternative"

# ---------------------------------------------------------------------------
# Group 2: step 4 states what the agent file states — invariant, message
# convention, verification.
# ---------------------------------------------------------------------------

chk_in_section "$SKILL" '### 4. Move tracking' '### 5. Push only to' \
  '**Ordering invariant:**' \
  "pr-flow: step 4 carries an explicit ordering invariant (inside step 4, not elsewhere)"

# Deliberately long: the sequence IS the assertion — no shorter substring
# pins "between the gate and the push" rather than merely "somewhere near them".
chk_prose "$SKILL" \
  "**after** step 3's size gate and **before** step 5's push" \
  "pr-flow: the invariant places the tracking commit between the size gate and the push"

chk_prose "$SKILL" \
  'never reaches `origin` at all' \
  "pr-flow: step 4 records the audit#44 failure mode (a post-push tracking commit is stranded)"

chk_prose "$SKILL" \
  'Add a **separate commit**' \
  "pr-flow: step 4 states the separate commit as the single required move"

chk_in_section "$SKILL" '### 4. Move tracking' '### 5. Push only to' \
  'chore(tracking): move #<id> IN_PROGRESS → HISTORY' \
  "pr-flow: step 4 carries the chore(tracking) commit-message convention (matches pr-author)"

chk_in_section "$SKILL" '### 4. Move tracking' '### 5. Push only to' \
  '**Verify before running step 5**' \
  "pr-flow: step 4 requires verification before the push"

chk_prose "$SKILL" \
  'stop and fix it *before* pushing' \
  "pr-flow: a failed verification stops the flow before the branch becomes operator-visible"

chk_prose "$SKILL" \
  'no longer contains the task'"'"'s `#<id>` heading line' \
  "pr-flow: verification checks IN_PROGRESS.md no longer holds the task heading"

chk_prose "$SKILL" \
  'git log --oneline -2' \
  "pr-flow: verification checks the two-commit shape at the branch tip"

# ---------------------------------------------------------------------------
# Group 3: the ordering asserted STRUCTURALLY — heading line numbers must be
# strictly increasing. Independent of any prose wording; this is the assertion
# that fires directly on an audit#44-style re-inversion.
# ---------------------------------------------------------------------------

gate_ln="$(heading_line "$SKILL" '### 3. Size gate')"
track_ln="$(heading_line "$SKILL" '### 4. Move tracking')"
push_ln="$(heading_line "$SKILL" '### 5. Push only to')"
pr_ln="$(heading_line "$SKILL" '### 6. Open the PR')"

if [ -n "$gate_ln" ] && [ -n "$track_ln" ] && [ -n "$push_ln" ] && [ -n "$pr_ln" ]; then
  pass "pr-flow: all four ordered headings (size gate / tracking / push / PR) are present"
  if [ "$gate_ln" -lt "$track_ln" ] && [ "$track_ln" -lt "$push_ln" ] && [ "$push_ln" -lt "$pr_ln" ]; then
    pass "pr-flow: heading positions are strictly increasing — gate($gate_ln) < tracking($track_ln) < push($push_ln) < PR($pr_ln)"
  else
    fail "pr-flow: heading order inverted — gate($gate_ln) tracking($track_ln) push($push_ln) PR($pr_ln)"
  fi
else
  fail "pr-flow: missing one of the ordered headings — gate('$gate_ln') tracking('$track_ln') push('$push_ln') PR('$pr_ln')"
fi

# ---------------------------------------------------------------------------
# Group 4: cross-file consistency — `agents/pr-author.md` is the reference the
# recipe implements. If it stops requiring the separate tracking commit, this
# fix's premise is gone and pr-flow must be revisited with it.
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" \
  'Move the tracking forward as a separate commit — non-negotiable' \
  "pr-author: still requires the tracking move as a separate, non-negotiable commit"

chk_prose "$PR_AUTHOR" \
  'they go in their own commit at step 4' \
  "pr-author: still keeps IN_PROGRESS.md / HISTORY.md out of the code commit"

chk_prose "$PR_AUTHOR" \
  'chore(tracking): move #<id> IN_PROGRESS → HISTORY' \
  "pr-author: the commit-message convention pr-flow now mirrors is still stated here"

# Cross-file STRUCTURAL ordering. The prose checks above pin what pr-author
# *says*; this pins the order its numbered steps actually appear in. audit#44
# was an order inversion, and an inversion on the agent side would re-open the
# defect from the other file while every prose token above still matched. The
# anchors are the Core-responsibilities steps (each unique in the file — the
# FOLLOW-UP block spells its steps differently: "Push to the existing branch",
# "Skip step 6 entirely").
pa_gate_ln="$(heading_line "$PR_AUTHOR" '3. **Size gate — run')"
pa_track_ln="$(heading_line "$PR_AUTHOR" '4. **Move the tracking forward as a separate commit')"
pa_push_ln="$(heading_line "$PR_AUTHOR" '5. **Push to the right place.**')"
pa_pr_ln="$(heading_line "$PR_AUTHOR" '6. **Open the PR with')"

if [ -n "$pa_gate_ln" ] && [ -n "$pa_track_ln" ] && [ -n "$pa_push_ln" ] && [ -n "$pa_pr_ln" ]; then
  pass "pr-author: all four ordered steps (size gate / tracking / push / PR) are present"
  if [ "$pa_gate_ln" -lt "$pa_track_ln" ] && [ "$pa_track_ln" -lt "$pa_push_ln" ] &&
    [ "$pa_push_ln" -lt "$pa_pr_ln" ]; then
    pass "pr-author: step positions are strictly increasing — gate($pa_gate_ln) < tracking($pa_track_ln) < push($pa_push_ln) < PR($pa_pr_ln)"
  else
    fail "pr-author: step order inverted — gate($pa_gate_ln) tracking($pa_track_ln) push($pa_push_ln) PR($pa_pr_ln)"
  fi
else
  fail "pr-author: missing one of the ordered steps — gate('$pa_gate_ln') tracking('$pa_track_ln') push('$pa_push_ln') PR('$pa_pr_ln')"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "pr-flow-step-order (#32): all assertions passed."
  exit 0
else
  echo "pr-flow-step-order (#32): $fails assertion(s) failed."
  exit 1
fi
