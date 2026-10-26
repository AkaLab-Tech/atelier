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
#   M9  (#633) allow in sync, environment entries missing -> environment WARN + fix
#   M10 (#633) environment entry stale -> environment WARN, file byte-identical
#   M11 (#633) environment in sync, allow stale -> allow WARN only
#   M12 (#633) only environment stale (allow + soft_deny in sync) -> environment WARN only, no allow WARN
#   M13 (#633) soft_deny stale / missing -> soft_deny WARN only + fix, file byte-identical
#   P1  (#633) hand-written trusted-repo entry naming a gone path -> WARN + --replace-path fix
#   P2  same, no registered candidate -> WARN + edit-the-entry fix
#   P3  managed / non-trust / absent environment entries -> OK, no warning
#   P4  stale-path check is read-only and never registers an auto fix
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
FN2_FILE="$TREE/scripts/fns2.sh"
awk '/^check_automode_environment_stale_paths\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' "$DOCTOR" > "$FN2_FILE"
grep -q 'check_automode_environment_stale_paths()' "$FN2_FILE" || { echo "  FAIL: could not extract check_automode_environment_stale_paths from $DOCTOR"; exit 1; }
# shellcheck disable=SC1090
source "$FN2_FILE"

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
WA="$(jq -c '.autoMode.allow' "$TREE/templates/automode.user.json")"
# No projects.json in the scratch config dir -> placeholder renders as below.
# shellcheck disable=SC2016  # jq program, not shell
WE="$(jq -c '.autoMode.environment | map(gsub("\\{\\{registered_projects\\}\\}"; "(no project registered yet)"))' "$TREE/templates/automode.user.json")"
WS="$(jq -c '.autoMode.soft_deny' "$TREE/templates/automode.user.json")"
IN_SYNC="$(jq -nc --argjson a "$WA" --argjson e "$WE" --argjson s "$WS" '{autoMode:{allow:(["$defaults"]+$a),environment:(["$defaults"]+$e),soft_deny:(["$defaults"]+$s)}}')"

# M1
scenario m1 "$IN_SYNC"
grep -q '^OKMARK managed autoMode gate-run rule in sync' "$HOST_OUT" && [ ! -s "$MANUAL_OUT" ] && ! grep -q '^WARNMARK' "$HOST_OUT" \
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

grep -q '^WARNMARK managed autoMode environment entries' "$HOST_OUT" \
  && pass "M2: missing environment entries -> second WARN (trusted repos, flows)" || fail "M2: no environment WARN (host: $(cat "$HOST_OUT"))"

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

# M9: allow in sync, environment array absent
scenario m9 "$(jq -nc --argjson a "$WA" --argjson s "$WS" '{autoMode:{allow:(["$defaults"]+$a),soft_deny:(["$defaults"]+$s)}}')"
grep -q '^WARNMARK managed autoMode environment entries (trusted repos, flows) missing or stale' "$HOST_OUT" && grep -q '^/atelier:update' "$MANUAL_OUT" \
  && pass "M9: missing environment entries -> environment WARN + /atelier:update fix" || fail "M9: (host: $(cat "$HOST_OUT"))"

# M10: environment stale (old trusted-repos text), allow in sync
scenario m10 "$(jq -nc --argjson a "$WA" --argjson e "$WE" --argjson s "$WS" '{autoMode:{allow:(["$defaults"]+$a),environment:(["$defaults", "[atelier-managed:trusted-repos] OLD stale text", $e[1]]),soft_deny:(["$defaults"]+$s)}}')"
before="$(cat "$ATELIER_CONFIG_DIR/settings.json")"
grep -q '^WARNMARK managed autoMode environment entries' "$HOST_OUT" && grep -q '^/atelier:update' "$MANUAL_OUT" \
  && pass "M10: stale environment entry -> environment WARN + manual fix" || fail "M10: (host: $(cat "$HOST_OUT"))"
[ "$before" = "$(cat "$ATELIER_CONFIG_DIR/settings.json")" ] && [ -z "$(find "$ATELIER_CONFIG_DIR" -name 'settings.json.atelier.*')" ] \
  && pass "M10: settings.json untouched, no temp files" || fail "M10: file changed"

