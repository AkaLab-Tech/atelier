#!/usr/bin/env bash
#
# Regression test for #44c — no standalone command self-coordinates
# authoring + review of a PR it prepared.
#
# Root cause pattern this guards against: a standalone, non-task-branch
# command (align's Tier 3 `auto` path, release's bump-PR chain, or a
# plan-task autonomous plan-landing PR) authors or prepares a PR and then
# ALSO dispatches `reviewer` (and `auto-merge`) itself, from its own turn.
# Collapsing "the actor that prepared the change" and "the actor that
# reviews/approves it" into the same session trips the auto-mode
# classifier's self-approval block. The fix (already landed for all three
# commands as of #44c) is: each command delegates the ENTIRE
# author -> review -> merge coordination to the `task-orchestrator` agent
# (`mode: non-task-pr`), which then dispatches `pr-author`/`pr-opener` ->
# `reviewer` -> `auto-merge` as ITS OWN sub-agent calls, one level down from
# the driving command's turn.
#
# CRITICAL negative-assertion design note: the corrected prose in align.md
# and release.md legitimately DESCRIBES what the orchestrator does (e.g.
# "the orchestrator ... dispatches `pr-opener` -> `reviewer` -> ... ->
# `auto-merge`"), so a naive `chk_absent` on the bare words "reviewer" or
# "auto-merge" would false-fail on correct, already-fixed prose. Instead,
# every negative assertion below (b) is anchored on the OLD
# self-coordination SHAPE — a step header or dispatch line that names
# `reviewer` as the direct `Task`/`SlashCommand` target of the command's OWN
# turn (e.g. align's pre-fix "invoke the `reviewer` agent (via
# `SlashCommand`) against the PR." or release's pre-fix "`reviewer` dispatch
# (`Task`, separate from step 7)") — never on a bare mention of the word.
# Each command's coordinating section is also extracted via `awk` first (as
# `pr-opener-delegation.test.sh` extracts align's Tier-3-auto section) so the
# checks are scoped to the coordinating path itself, not the whole file.
#
# Benign exception (NOT flagged): a command may still *open* / *prepare* a PR
# without also reviewing it — e.g. align's Tier 3 `ask` path and plan-task's
# interactive approval flow both authored inline via an operator-facing
# `AskUserQuestion` offer, and release step 6 dispatches `implementer` to make
# the version-bump edit. None of those pair authoring with a same-turn
# `reviewer`/`auto-merge` dispatch, so none are in scope here — this test
# targets only the author+review *pairing coordinated by the command's own
# turn*, not authoring (or an unrelated specialist dispatch) alone.
#
# Contract invariants asserted, per standalone command (align.md, release.md,
# plan-task.md):
#   (a) the command's coordinating/auto section names `task-orchestrator` as
#       the delegation target, in `mode: non-task-pr`
#   (b) that section does NOT contain an OLD-shape inline dispatch of
#       `reviewer` from the command's own turn (a `Task`/`SlashCommand` line
#       naming `reviewer` as its direct target within the command's own
#       coordinating step)
#   (c) a positive statement of the corrected invariant is present: the
#       driving session delegates the whole author->review->merge
#       coordination and never coordinates both authoring and review of a PR
#       it prepared itself
#
# Hermetic: greps committed prose only; no network, no jq, no temp dirs.
#
# Run:  hooks/tests/no-self-review-standalone.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALIGN_MD="$REPO_ROOT/commands/align.md"
RELEASE_MD="$REPO_ROOT/commands/release.md"
PLAN_TASK_MD="$REPO_ROOT/commands/plan-task.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label>
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

# chk_section_prose <section-text> <fixed-string> <label>
# Passes when the fixed string is present in the already-extracted section.
chk_section_prose() {
  local section="$1" pattern="$2" label="$3"
  if printf '%s' "$section" | grep -qF "$pattern"; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in extracted section"
  fi
}

# chk_section_absent <section-text> <fixed-string> <label>
# Passes when the fixed string is ABSENT from the already-extracted section.
chk_section_absent() {
  local section="$1" pattern="$2" label="$3"
  if printf '%s' "$section" | grep -qF "$pattern"; then
    fail "$label — token '$pattern' found but should be absent from extracted section"
  else
    pass "$label"
  fi
}

for f in "$ALIGN_MD" "$RELEASE_MD" "$PLAN_TASK_MD"; do
  [ -f "$f" ] || { echo "  FAIL: $f not found"; exit 1; }
done

# ---------------------------------------------------------------------------
# Section extraction — scope each command to its own coordinating path
# ---------------------------------------------------------------------------

# align.md — Tier 3 `auto` (autonomous) section (header to next ##/### header).
align_tier3_auto_section() {
  awk '
    /^### Tier 3 under `auto`/ { capture=1 }
    capture && /^## / && !/^### Tier 3 under `auto`/ { exit }
    capture && /^### / && !/^### Tier 3 under `auto`/ { exit }
    capture { print }
  ' "$ALIGN_MD"
}

# release.md — the delegated coordination dispatch (step 7) through EOF,
# which also covers the tag step and the Hard refusals section (both carry
# relevant assertions).
release_coordinating_section() {
  awk '
    /^### 7\. Delegate author/ { capture=1 }
    capture { print }
  ' "$RELEASE_MD"
}

# plan-task.md — the "Autonomous plan-landing PRs" note through EOF, which
# also covers the matching Hard refusals entry.
plantask_coordinating_section() {
  awk '
    /\*\*Autonomous plan-landing PRs\.\*\*/ { capture=1 }
    capture { print }
  ' "$PLAN_TASK_MD"
}

