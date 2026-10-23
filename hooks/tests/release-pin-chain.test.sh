#!/usr/bin/env bash
#
# Regression test for #575 — the catalog pin PR (/atelier:release step 8b) must
# not be prepared from the command's own turn, and a classifier-denied merge is
# a terminal held state.
#
# Asserts (prose only; hermetic, no network, no temp dirs):
#   1. step 8b dispatches `atelier:implementer` to prepare the pin
#   2. frontmatter allowed-tools: no `Bash(atelier-release:*)`, has
#      `Bash(atelier-release resolve:*)`
#   3. no top-level "run there:" pin-marketplace step in 8b
#   4. hard refusal: never run pin-marketplace / edit / commit in the
#      claude-plugins worktree from the command's own turn
#   5. held message ("previous pinned release") and the "never print the step 9
#      recipe" rule remain in 8b
#   6. auto-merge SKILL.md and task-orchestrator.md both name the held state
#      `held: merge blocked by auto-mode classifier — human merge required`
#
# Run:  hooks/tests/release-pin-chain.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_MD="$REPO_ROOT/commands/release.md"
SKILL_MD="$REPO_ROOT/skills/auto-merge/SKILL.md"
ORCH_MD="$REPO_ROOT/agents/task-orchestrator.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_text <text> <fixed-string> <label> — present in the given text
chk_text() {
  if printf '%s\n' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 — token '$2' not found"; fi
}
# chk_text_absent <text> <fixed-string> <label> — absent from the given text
chk_text_absent() {
  if printf '%s\n' "$1" | grep -qF -- "$2"; then fail "$3 — token '$2' found but should be absent"; else pass "$3"; fi
}

for f in "$RELEASE_MD" "$SKILL_MD" "$ORCH_MD"; do
  [ -f "$f" ] || { echo "  FAIL: $f not found"; exit 1; }
done

# Frontmatter = lines between the first two `---`.
FRONT="$(awk '/^---$/{n++; next} n==1{print} n>=2{exit}' "$RELEASE_MD")"
ALLOWED="$(printf '%s\n' "$FRONT" | grep '^allowed-tools:' || true)"
# Step 8b section = from its heading up to the next `### ` heading.
STEP8B="$(awk '/^### 8b\. /{p=1; print; next} p && /^### /{exit} p{print}' "$RELEASE_MD")"

[ -n "$ALLOWED" ] || fail "release.md frontmatter has an allowed-tools line"
[ -n "$STEP8B" ] || fail "release.md has a '### 8b.' section"

# 1. implementer prepares the pin
chk_text "$STEP8B" 'implementer` dispatch (`Task`, `atelier:implementer`)' \
  "step 8b prepares the pin with an atelier:implementer dispatch"

# 2. allowed-tools
chk_text_absent "$ALLOWED" 'Bash(atelier-release:*)' \
  "allowed-tools does not grant the blanket Bash(atelier-release:*)"
chk_text "$ALLOWED" 'Bash(atelier-release resolve:*)' \
  "allowed-tools grants Bash(atelier-release resolve:*)"

# 3. no own-turn "run there:" pin-marketplace step
chk_text_absent "$STEP8B" 'and run there:' \
  "step 8b has no top-level 'run there:' pin-marketplace step"

# 4. hard refusal
chk_text "$(cat "$RELEASE_MD")" \
  'Never** run `atelier-release pin-marketplace`, edit, or commit in the claude-plugins worktree from this command'"'"'s own turn' \
  "hard refusal: never pin-marketplace/edit/commit in the claude-plugins worktree from own turn"

# 5. held message + no step 9 recipe
chk_text "$STEP8B" 'operators keep receiving the previous pinned release until the pin PR merges' \
  "step 8b held message: operators keep the previous pinned release until the pin PR merges"
chk_text "$STEP8B" 'do **not** print the step 9 recipe' \
  "step 8b held: never print the step 9 recipe"

# 6. classifier-denied merge held state
HELD='held: merge blocked by auto-mode classifier — human merge required'
chk_text "$(cat "$SKILL_MD")" "$HELD" "auto-merge SKILL.md names the classifier-denied-merge held state"
chk_text "$(cat "$ORCH_MD")" "$HELD" "task-orchestrator.md names the classifier-denied-merge held state"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "release-pin-chain (#575): all assertions passed."
  exit 0
else
  echo "release-pin-chain (#575): $fails assertion(s) failed."
  exit 1
fi