# M11: environment in sync, allow stale
scenario m11 "$(jq -nc --argjson e "$WE" --argjson s "$WS" '{autoMode:{allow:["$defaults","[atelier-managed:gate-runs] stale old text"],environment:(["$defaults"]+$e),soft_deny:(["$defaults"]+$s)}}')"
grep -q '^WARNMARK managed autoMode gate-run rule missing or stale' "$HOST_OUT" && ! grep -q 'environment entries' "$HOST_OUT" && ! grep -q 'soft_deny entries' "$HOST_OUT" \
  && pass "M11: only the allow WARN when the environment entries are in sync" || fail "M11: (host: $(cat "$HOST_OUT"))"

# M12: only environment stale -> exactly one WARN (environment), no allow WARN
scenario m12 "$(jq -nc --argjson a "$WA" --argjson e "$WE" --argjson s "$WS" '{autoMode:{allow:(["$defaults"]+$a),environment:(["$defaults", "[atelier-managed:trusted-repos] OLD stale text", $e[1]]),soft_deny:(["$defaults"]+$s)}}')"
before="$(cat "$ATELIER_CONFIG_DIR/settings.json")"
[ "$(grep -c '^WARNMARK' "$HOST_OUT")" -eq 1 ] && grep -q '^WARNMARK managed autoMode environment entries' "$HOST_OUT" \
  && ! grep -q 'gate-run rule' "$HOST_OUT" && ! grep -q '(allow entries)' "$HOST_OUT" && ! grep -q 'soft_deny' "$HOST_OUT" \
  && grep -q '^/atelier:update' "$MANUAL_OUT" \
  && pass "M12: only-stale environment prints only the environment WARN (no allow, no soft_deny WARN)" || fail "M12: (host: $(cat "$HOST_OUT"))"
[ "$before" = "$(cat "$ATELIER_CONFIG_DIR/settings.json")" ] && pass "M12: file untouched" || fail "M12: file changed"

# M13: soft_deny stale (then missing) with allow + environment in sync -> soft_deny WARN only
scenario m13 "$(jq -nc --argjson a "$WA" --argjson e "$WE" '{autoMode:{allow:(["$defaults"]+$a),environment:(["$defaults"]+$e),soft_deny:["$defaults","[atelier-managed:dispatch-other] OLD stale text"]}}')"
before="$(cat "$ATELIER_CONFIG_DIR/settings.json")"
[ "$(grep -c '^WARNMARK' "$HOST_OUT")" -eq 1 ] && grep -q '^WARNMARK managed autoMode soft_deny entries missing or stale' "$HOST_OUT" \
  && ! grep -q '(allow entries)' "$HOST_OUT" && ! grep -q 'environment entries' "$HOST_OUT" && grep -q '^/atelier:update' "$MANUAL_OUT" \
  && pass "M13: stale soft_deny entry -> soft_deny WARN only + /atelier:update fix" || fail "M13: (host: $(cat "$HOST_OUT"))"
[ "$before" = "$(cat "$ATELIER_CONFIG_DIR/settings.json")" ] && [ -z "$(find "$ATELIER_CONFIG_DIR" -name 'settings.json.atelier.*')" ] \
  && pass "M13: settings.json untouched, no temp files" || fail "M13: file changed"
scenario m13b "$(jq -nc --argjson a "$WA" --argjson e "$WE" '{autoMode:{allow:(["$defaults"]+$a),environment:(["$defaults"]+$e)}}')"
[ "$(grep -c '^WARNMARK' "$HOST_OUT")" -eq 1 ] && grep -q '^WARNMARK managed autoMode soft_deny entries missing or stale' "$HOST_OUT" \
  && pass "M13: absent soft_deny array -> soft_deny WARN only" || fail "M13b: (host: $(cat "$HOST_OUT"))"