ALIGN_AUTO="$(align_tier3_auto_section)"
RELEASE_COORD="$(release_coordinating_section)"
PLANTASK_COORD="$(plantask_coordinating_section)"

if [ -z "$ALIGN_AUTO" ]; then
  fail "align: Tier 3 auto section extraction is empty — header token may have drifted"
else
  pass "align: Tier 3 auto section extracted"
fi

if [ -z "$RELEASE_COORD" ]; then
  fail "release: step 7 coordinating section extraction is empty — header token may have drifted"
else
  pass "release: step 7 coordinating section extracted"
fi

if [ -z "$PLANTASK_COORD" ]; then
  fail "plan-task: autonomous plan-landing PR note extraction is empty — token may have drifted"
else
  pass "plan-task: autonomous plan-landing PR note extracted"
fi

# ---------------------------------------------------------------------------
# align.md — Tier 3 `auto` (autonomous) path
# ---------------------------------------------------------------------------

# (a) names task-orchestrator as the coordination target, in non-task-pr mode
chk_section_prose "$ALIGN_AUTO" 'task-orchestrator' \
  "align: Tier 3 auto section names task-orchestrator"

chk_section_prose "$ALIGN_AUTO" 'mode: non-task-pr' \
  "align: Tier 3 auto section dispatches task-orchestrator in mode: non-task-pr"

# (b) no OLD-shape inline reviewer dispatch from align's own turn
chk_section_absent "$ALIGN_AUTO" \
  'invoke the `reviewer` agent (via `SlashCommand`) against the PR.' \
  "align: Tier 3 auto section does not inline-dispatch reviewer via SlashCommand (OLD pre-delegation shape)"

chk_section_absent "$ALIGN_AUTO" \
  '**Review:** invoke the `reviewer` agent' \
  "align: Tier 3 auto section has no numbered 'Review' step dispatching reviewer itself (OLD pre-delegation shape)"

# (c) positive corrected-invariant statement
chk_section_prose "$ALIGN_AUTO" \
  'Align does not itself dispatch `reviewer` or `auto-merge`, and' \
  "align: Tier 3 auto section states align does not itself dispatch reviewer or auto-merge"

chk_section_prose "$ALIGN_AUTO" \
  'the actor that prepares the change is never the same' \
  "align: Tier 3 auto section states the corrected same-actor invariant"

# ---------------------------------------------------------------------------
# release.md — bump-PR coordination (step 7 onward)
# ---------------------------------------------------------------------------

# (a) names task-orchestrator as the coordination target, in non-task-pr mode
chk_section_prose "$RELEASE_COORD" 'task-orchestrator' \
  "release: step 7 coordinating section names task-orchestrator"

chk_section_prose "$RELEASE_COORD" 'mode: non-task-pr' \
  "release: step 7 coordinating section dispatches task-orchestrator in mode: non-task-pr"

# (b) no OLD-shape inline reviewer dispatch from release's own turn
chk_section_absent "$RELEASE_COORD" \
  '`reviewer` dispatch (`Task`, separate from step 7)' \
  "release: coordinating section has no OLD same-turn reviewer Task-dispatch header"

chk_section_absent "$RELEASE_COORD" \
  '### 8. Independent review' \
  "release: coordinating section has no OLD 'Independent review' step dispatching reviewer itself"

# (c) positive corrected-invariant statement
chk_prose "$RELEASE_MD" \
  'This command delegates the whole author→review→merge coordination to `task-orchestrator` (non-task PR coordination mode)' \
  "release: top-of-file states the whole author-review-merge coordination is delegated to task-orchestrator"

chk_section_prose "$RELEASE_COORD" \
  "**Never** dispatch \`pr-author\`, \`reviewer\`, or \`auto-merge\` from this command's own turn" \
  "release: hard-refusal states release never dispatches pr-author/reviewer/auto-merge from its own turn"

# ---------------------------------------------------------------------------
# plan-task.md — autonomous plan-landing PR coordination
# ---------------------------------------------------------------------------

# (a) names task-orchestrator as the coordination target, in non-task-pr mode
chk_section_prose "$PLANTASK_COORD" 'task-orchestrator' \
  "plan-task: autonomous plan-landing PR note names task-orchestrator"

chk_section_prose "$PLANTASK_COORD" '(non-task PR coordination mode)' \
  "plan-task: autonomous plan-landing PR note specifies non-task PR coordination mode"

# (b) no OLD/self-shape inline reviewer dispatch from plan-task's own turn
chk_section_absent "$PLANTASK_COORD" \
  '`reviewer` dispatch (`Task`' \
  "plan-task: autonomous plan-landing PR note has no inline reviewer Task-dispatch"

chk_absent "$PLAN_TASK_MD" \
  '`reviewer` dispatch (`Task`' \
  "plan-task: file-wide — no inline reviewer Task-dispatch anywhere in the command"

# (c) positive corrected-invariant statement
chk_section_prose "$PLANTASK_COORD" \
  'never authored and reviewed by the driving session itself' \
  "plan-task: autonomous plan-landing PR note states the PR is never authored and reviewed by the driving session itself"

chk_section_prose "$PLANTASK_COORD" \
  'a driving session must never coordinate both authoring and review of a PR it prepared' \
  "plan-task: autonomous plan-landing PR note states the corrected never-coordinate-both invariant"

chk_section_prose "$PLANTASK_COORD" \
  'Never** author AND review a plan-landing PR from this command'"'"'s own turn' \
  "plan-task: hard-refusal restates never author AND review a plan-landing PR from this command's own turn"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "no-self-review-standalone (#44c): all assertions passed."
  exit 0
else
  echo "no-self-review-standalone (#44c): $fails assertion(s) failed."
  exit 1
fi
