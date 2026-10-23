#!/usr/bin/env bash
#
# Regression test for #572 — the non-`files` planning gate in
# /atelier:next-task must not refuse an In Progress item whose `Ready` was
# consumed by a next-part claim with the "not planned" message. For an
# explicitly named id whose Status is in `stateMap.inProgress` the gate falls
# through to the "Claim kind" classifier (signal (c) covers `Ready`); a Todo
# item with no `Ready` is still refused exactly as before.
#
# Hermetic: greps committed prose only; no network, no temp dirs.
#
# Run:  hooks/tests/next-task-inprogress-planning-gate.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

# shellcheck disable=SC2016 # backticks in single quotes are literal prose tokens
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NEXT_TASK="${NEXT_TASK_FILE:-$REPO_ROOT/commands/next-task.md}"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then pass "$label"
  else fail "$label — token '$pattern' not found in $file"; fi
}
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else pass "$label"; fi
}
# First line number of a fixed-string match (empty when absent).
line_of() { grep -nF -e "$2" "$1" 2>/dev/null | head -n1 | cut -d: -f1; }

if [ -f "$NEXT_TASK" ]; then pass "file: commands/next-task.md exists"
else fail "file: $NEXT_TASK not found"; fi

# ---------------------------------------------------------------------------
# Group 1: the In Progress exception
# ---------------------------------------------------------------------------
EXC='**Exception — In Progress item (non-`files` backend, explicitly named id only):**'
chk_prose "$NEXT_TASK" "$EXC" \
  "exception: paragraph heading present"
chk_prose "$NEXT_TASK" "the planning gate does not refuse" \
  "exception: gate does not refuse an In Progress item"
chk_prose "$NEXT_TASK" 'when the `getTask(id)` record'"'"'s Status is in `stateMap.inProgress`' \
  "exception: keyed on getTask Status in stateMap.inProgress"
chk_prose "$NEXT_TASK" 'The `Ready` and plan-existence halves move to the next-part / interrupted-claim classification below ("Claim kind").' \
  "exception: Ready and plan-existence move to Claim kind classification"
chk_prose "$NEXT_TASK" 'A Todo item (Status not in `stateMap.inProgress`) with no `Ready` is still refused exactly as below.' \
  "exception: Todo item without Ready is still refused"
chk_prose "$NEXT_TASK" '(except for an In Progress item per the exception above, which falls through to the classifier)' \
  "refusal sentence: carves out the In Progress exception"

# ---------------------------------------------------------------------------
# Group 2: refusal wording unchanged
# ---------------------------------------------------------------------------
chk_prose "$NEXT_TASK" 'The **planning-gate validation** is absolute: a named-but-unplanned task is refused exactly like an auto-picked one.' \
  "refusal: planning gate still absolute for unplanned tasks"
chk_prose "$NEXT_TASK" 'If the task fails the planning gate (missing `Ready` / missing `[ready]`' \
  "refusal: missing Ready / [ready] still fails the gate"
chk_prose "$NEXT_TASK" '✗ /next-task: task #<id> is not planned — run `/atelier:plan-task #<id>` first.' \
  "refusal: 'not planned' block unchanged"
chk_prose "$NEXT_TASK" 'never improvise a plan, never offer to plan it inline' \
  "refusal: never improvise a plan"

# ---------------------------------------------------------------------------
# Group 3: Status-dependent Ready requirement (named-id bullet)
# ---------------------------------------------------------------------------
chk_prose "$NEXT_TASK" '`Ready` field is set (only when the record'"'"'s Status is **not** in `stateMap.inProgress`' \
  "named-id bullet: Ready required only when Status is not In Progress"
chk_prose "$NEXT_TASK" 'for an In Progress item the `Ready` check is not evaluated here, it moves to classifier signal (c) under "Claim kind" below' \
  "named-id bullet: In Progress Ready check moves to signal (c)"

# ---------------------------------------------------------------------------
# Group 4: classifier signal (e) and the missing-signal example
# ---------------------------------------------------------------------------
chk_prose "$NEXT_TASK" 'A plan with no timestamp never qualifies. If no `PLAN_SOURCE` was found, (e) fails.' \
  "signal (e): no PLAN_SOURCE -> (e) fails"
chk_prose "$NEXT_TASK" '`missing signal: no approved plan found (plan it with /atelier:plan-task)`' \
  "missing-signal example: no approved plan found"
chk_prose "$NEXT_TASK" 'instead of the planning-gate "not planned" refusal, per the planning-gate exception in this step.' \
  "interrupted-claim sentence: cites the planning-gate exception"
chk_prose "$NEXT_TASK" '`missing signal: Ready is not set`' \
  "missing-signal example: Ready is not set still present"

# ---------------------------------------------------------------------------
# Group 5: ordering — step 3 heading < exception < Claim kind, Plan-on-base guard
# ---------------------------------------------------------------------------
l_head=$(line_of "$NEXT_TASK" '### 3. Pick the task')
l_exc=$(line_of "$NEXT_TASK" "$EXC")
l_claim=$(line_of "$NEXT_TASK" '**Claim kind — first claim or next part')
l_guard=$(line_of "$NEXT_TASK" '**Plan-on-base guard')

if [ -n "$l_head" ] && [ -n "$l_exc" ] && [ -n "$l_claim" ] && [ -n "$l_guard" ]; then
  pass "ordering: all four anchors found (heading=$l_head exception=$l_exc guard=$l_guard claim=$l_claim)"
else
  fail "ordering: missing anchor (heading='$l_head' exception='$l_exc' guard='$l_guard' claim='$l_claim')"
fi
if [ -n "$l_head" ] && [ -n "$l_exc" ] && [ "$l_head" -lt "$l_exc" ]; then
  pass "ordering: exception is after the '### 3.' heading"
else fail "ordering: exception ($l_exc) not after '### 3.' heading ($l_head)"; fi
if [ -n "$l_exc" ] && [ -n "$l_claim" ] && [ "$l_exc" -lt "$l_claim" ]; then
  pass "ordering: exception is before 'Claim kind'"
else fail "ordering: exception ($l_exc) not before 'Claim kind' ($l_claim)"; fi
if [ -n "$l_exc" ] && [ -n "$l_guard" ] && [ "$l_exc" -lt "$l_guard" ]; then
  pass "ordering: exception is before 'Plan-on-base guard'"
else fail "ordering: exception ($l_exc) not before 'Plan-on-base guard' ($l_guard)"; fi

# The exception must appear exactly once (no duplicated paragraph).
n_exc=$(grep -cF -e "$EXC" "$NEXT_TASK" 2>/dev/null || true)
if [ "$n_exc" = "1" ]; then pass "exception: appears exactly once"
else fail "exception: expected exactly 1 occurrence, found '$n_exc'"; fi

chk_absent "$NEXT_TASK" 'In Progress item is refused' \
  "no wording that refuses an In Progress item outright"

echo
if [ "$fails" -eq 0 ]; then echo "All assertions passed."; exit 0
else echo "$fails assertion(s) failed."; exit 1; fi
