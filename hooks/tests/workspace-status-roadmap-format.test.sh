#!/usr/bin/env bash
#
# Test for atelier-workspace-status's roadmap_format() — the per-member §5
# conformance signal used by /atelier:onboard-workspace to find members whose
# ROADMAP.md must be adopted to PLAN.md §5. Mirrors detect_roadmap_format in
# atelier-setup-project (M7.1.F74).
#
# Hermetic: extracts roadmap_format() and runs it against throwaway dirs.
#
# Run:  hooks/tests/workspace-status-roadmap-format.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-workspace-status"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

FN="$TMP/roadmap_format.sh"
awk '/^roadmap_format\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$FN"
grep -q "non-conforming" "$FN" || { echo "  FAIL: could not extract roadmap_format() from $SCRIPT"; exit 1; }
# shellcheck disable=SC1090
source "$FN"

assert() { # <expected> <dir> <label>
  local got; got="$(roadmap_format "$2")"
  [ "$got" = "$1" ] && pass "$3 (=$got)" || fail "$3: expected '$1', got '$got'"
}

mk() { local d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"; }

D1="$(mk a)"; printf '# Roadmap\n## 🎯 P1 — Next\n- [ ] x\n' > "$D1/ROADMAP.md"
assert conforming "$D1" "§5 ROADMAP (emoji P1)"

D2="$(mk b)"; printf '# Roadmap\n## P0 — Blockers\n' > "$D2/ROADMAP.md"
assert conforming "$D2" "§5 ROADMAP (plain P0)"

D3="$(mk c)"; printf '# Roadmap\n## Backlog\n### TASK-68 — Prioridad Alta\n' > "$D3/ROADMAP.md"
assert non-conforming "$D3" "foreign ROADMAP (Backlog / TASK-NN)"

D4="$(mk d)"; printf '# Roadmap\n## High Priority\n## Phase 8\n' > "$D4/ROADMAP.md"
assert non-conforming "$D4" "High/Med/Low (no P0/P1/P2; 'Phase' not matched)"

D5="$(mk e)"
assert absent "$D5" "missing ROADMAP.md"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "workspace-status roadmap_format: all assertions passed."; exit 0
else
  echo "workspace-status roadmap_format: $fails assertion(s) failed."; exit 1
fi
