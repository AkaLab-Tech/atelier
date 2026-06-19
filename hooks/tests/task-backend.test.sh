#!/usr/bin/env bash
#
# Test for atelier-task-backend (M9.1): resolve a project's roadmap backend from
# .roadmap.json, defaulting to `files`. Hermetic.
#
# Run:  hooks/tests/task-backend.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$REPO_ROOT/scripts/atelier-task-backend"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
chk() { local got; got="$(bash "$B" "$2")"; [ "$got" = "$1" ] && pass "$3 (=$got)" || fail "$3: want '$1' got '$got'"; }

D="$TMP/p"; mkdir -p "$D"
chk files "$D" "absent .roadmap.json → files"
echo '{"backend":"linear"}' > "$D/.roadmap.json";          chk linear "$D" "backend=linear"
echo '{"backend":"github-project"}' > "$D/.roadmap.json";   chk github-project "$D" "backend=github-project"
echo '{"backend":"files"}' > "$D/.roadmap.json";            chk files "$D" "backend=files (explicit)"
echo '{}' > "$D/.roadmap.json";                              chk files "$D" "no backend key → files"
printf 'not json{' > "$D/.roadmap.json";                     chk files "$D" "malformed JSON → files (fail-open)"

# exit code is always 0 (fail-open)
bash "$B" "$TMP/does-not-exist" >/dev/null 2>&1 && pass "missing dir → exit 0 (fail-open)" || fail "missing dir non-zero"

echo ""
if [ "$fails" -eq 0 ]; then echo "task-backend: all assertions passed."; exit 0
else echo "task-backend: $fails assertion(s) failed."; exit 1; fi
