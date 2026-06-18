#!/usr/bin/env bash
#
# Regression test for TASK_016 Phase 2: the `atelier()` shell function shipped in
# install.sh's shellrc block must (a) be valid shell, (b) open bare `atelier`
# with /atelier:orient, and (c) honor an --no-orient escape hatch.
#
# Run:  hooks/tests/atelier-shellrc-orient.test.sh
# Exit: 0 = pass, 1 = fail.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

FN="$TMP/atelier-fn.sh"
awk '/^atelier\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$INSTALL" > "$FN"

grep -q 'atelier()' "$FN" && pass "extracted atelier() from install.sh" || { fail "could not extract atelier()"; echo "$fails failed"; exit 1; }
bash -n "$FN" && pass "atelier() is valid shell" || fail "atelier() has a syntax error"
grep -qF '/atelier:orient' "$FN" && pass "bare atelier wires /atelier:orient" || fail "no /atelier:orient wiring"
grep -qF -- '--no-orient' "$FN" && pass "honors --no-orient escape hatch" || fail "no --no-orient escape hatch"
# the no-args guard must gate the orient injection
grep -qE '\[ "\$#" -eq 0 \]' "$FN" && pass "guards on no-args" || fail "missing no-args guard"

echo ""
if [ "$fails" -eq 0 ]; then echo "atelier() shellrc orient wiring: all assertions passed."; exit 0
else echo "atelier() shellrc orient wiring: $fails assertion(s) failed."; exit 1; fi
