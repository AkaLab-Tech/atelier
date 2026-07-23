#!/usr/bin/env bash
#
# Test for the operator-facing fenced ```text output-block language leak fix
# (issue #28): operator-rules.md carries the authoritative "translate the
# labels" directive, and every command file whose final operator-facing
# ```text block was identified as a genuine status/output block (as opposed
# to an internal pseudocode / inter-agent-dispatch block) carries the exact
# same inline reminder immediately before it.
#
# Static assertions only — model output is non-deterministic, so this test
# checks the source markdown, not a live command run.
#
# Run:  hooks/tests/operator-language-output-blocks.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RULES_FILE="$REPO_ROOT/operator-rules.md"

# The exact reminder line every affected command file must carry, verbatim,
# so this test can grep one stable string across all of them.
REMINDER="Render the labels below in the operator's chatLanguage — the English is illustrative structure, not literal output."

# Command files whose ```text block(s) were inspected and found to be genuine
# operator-facing status/output (not an internal pseudocode block, not an
# inter-agent Task-dispatch briefing). commands/setup-project.md's only
# ```text block is an internal implementation pseudocode snippet ("Mandatory
# dispatch + Write path") never shown to the operator, so it is deliberately
# excluded here.
AFFECTED_FILES=(
  "commands/abandon-task.md"
  "commands/babysit-prs.md"
  "commands/finish-task.md"
  "commands/next-task.md"
  "commands/plan-task.md"
  "commands/release.md"
  "commands/resume-task.md"
  "commands/set-policy.md"
  "commands/slice-task.md"
  "commands/status.md"
  "commands/update.md"
  "commands/validate.md"
)

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- operator-rules.md: central directive present ---
# NOTE: deliberately NOT named "## Operator chat language" — that literal
# string is reserved for the dynamically hook-injected directive tested by
# hooks/tests/operator-language.test.sh (front-loaded, checked to sit within
# the first 2KB); a second static occurrence in the file itself would trip
# that test's "silent when unset" assertion (the file is cat'd regardless of
# whether a chatLanguage is configured).
[ -f "$RULES_FILE" ] && grep -q '## Command output-block language' "$RULES_FILE" \
  && pass "operator-rules.md has a 'Command output-block language' section" \
  || fail "operator-rules.md missing 'Command output-block language' section"

grep -q 'illustrative structure, not literal output' "$RULES_FILE" \
  && pass "operator-rules.md carries the 'illustrative structure' directive" \
  || fail "operator-rules.md missing the 'illustrative structure' directive"

grep -q 'fenced.*```text' "$RULES_FILE" \
  && pass "operator-rules.md directive references fenced text blocks" \
  || fail "operator-rules.md directive does not mention fenced text blocks"

# --- each affected command file: consistent inline reminder present ---
for rel in "${AFFECTED_FILES[@]}"; do
  f="$REPO_ROOT/$rel"
  if [ ! -f "$f" ]; then
    fail "$rel: file not found"
    continue
  fi
  if grep -qF "$REMINDER" "$f"; then
    pass "$rel: carries the consistent inline reminder"
  else
    fail "$rel: missing the consistent inline reminder"
  fi
done

# --- setup-project.md: deliberately excluded, but still sane ---
if [ -f "$REPO_ROOT/commands/setup-project.md" ]; then
  if grep -qF "$REMINDER" "$REPO_ROOT/commands/setup-project.md"; then
    fail "commands/setup-project.md: unexpectedly carries the reminder (its only \`\`\`text block is internal pseudocode, not operator output)"
  else
    pass "commands/setup-project.md: correctly has no reminder (no operator-facing text block)"
  fi
fi

echo ""
if [ "$fails" -eq 0 ]; then echo "operator-language-output-blocks: all assertions passed."; exit 0
else echo "operator-language-output-blocks: $fails assertion(s) failed."; exit 1; fi
