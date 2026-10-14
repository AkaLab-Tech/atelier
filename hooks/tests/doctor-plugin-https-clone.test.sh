#!/usr/bin/env bash
#
# Regression test for #442 — atelier-doctor check_plugin_https_clone().
#
#   D1 github entries + no env            → FAIL + auto fix registered
#   D2 github entries + env "1"           → OK, no fix
#   D3 https url entries + no env         → OK, no fix
#   D4 marketplace.json missing           → SKIP, no fix
#   D5 registered fix writes the key and preserves other keys (also when
#      settings.json is absent); after the fix the check reports OK
#   D6 only atelier/claude-roadmap-tools entries count (other github plugins ignored)
#
# Hermetic: the function is extracted from scripts/atelier-doctor and run with
# push_* stubs against fixtures in a scratch ATELIER_CONFIG_DIR. No network.
#
# Run:  hooks/tests/doctor-plugin-https-clone.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/atelier-doctor"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

FN_FILE="$TMP/fns.sh"
awk '/^check_plugin_https_clone\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' "$DOCTOR" > "$FN_FILE"
grep -q 'check_plugin_https_clone()' "$FN_FILE" || { echo "  FAIL: could not extract check_plugin_https_clone from $DOCTOR"; exit 1; }
# shellcheck disable=SC1090
source "$FN_FILE"

PLUGIN_OUT="$TMP/plugin_out"; FIX_OUT="$TMP/fix_out"
push_plugin()     { printf '%s\n' "$*" >> "$PLUGIN_OUT"; }
push_fix_auto()   { printf '%s\n' "$*" >> "$FIX_OUT"; }
OK="✓"; FAIL="✗"; SKIP="–"

# scenario <name> <marketplace-json|NONE> <settings-json|NONE>; sets ATELIER_CONFIG_DIR.
scenario() {
  rm -f "$PLUGIN_OUT" "$FIX_OUT"
  ATELIER_CONFIG_DIR="$TMP/$1"
  mkdir -p "$ATELIER_CONFIG_DIR/plugins/marketplaces/akalab-tech/.claude-plugin"
  [ "$2" = NONE ] || printf '%s\n' "$2" > "$ATELIER_CONFIG_DIR/plugins/marketplaces/akalab-tech/.claude-plugin/marketplace.json"
  [ "$3" = NONE ] || printf '%s\n' "$3" > "$ATELIER_CONFIG_DIR/settings.json"
  check_plugin_https_clone
}

GH='{"plugins":[{"name":"atelier","source":{"source":"github","repo":"AkaLab-Tech/atelier"}},{"name":"claude-roadmap-tools","source":{"source":"github","repo":"AkaLab-Tech/claude-roadmap-tools"}}]}'
URL='{"plugins":[{"name":"atelier","source":{"source":"url","url":"https://github.com/AkaLab-Tech/atelier.git"}},{"name":"claude-roadmap-tools","source":{"source":"url","url":"https://github.com/AkaLab-Tech/claude-roadmap-tools.git"}}]}'
OTHER='{"plugins":[{"name":"neon-integration","source":{"source":"github","repo":"AkaLab-Tech/neon"}},{"name":"atelier","source":"./"}]}'

echo "atelier-doctor check_plugin_https_clone (#442)"

scenario d1 "$GH" '{"permissions":{"defaultMode":"auto"}}'
grep -q "^$FAIL plugin updates will clone over SSH" "$PLUGIN_OUT" \
  && pass "D1: github source + no env -> FAIL" || fail "D1: expected FAIL (got: $(cat "$PLUGIN_OUT"))"
[ "$(wc -l < "$FIX_OUT" 2>/dev/null | tr -d ' ')" = "1" ] \
  && grep -q 'CLAUDE_CODE_PLUGIN_PREFER_HTTPS' "$FIX_OUT" \
  && pass "D1: exactly one auto fix registered, mentions the env key" || fail "D1: fix missing (got: $(cat "$FIX_OUT" 2>/dev/null))"

scenario d2 "$GH" '{"env":{"CLAUDE_CODE_PLUGIN_PREFER_HTTPS":"1"}}'
grep -q "^$OK plugin updates clone over HTTPS" "$PLUGIN_OUT" && [ ! -f "$FIX_OUT" ] \
  && pass "D2: github source + env=1 -> OK, no fix" || fail "D2: got $(cat "$PLUGIN_OUT") / fix: $(cat "$FIX_OUT" 2>/dev/null)"

scenario d3 "$URL" NONE
grep -q "^$OK plugin updates clone over HTTPS" "$PLUGIN_OUT" && [ ! -f "$FIX_OUT" ] \
  && pass "D3: https url sources + no env -> OK, no fix" || fail "D3: got $(cat "$PLUGIN_OUT") / fix: $(cat "$FIX_OUT" 2>/dev/null)"

scenario d4 NONE NONE
grep -q "^$SKIP plugin HTTPS clone" "$PLUGIN_OUT" && [ ! -f "$FIX_OUT" ] \
  && pass "D4: marketplace.json missing -> SKIP, no fix" || fail "D4: got $(cat "$PLUGIN_OUT" 2>/dev/null)"

scenario d6 "$OTHER" NONE
grep -q "^$OK " "$PLUGIN_OUT" && [ ! -f "$FIX_OUT" ] \
  && pass "D6: github sources of other plugins / relative atelier source ignored -> OK" || fail "D6: got $(cat "$PLUGIN_OUT")"

# D5: run the registered fix with settings.json present, then absent.
scenario d5 "$GH" '{"permissions":{"defaultMode":"auto"},"env":{"KEEP":"x"}}'
bash -c "$(cat "$FIX_OUT")"; frc=$?
S="$ATELIER_CONFIG_DIR/settings.json"
[ "$frc" -eq 0 ] && [ "$(jq -r '.env.CLAUDE_CODE_PLUGIN_PREFER_HTTPS' "$S")" = "1" ] \
  && pass "D5: fix writes env.CLAUDE_CODE_PLUGIN_PREFER_HTTPS=\"1\"" || fail "D5: fix rc=$frc, settings: $(cat "$S")"
[ "$(jq -r '.permissions.defaultMode' "$S")" = "auto" ] && [ "$(jq -r '.env.KEEP' "$S")" = "x" ] \
  && pass "D5: fix preserves permissions.defaultMode and env.KEEP" || fail "D5: keys lost: $(cat "$S")"
rm -f "$PLUGIN_OUT" "$FIX_OUT"; check_plugin_https_clone
grep -q "^$OK plugin updates clone over HTTPS" "$PLUGIN_OUT" \
  && pass "D5: after the fix the check reports OK" || fail "D5: still not OK: $(cat "$PLUGIN_OUT")"
ls "$ATELIER_CONFIG_DIR"/settings.json.atelier.* >/dev/null 2>&1 \
  && fail "D5: temp file left behind" || pass "D5: no temp file left behind"

scenario d5b "$GH" NONE
bash -c "$(cat "$FIX_OUT")"; frc=$?
[ "$frc" -eq 0 ] && [ "$(jq -c . "$ATELIER_CONFIG_DIR/settings.json")" = '{"env":{"CLAUDE_CODE_PLUGIN_PREFER_HTTPS":"1"}}' ] \
  && pass "D5: fix creates settings.json when absent" || fail "D5b: rc=$frc, $(cat "$ATELIER_CONFIG_DIR/settings.json" 2>&1)"

echo ""
if [ "$fails" -eq 0 ]; then echo "doctor-plugin-https-clone: all assertions passed."; exit 0
else echo "doctor-plugin-https-clone: $fails assertion(s) failed."; exit 1; fi
