#!/usr/bin/env bash
#
# Regression test for #31 (audit#192) — Step 3 of decision-broker's SKILL.md
# reads `decisionPolicy.<category>` (flat) but the real path `.atelier.json`
# is written to by `/atelier:set-policy` — and referenced everywhere else in
# this same document (the precedence summary's item 3, Step 2.5's forward
# reference) — is the NESTED `decisionPolicy.byCategory.<category>`.
#
# Root cause: an agent following Step 3 literally looked up a flat key that
# never exists in `.atelier.json`, found nothing, and fell through to
# `decisionPolicy.default` or the conservative `ask` fallback — silently
# ignoring every fixed/per-category `auto` policy the operator configured
# (the same failure mode observed in production and tracked as atelier
# issue #30).
#
# Fix asserted here: Step 3's lookup sentence names the nested
# `decisionPolicy.byCategory.<category>` path, matching the precedence
# summary and Step 2.5. The flat form is gone from Step 3.
#
# CRITICAL negative-assertion design note: `decisionPolicy.byCategory.<category>`
# legitimately contains `decisionPolicy.` as a substring, and the document
# elsewhere legitimately mentions `decisionPolicy.default` and bare
# `decisionPolicy` prose. A naive `grep -F 'decisionPolicy'` would false-fail
# on all of that correct, unrelated prose. The negative check below is
# anchored on the literal flat-key substring `decisionPolicy.<category>` —
# i.e. `decisionPolicy.` immediately followed by the literal `<category>`
# placeholder with no `byCategory.` in between. That substring cannot occur
# inside the nested form `decisionPolicy.byCategory.<category>` (which reads
# `decisionPolicy.byCategory.<category>` — "byCategory." sits between the
# two tokens the flat substring requires to be adjacent), so it does not
# false-positive against the corrected text, and it does not false-positive
# against `decisionPolicy.default` or bare `decisionPolicy` mentions either
# (neither contains the literal `<category>` placeholder immediately after
# `decisionPolicy.`).
#
# Contract invariants asserted:
#   1. Step 3's section is extracted (header to next ##/### header) so all
#      checks are scoped to the actual lookup instruction, not the whole file.
#   2. Step 3 names the nested `decisionPolicy.byCategory.<category>` path.
#   3. Step 3 does NOT contain the flat `decisionPolicy.<category>` substring
#      (the #31 defect shape) — checked both via the exact old sentence and
#      via the bare substring, so a partial copy-edit cannot re-open the bug.
#   4. Step 3 stays consistent with the precedence summary's item 3, which
#      names the same nested path — so the two can never silently drift
#      apart again (the way Step 3 and the summary drifted apart pre-fix).
#   5. File-wide regression guard: the flat substring does not reappear
#      anywhere else in SKILL.md either.
#
# Hermetic: greps committed prose only; no network, no jq, no temp dirs.
#
# Run:  hooks/tests/decision-broker-skill-policy-path.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/skills/decision-broker/SKILL.md"

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

# chk_section_prose <section-text> <fixed-string> <label>
chk_section_prose() {
  local section="$1" pattern="$2" label="$3"
  if printf '%s' "$section" | grep -qF "$pattern"; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in extracted section"
  fi
}

# chk_section_absent <section-text> <fixed-string> <label>
chk_section_absent() {
  local section="$1" pattern="$2" label="$3"
  if printf '%s' "$section" | grep -qF "$pattern"; then
    fail "$label — token '$pattern' found but should be absent from extracted section"
  else
    pass "$label"
  fi
}

[ -f "$SKILL" ] || { echo "  FAIL: $SKILL not found"; exit 1; }

# ---------------------------------------------------------------------------
# Section extraction — scope the checks to Step 3's own lookup instruction.
# ---------------------------------------------------------------------------

step3_section() {
  awk '
    /^### Step 3 — Read project policy/ { capture=1 }
    capture && /^## / && !/^### Step 3 — Read project policy/ { exit }
    capture && /^### / && !/^### Step 3 — Read project policy/ { exit }
    capture { print }
  ' "$SKILL"
}

STEP3="$(step3_section)"

if [ -z "$STEP3" ]; then
  fail "Step 3 section extraction is empty — header token may have drifted"
else
  pass "Step 3 section extracted"
fi

# ---------------------------------------------------------------------------
# Step 3 names the NESTED path.
# ---------------------------------------------------------------------------

chk_section_prose "$STEP3" \
  'Locate `decisionPolicy.byCategory.<category>`' \
  "Step 3: the lookup sentence locates the nested decisionPolicy.byCategory.<category> path"

# ---------------------------------------------------------------------------
# Step 3 does NOT contain the flat #31 defect shape.
# ---------------------------------------------------------------------------

chk_section_absent "$STEP3" \
  'Locate `decisionPolicy.<category>`' \
  "Step 3: OLD exact flat-path sentence ('Locate \`decisionPolicy.<category>\`') is gone"

chk_section_absent "$STEP3" \
  'decisionPolicy.<category>' \
  "Step 3: the bare flat substring 'decisionPolicy.<category>' does not appear anywhere in the section"

# ---------------------------------------------------------------------------
# Step 3 stays consistent with the precedence summary (item 3), so the two
# can never silently drift apart again.
# ---------------------------------------------------------------------------

chk_prose "$SKILL" \
  '`decisionPolicy.byCategory.<category>` in `.atelier.json` (this step)' \
  "precedence summary item 3 names the same nested decisionPolicy.byCategory.<category> path Step 3 uses"

# ---------------------------------------------------------------------------
# File-wide regression guard — the flat substring must not reappear anywhere
# else in the document either (e.g. reintroduced via a partial copy-edit).
# ---------------------------------------------------------------------------

chk_absent "$SKILL" 'decisionPolicy.<category>' \
  "SKILL.md file-wide: the flat 'decisionPolicy.<category>' substring is absent everywhere"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "decision-broker-skill-policy-path (#31): all assertions passed."
  exit 0
else
  echo "decision-broker-skill-policy-path (#31): $fails assertion(s) failed."
  exit 1
fi
