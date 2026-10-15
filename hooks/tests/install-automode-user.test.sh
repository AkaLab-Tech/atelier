#!/usr/bin/env bash
#
# Regression test for #456 — install.sh phase_c_1_atelier_automode_allow
# writes the managed autoMode rule into $ATELIER_CONFIG_DIR/settings.json
# ONLY with the operator's explicit y on an interactive prompt.
#
#   I1 no TTY (stdin /dev/null, NONINTERACTIVE=false) -> skip with a notice, nothing written
#   I2 --yes (NONINTERACTIVE=true), even with "y" on stdin -> never applied
#   I3 interactive, answer y -> applied (["$defaults", managed])
#   I4 interactive, answer N / empty / other -> not applied, "apply later" hint
#   I5 already in sync -> skip, no prompt; operator entries preserved on apply
#   I6 invalid JSON settings -> untouched, returns 0
#   I7 scratch HOME untouched, no temp files
#
# Interactive branch is reached via the ATELIER_TEST_FORCE_TTY=1 seam (answer
# read from stdin). Hermetic: scratch HOME + ATELIER_CONFIG_DIR; no network.
#
# Run:  hooks/tests/install-automode-user.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
mkdir -p "$TMP/home"

echo "install.sh phase_c_1_atelier_automode_allow (#456)"

MANAGED="$(jq -c '.autoMode.allow[0]' "$REPO_ROOT/templates/automode.user.json")"

# run_phase <cfg> <noninteractive true|false> <force_tty 0|1> <stdin-text>
run_phase() {
  local cfg="$1" ni="$2" force="$3" input="$4"
  (
    export HOME="$TMP/home" ATELIER_CONFIG_DIR="$cfg" NO_COLOR=1 ATELIER_SOURCE_ROOT="$REPO_ROOT" NONINTERACTIVE="$ni"
    [ "$force" = 1 ] && export ATELIER_TEST_FORCE_TTY=1
    # shellcheck disable=SC1090
    source "$INSTALL"
    NONINTERACTIVE="$ni"
    phase_c_1_atelier_automode_allow
    echo "RC=$?"
  ) 2>&1 <<< "$input"
}
# Same but with stdin from /dev/null (no TTY, no seam).
run_phase_notty() {
  local cfg="$1" ni="$2"
  (
    export HOME="$TMP/home" ATELIER_CONFIG_DIR="$cfg" NO_COLOR=1 ATELIER_SOURCE_ROOT="$REPO_ROOT"
    # shellcheck disable=SC1090
    source "$INSTALL"
    NONINTERACTIVE="$ni"
    phase_c_1_atelier_automode_allow
    echo "RC=$?"
  ) 2>&1 </dev/null
}

# I1
CFG="$TMP/i1"; mkdir -p "$CFG"
out="$(run_phase_notty "$CFG" false)"
[ ! -e "$CFG/settings.json" ] && pass "I1: no TTY -> nothing written" || fail "I1: settings.json created"
printf '%s' "$out" | grep -q 'not applied' && printf '%s' "$out" | grep -q 'RC=0' \
  && pass "I1: skip notice printed, returns 0" || fail "I1: (out: $out)"
printf '%s' "$out" | grep -q 'atelier-automode-sync --apply' && pass "I1: tells how to apply later" || fail "I1: no later hint (out: $out)"

# I2
CFG="$TMP/i2"; mkdir -p "$CFG"
out="$(run_phase "$CFG" true 0 "y")"
[ ! -e "$CFG/settings.json" ] && pass "I2: --yes / non-interactive never applies, even with y on stdin" || fail "I2: settings.json created: $(cat "$CFG/settings.json")"

# I3
CFG="$TMP/i3"; mkdir -p "$CFG"
out="$(run_phase "$CFG" false 1 "y")"
[ "$(jq -c '.autoMode.allow' "$CFG/settings.json" 2>/dev/null)" = "$(jq -nc --argjson m "$MANAGED" '["$defaults",$m]')" ] \
  && pass "I3: y -> [\"\$defaults\", managed] written" || fail "I3: got $(cat "$CFG/settings.json" 2>&1) (out: $out)"
printf '%s' "$out" | grep -q '\[y/N\]' && printf '%s' "$out" | grep -qF '+ [gate-runs]' \
  && pass "I3: showed the diff and the y/N prompt before writing" || fail "I3: (out: $out)"

# I4
for ans in "N" "n" "" "maybe"; do
  CFG="$TMP/i4-${ans:-empty}"; mkdir -p "$CFG"
  out="$(run_phase "$CFG" false 1 "$ans")"
  [ ! -e "$CFG/settings.json" ] && printf '%s' "$out" | grep -q 'not applied' \
    && pass "I4: answer '$ans' -> not applied, hint printed" || fail "I4: '$ans' (out: $out)"
done

# I5
out="$(run_phase "$TMP/i3" false 1 "y")"
printf '%s' "$out" | grep -q 'already in sync' && ! printf '%s' "$out" | grep -q '\[y/N\]' \
  && pass "I5: in sync -> skip without prompting" || fail "I5: (out: $out)"
CFG="$TMP/i5"; mkdir -p "$CFG"
printf '{"autoMode":{"allow":["Mine 1","$defaults","Mine 2"]},"model":"opus"}\n' > "$CFG/settings.json"
run_phase "$CFG" false 1 "y" >/dev/null
[ "$(jq -c '.autoMode.allow' "$CFG/settings.json")" = "$(jq -nc --argjson m "$MANAGED" '["Mine 1","$defaults","Mine 2",$m]')" ] \
  && [ "$(jq -r .model "$CFG/settings.json")" = opus ] \
  && pass "I5: operator entries and other keys preserved on apply" || fail "I5: got $(cat "$CFG/settings.json")"

# I6
CFG="$TMP/i6"; mkdir -p "$CFG"
printf '{ not json' > "$CFG/settings.json"
out="$(run_phase "$CFG" false 1 "y")"
[ "$(cat "$CFG/settings.json")" = '{ not json' ] && printf '%s' "$out" | grep -q 'RC=0' \
  && pass "I6: invalid JSON untouched, returns 0" || fail "I6: (out: $out)"

# I7
[ -z "$(ls -A "$TMP/home")" ] && pass "I7: scratch HOME untouched" || fail "I7: HOME touched: $(ls -A "$TMP/home")"
leftover="$(find "$TMP" -name 'settings.json.atelier.*' | head -1)"
[ -z "$leftover" ] && pass "I7: no temp files left behind" || fail "I7: leftover $leftover"

echo ""
if [ "$fails" -eq 0 ]; then echo "install-automode-user: all assertions passed."; exit 0
else echo "install-automode-user: $fails assertion(s) failed."; exit 1; fi
