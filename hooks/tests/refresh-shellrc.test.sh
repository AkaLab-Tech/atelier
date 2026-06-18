#!/usr/bin/env bash
#
# Test for `install.sh --refresh-shellrc` (TASK_016 / atelier-update shellrc
# propagation): it re-injects ONLY the shellrc hook block, is idempotent, and
# atelier-update wires the call so shellrc changes ship without a full re-install.
#
# Run:  hooks/tests/refresh-shellrc.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
UPDATE="$REPO_ROOT/scripts/atelier-update"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"; CFG="$TMP/home/cfg"; mkdir -p "$CFG"
RC="$HOME_DIR/.zshrc"; : > "$RC"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

refresh() { SHELL=/bin/zsh HOME="$HOME_DIR" bash "$INSTALL" --config-dir "$CFG" --refresh-shellrc >/dev/null 2>&1; }

# --- first injection ---
refresh && pass "--refresh-shellrc exits 0" || fail "--refresh-shellrc non-zero"
[ "$(grep -c '>>> atelier hooks' "$RC")" = "1" ] && pass "injects exactly one block" || fail "block count != 1"
grep -q "export ATELIER_CONFIG_DIR=\"$CFG\"" "$RC" && pass "config dir substituted" || fail "config dir not substituted"
grep -q '# atelier-hooks-version: 6' "$RC" && pass "block is version 6 (bumped for atelier() orient)" || fail "block version not 6"
grep -q '/atelier:orient' "$RC" && pass "atelier() opens with /atelier:orient" || fail "atelier() missing orient wiring"

# --- idempotent: second run does not duplicate ---
refresh
[ "$(grep -c '>>> atelier hooks' "$RC")" = "1" ] && pass "idempotent — still one block" || fail "second run duplicated the block"
[ "$(grep -c '# atelier-hooks-version:' "$RC")" = "1" ] && pass "idempotent — one version line" || fail "second run duplicated version line"

# --- did NOT do the heavy install (no deps/auth) — block-only, fast ---
grep -q 'fnm' "$RC" && pass "shellrc still has the full block content (fnm hook)" || fail "block content incomplete"

# --- atelier-update wires the refresh ---
grep -q -- '--refresh-shellrc' "$UPDATE" && pass "atelier-update calls install.sh --refresh-shellrc" || fail "atelier-update does not wire the refresh"

echo ""
if [ "$fails" -eq 0 ]; then echo "refresh-shellrc: all assertions passed."; exit 0
else echo "refresh-shellrc: $fails assertion(s) failed."; exit 1; fi
