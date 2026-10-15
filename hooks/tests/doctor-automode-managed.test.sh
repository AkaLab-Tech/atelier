#!/usr/bin/env bash
#
# Regression test for #456 — atelier-doctor check_atelier_automode_managed().
#
#   M1 managed entry in sync            -> OK, no fix
#   M2 entry missing                    -> WARN + manual fix line "/atelier:update", settings.json NOT written
#   M3 entry stale                      -> WARN + manual fix, file byte-identical
#   M4 invalid JSON settings            -> SKIP, no fix, file untouched
#   M5 settings.json missing            -> SKIP, no fix
#   M6 helper or template missing       -> SKIP
#   M7 helper failure (bad template)    -> SKIP
#   M8 push_fix_auto is never called in any scenario
#
# Hermetic: the function is extracted from scripts/atelier-doctor into a
# scratch plugin-shaped tree (scripts/ + templates/) and run with push_* stubs
# against fixtures in a scratch ATELIER_CONFIG_DIR. No network.
#
# Run:  hooks/tests/doctor-automode-managed.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/atelier-doctor"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# Plugin-shaped tree so the function finds the helper/template next to itself.
TREE="$TMP/plugin"; mkdir -p "$TREE/scripts" "$TREE/templates"
cp "$REPO_ROOT/scripts/atelier-automode-sync" "$TREE/scripts/atelier-automode-sync"
cp "$REPO_ROOT/templates/automode.user.json" "$TREE/templates/automode.user.json"
chmod +x "$TREE/scripts/atelier-automode-sync"

FN_FILE="$TREE/scripts/fns.sh"
awk '/^check_atelier_automode_managed\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' "$DOCTOR" > "$FN_FILE"
grep -q 'check_atelier_automode_managed()' "$FN_FILE" || { echo "  FAIL: could not extract check_atelier_automode_managed from $DOCTOR"; exit 1; }
# shellcheck disable=SC1090
source "$FN_FILE"

HOST_OUT="$TMP/host_out"; AUTO_OUT="$TMP/auto_out"; MANUAL_OUT="$TMP/manual_out"
push_host()       { printf '%s\n' "$*" >> "$HOST_OUT"; }
push_fix_auto()   { printf '%s\n' "$*" >> "$AUTO_OUT"; }
push_fix_manual() { printf '%s\n' "$*" >> "$MANUAL_OUT"; }
export OK="OKMARK" WARN="WARNMARK" SKIP="SKIPMARK" FAIL="FAILMARK"

# scenario <name> <settings-json|NONE>; sets ATELIER_CONFIG_DIR, runs the check.
scenario() {
  rm -f "$HOST_OUT" "$AUTO_OUT" "$MANUAL_OUT"
  ATELIER_CONFIG_DIR="$TMP/$1"; mkdir -p "$ATELIER_CONFIG_DIR"
  [ "$2" = NONE ] || printf '%s\n' "$2" > "$ATELIER_CONFIG_DIR/settings.json"
  check_atelier_automode_managed
  [ ! -s "$AUTO_OUT" ] && pass "M8/$1: no push_fix_auto registered" || fail "M8/$1: auto fix registered: $(cat "$AUTO_OUT")"
}

echo "atelier-doctor check_atelier_automode_managed (#456)"
MANAGED="$(jq -c '.autoMode.allow[0]' "$TREE/templates/automode.user.json")"

# M1
scenario m1 "$(jq -nc --argjson m "$MANAGED" '{autoMode:{allow:["$defaults",$m]}}')"
grep -q '^OKMARK managed autoMode gate-run rule in sync' "$HOST_OUT" && [ ! -s "$MANUAL_OUT" ] \
  && pass "M1: in sync -> OK, no fix line" || fail "M1: (host: $(cat "$HOST_OUT") manual: $(cat "$MANUAL_OUT" 2>/dev/null))"

# M2
scenario m2 '{"autoMode":{"allow":["$defaults","Operator rule"]},"model":"opus"}'
cp "$ATELIER_CONFIG_DIR/settings.json" "$TMP/m2.orig"
grep -q '^WARNMARK managed autoMode gate-run rule missing or stale' "$HOST_OUT" \
  && pass "M2: missing entry -> WARN" || fail "M2: (host: $(cat "$HOST_OUT"))"
grep -q '^/atelier:update' "$MANUAL_OUT" \
  && pass "M2: manual fix line points at /atelier:update" || fail "M2: manual: $(cat "$MANUAL_OUT" 2>/dev/null)"
scenario m2 '{"autoMode":{"allow":["$defaults","Operator rule"]},"model":"opus"}'
cmp -s "$ATELIER_CONFIG_DIR/settings.json" "$TMP/m2.orig" \
  && [ -z "$(find "$ATELIER_CONFIG_DIR" -name 'settings.json.atelier.*')" ] \
  && pass "M2: settings.json not written, no temp files" || fail "M2: file changed or temp left"

# M3
scenario m3 '{"autoMode":{"allow":["$defaults","[atelier-managed:gate-runs] stale old text"]}}'
before="$(cat "$ATELIER_CONFIG_DIR/settings.json")"
grep -q '^WARNMARK' "$HOST_OUT" && grep -q '^/atelier:update' "$MANUAL_OUT" \
  && pass "M3: stale entry -> WARN + manual fix" || fail "M3: (host: $(cat "$HOST_OUT"))"
[ "$before" = "$(cat "$ATELIER_CONFIG_DIR/settings.json")" ] && pass "M3: file untouched" || fail "M3: file changed"

# M4
scenario m4 '{ not json'
grep -q '^SKIPMARK .*not valid JSON' "$HOST_OUT" && [ ! -s "$MANUAL_OUT" ] && [ "$(cat "$ATELIER_CONFIG_DIR/settings.json")" = '{ not json' ] \
  && pass "M4: invalid JSON -> SKIP, no fix, file untouched" || fail "M4: (host: $(cat "$HOST_OUT" 2>/dev/null))"

# M5
scenario m5 NONE
grep -q '^SKIPMARK .*missing' "$HOST_OUT" && [ ! -s "$MANUAL_OUT" ] && [ ! -e "$ATELIER_CONFIG_DIR/settings.json" ] \
  && pass "M5: settings.json missing -> SKIP, not created" || fail "M5: (host: $(cat "$HOST_OUT" 2>/dev/null))"

# M6
mv "$TREE/templates/automode.user.json" "$TREE/templates/automode.user.json.bak"
scenario m6 '{}'
grep -q '^SKIPMARK .*not found next to this script' "$HOST_OUT" && [ ! -s "$MANUAL_OUT" ] \
  && pass "M6: template missing -> SKIP" || fail "M6: (host: $(cat "$HOST_OUT" 2>/dev/null))"
mv "$TREE/templates/automode.user.json.bak" "$TREE/templates/automode.user.json"

# M7
cp "$TREE/templates/automode.user.json" "$TMP/tmpl.good"
printf '{"autoMode":{"allow":"not-an-array"}}\n' > "$TREE/templates/automode.user.json"
scenario m7 '{}'
grep -q '^SKIPMARK .*atelier-automode-sync failed, rc=2' "$HOST_OUT" && [ ! -s "$MANUAL_OUT" ] \
  && pass "M7: helper failure (rc 2) -> SKIP, no fix" || fail "M7: (host: $(cat "$HOST_OUT" 2>/dev/null))"
cp "$TMP/tmpl.good" "$TREE/templates/automode.user.json"

echo ""
if [ "$fails" -eq 0 ]; then echo "doctor-automode-managed: all assertions passed."; exit 0
else echo "doctor-automode-managed: $fails assertion(s) failed."; exit 1; fi
