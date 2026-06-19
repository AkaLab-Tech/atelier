#!/usr/bin/env bash
#
# Test for atelier-migrate-task-ids (M7.4): detect + renumber non-§5 task ids in
# a §5-structured ROADMAP. Hermetic — synthetic project dirs, no network.
#
# Run:  hooks/tests/migrate-task-ids.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIG="$REPO_ROOT/scripts/atelier-migrate-task-ids"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

mkproj() {  # $1 = dir
  local d="$1"; mkdir -p "$d/.plan"
  cat > "$d/ROADMAP.md" <<'MD'
# Roadmap
## 🎯 P1 — Next
- [ ] `feat` Set up RLS `RLS.2` `~3h`
- [ ] `feat` Landing hero `WEB.1` `~2h` blocked_by:RLS.2
- [ ] `bug` Already numeric `#7` `~1h`
## 💭 P2 — Later
- [ ] `chore` Cleanup `DEVTOOL.3` `~30m`
MD
  printf '# In Progress\n\n- [ ] `feat` Set up RLS `RLS.2`\n' > "$d/IN_PROGRESS.md"
  : > "$d/.plan/RLS.2.md"; : > "$d/.plan/WEB.1.md"
}

# --- detection: --check on a §5 ROADMAP with foreign ids → exit 3 ---
T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"; mkproj "$T"
bash "$MIG" "$T" --check >/dev/null 2>&1; [ "$?" -eq 3 ] && pass "--check flags non-§5 ids (exit 3)" || fail "--check should exit 3"

# --- apply: renumber, preserve existing §5, rewrite blocked_by + IN_PROGRESS + .plan ---
bash "$MIG" "$T" --apply >/dev/null 2>&1
R="$(cat "$T/ROADMAP.md")"
printf '%s' "$R" | grep -q '`#8`' && pass "RLS.2 → #8 (after max existing #7)" || fail "RLS.2 not #8"
printf '%s' "$R" | grep -q 'Landing hero `#9`' && pass "WEB.1 → #9" || fail "WEB.1 not #9"
printf '%s' "$R" | grep -q 'Cleanup `#10`' && pass "DEVTOOL.3 → #10" || fail "DEVTOOL.3 not #10"
printf '%s' "$R" | grep -q 'Already numeric `#7`' && pass "existing §5 id #7 preserved" || fail "#7 changed"
printf '%s' "$R" | grep -q 'blocked_by:#8' && pass "blocked_by:RLS.2 → blocked_by:#8" || fail "blocked_by not rewritten"
grep -q '`#8`' "$T/IN_PROGRESS.md" && pass "IN_PROGRESS rewritten" || fail "IN_PROGRESS not rewritten"
[ -f "$T/.plan/8.md" ] && [ -f "$T/.plan/9.md" ] && pass ".plan files renamed (8.md, 9.md)" || fail ".plan not renamed"
[ ! -f "$T/.plan/RLS.2.md" ] && pass "old .plan removed" || fail "old .plan remains"

# --- idempotent: second --check is clean ---
bash "$MIG" "$T" --check >/dev/null 2>&1; [ "$?" -eq 0 ] && pass "idempotent (--check exit 0 after apply)" || fail "not idempotent"
rm -rf "$T"

# --- out of scope: a non-§5-LAYOUT ROADMAP (no P0/P1/P2) is NOT flagged (that's F74) ---
T2="$(mktemp -d)"; T2="$(cd "$T2" && pwd -P)"; mkdir -p "$T2"
printf '# Roadmap\n## Backlog\n### TASK-1 Alta\n- [ ] do it `TASK-1`\n' > "$T2/ROADMAP.md"
bash "$MIG" "$T2" --check >/dev/null 2>&1; [ "$?" -eq 0 ] && pass "non-§5 LAYOUT not flagged (F74 territory, exit 0)" || fail "non-§5 layout wrongly flagged"
rm -rf "$T2"

echo ""
if [ "$fails" -eq 0 ]; then echo "migrate-task-ids: all assertions passed."; exit 0
else echo "migrate-task-ids: $fails assertion(s) failed."; exit 1; fi