# ---- check_automode_environment_stale_paths (#633) ------------------------
GONE="/Users/nobody-atelier-test/Work/gone-proj"
[ ! -e "$GONE" ] || { echo "  FAIL: fixture path $GONE unexpectedly exists"; exit 1; }
stale() {  # stale <name> <settings-json> [projects-json]
  rm -f "$HOST_OUT" "$AUTO_OUT" "$MANUAL_OUT"
  ATELIER_CONFIG_DIR="$TMP/$1"; mkdir -p "$ATELIER_CONFIG_DIR"
  printf '%s\n' "$2" > "$ATELIER_CONFIG_DIR/settings.json"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$ATELIER_CONFIG_DIR/projects.json"
  cp "$ATELIER_CONFIG_DIR/settings.json" "$TMP/$1.orig"
  check_automode_environment_stale_paths
  [ ! -s "$AUTO_OUT" ] && cmp -s "$ATELIER_CONFIG_DIR/settings.json" "$TMP/$1.orig" \
    && pass "P4/$1: no auto fix, settings.json byte-identical" || fail "P4/$1: auto fix or file changed"
}
HAND="$(jq -nc --arg g "$GONE" '{autoMode:{environment:["$defaults", ("Trusted repo: " + $g + " (origin acme/gone-proj) is mine.")]}}')"

# P1: candidate registered under the same basename
mkdir -p "$TMP/moved/gone-proj"
stale p1 "$HAND" "$(jq -nc --arg p "$TMP/moved/gone-proj" '{projects:{($p):{}}}')"
grep -q "^WARNMARK user settings trusted-repo entry names $GONE, which no longer exists" "$HOST_OUT" \
  && pass "P1: gone trusted-repo path -> WARN naming it" || fail "P1: (host: $(cat "$HOST_OUT"))"
grep -qF "atelier-automode-sync --replace-path $GONE=$TMP/moved/gone-proj" "$MANUAL_OUT" \
  && pass "P1: fix offers --replace-path OLD=NEW with the registered same-name project" || fail "P1: manual: $(cat "$MANUAL_OUT" 2>/dev/null)"

# P2: no registered candidate
stale p2 "$HAND"
grep -q "^WARNMARK .*names $GONE" "$HOST_OUT" && grep -q "^edit the trusted-repo entry in $ATELIER_CONFIG_DIR/settings.json" "$MANUAL_OUT" \
  && ! grep -q -- '--replace-path' "$MANUAL_OUT" \
  && pass "P2: no candidate -> WARN + edit-or-remove fix, no --replace-path" || fail "P2: (host: $(cat "$HOST_OUT") manual: $(cat "$MANUAL_OUT" 2>/dev/null))"

# P3: not flagged -> OK
stale p3a "$(jq -nc --arg g "$GONE" '{autoMode:{environment:["[atelier-managed:trusted-repos] Trusted repositories: " + $g + " (origin acme/x)"]}}')"
grep -q '^OKMARK no hand-written trusted-repo entry' "$HOST_OUT" && ! grep -q '^WARNMARK' "$HOST_OUT" && [ ! -s "$MANUAL_OUT" ] \
  && pass "P3: a managed entry naming a gone path is not flagged" || fail "P3a: (host: $(cat "$HOST_OUT"))"
stale p3b "$(jq -nc --arg g "$GONE" '{autoMode:{environment:[("Scratch notes live in " + $g)]}}')"
grep -q '^OKMARK' "$HOST_OUT" && ! grep -q '^WARNMARK' "$HOST_OUT" \
  && pass "P3: an unmarked entry that is not about repos/trust is not flagged" || fail "P3b: (host: $(cat "$HOST_OUT"))"
stale p3c '{"autoMode":{"allow":["$defaults"]}}'
grep -q '^OKMARK' "$HOST_OUT" && ! grep -q '^WARNMARK' "$HOST_OUT" \
  && pass "P3: no environment array -> OK" || fail "P3c: (host: $(cat "$HOST_OUT"))"

echo ""
if [ "$fails" -eq 0 ]; then echo "doctor-automode-managed: all assertions passed."; exit 0
else echo "doctor-automode-managed: $fails assertion(s) failed."; exit 1; fi
