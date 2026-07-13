#!/usr/bin/env bash
#
# Regression test — next-task.md step 4 must not ask "Claim this task?" when
# the operator already named the task id explicitly in $ARGUMENTS.
#
# Before this fix, step 4 unconditionally asked for confirmation in
# interactive mode regardless of whether the id was auto-picked by
# task-discovery or explicitly supplied by the operator. Naming an id is
# already an unambiguous statement of intent (mirrors the non-interactive
# branch's "the flag is the consent" reasoning) — the confirmation should
# only fire for the auto-picked path, where the operator has not yet seen
# which task would be chosen.
#
# Contract invariants asserted:
#   - step 4 distinguishes "id explicitly named" from "auto-picked"
#   - the explicit-id path skips the AskUserQuestion confirmation
#   - the auto-picked path still asks "Claim this task?"
#   - the old unconditional-ask wording is gone
#
# Hermetic: greps committed prose only; no network, no jq, no temp dirs.
#
# Run:  hooks/tests/next-task-explicit-id-skip-confirm.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NEXT_TASK="$REPO_ROOT/commands/next-task.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

echo "next-task-explicit-id-skip-confirm:"

chk_prose "$NEXT_TASK" 'id explicitly named in `$ARGUMENTS` (step 3):** skip the confirmation' \
  "next-task step 4: explicit-id path skips confirmation"

chk_prose "$NEXT_TASK" 'naming the id **is** the consent' \
  "next-task step 4: explicit-id consent reasoning present"

chk_prose "$NEXT_TASK" 'auto-picked (no id in `$ARGUMENTS`):** ask explicitly: *"Claim this task?"*' \
  "next-task step 4: auto-picked path still asks for confirmation"

chk_absent "$NEXT_TASK" '- **Interactive mode:** ask explicitly: *"Claim this task?"*. Wait for a yes/no. If no, stop — do not move tracking or create a worktree.' \
  "next-task step 4: old unconditional-ask wording removed"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "next-task-explicit-id-skip-confirm: all assertions passed."
  exit 0
else
  echo "next-task-explicit-id-skip-confirm: $fails assertion(s) failed."
  exit 1
fi
