#!/usr/bin/env bash
#
# Regression test for #442 — install.sh phase_c_1_plugin_prefer_https merges
# env.CLAUDE_CODE_PLUGIN_PREFER_HTTPS="1" into $ATELIER_CONFIG_DIR/settings.json.
#
#   P1 absent file        → created with only the env key
#   P2 existing keys      → preserved (permissions.defaultMode, other env keys)
#   P3 already set        → no-op (byte-identical file, "already set" skip line)
#   P4 invalid JSON       → left untouched + warning, function returns 0
#   P5 wrong value ("0")  → corrected to "1"
#   P6 no temp files left behind; real ~/.claude and git config never touched
#
# Hermetic: sources install.sh (main-gated) in subshells under a scratch
# HOME + ATELIER_CONFIG_DIR. No network.
#
# Run:  hooks/tests/install-plugin-prefer-https.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "install.sh phase_c_1_plugin_prefer_https (#442)"

# run_phase <cfg-dir> — runs the phase in a subshell; combined output on stdout.
run_phase() {
  (
    export HOME="$TMP/home" ATELIER_CONFIG_DIR="$1" NO_COLOR=1
    # shellcheck disable=SC1090
    source "$INSTALL"
    phase_c_1_plugin_prefer_https
    echo "RC=$?"
  ) 2>&1
}
mkdir -p "$TMP/home"

# P1
CFG="$TMP/p1"; mkdir -p "$CFG"
out="$(run_phase "$CFG")"
[ "$(jq -c . "$CFG/settings.json" 2>/dev/null)" = '{"env":{"CLAUDE_CODE_PLUGIN_PREFER_HTTPS":"1"}}' ] \
  && pass "P1: absent settings.json created with only the env key" || fail "P1: got $(cat "$CFG/settings.json" 2>&1) (out: $out)"
printf '%s' "$out" | grep -q 'set env.CLAUDE_CODE_PLUGIN_PREFER_HTTPS' \
  && pass "P1: logs the write" || fail "P1: no write log (out: $out)"

# P2
CFG="$TMP/p2"; mkdir -p "$CFG"
printf '{"permissions":{"defaultMode":"auto"},"env":{"KEEP":"x"},"model":"opus"}\n' > "$CFG/settings.json"
run_phase "$CFG" >/dev/null
[ "$(jq -c . "$CFG/settings.json")" = '{"permissions":{"defaultMode":"auto"},"env":{"KEEP":"x","CLAUDE_CODE_PLUGIN_PREFER_HTTPS":"1"},"model":"opus"}' ] \
  && pass "P2: existing keys preserved, env key added" || fail "P2: got $(cat "$CFG/settings.json")"

# P3
before="$(cat "$CFG/settings.json")"
out="$(run_phase "$CFG")"
[ "$before" = "$(cat "$CFG/settings.json")" ] \
  && pass "P3: already set -> file byte-identical" || fail "P3: file changed"
printf '%s' "$out" | grep -q 'already set' \
  && pass "P3: reports 'already set' skip" || fail "P3: no skip line (out: $out)"

# P4
CFG="$TMP/p4"; mkdir -p "$CFG"
printf '{ not json' > "$CFG/settings.json"
out="$(run_phase "$CFG")"
[ "$(cat "$CFG/settings.json")" = '{ not json' ] \
  && pass "P4: invalid JSON left untouched" || fail "P4: file rewritten: $(cat "$CFG/settings.json")"
printf '%s' "$out" | grep -q 'not valid JSON' && printf '%s' "$out" | grep -q 'RC=0' \
  && pass "P4: warns and returns 0" || fail "P4: (out: $out)"

# P5
CFG="$TMP/p5"; mkdir -p "$CFG"
printf '{"env":{"CLAUDE_CODE_PLUGIN_PREFER_HTTPS":"0"}}\n' > "$CFG/settings.json"
run_phase "$CFG" >/dev/null
[ "$(jq -r '.env.CLAUDE_CODE_PLUGIN_PREFER_HTTPS' "$CFG/settings.json")" = "1" ] \
  && pass "P5: wrong value \"0\" corrected to \"1\"" || fail "P5: got $(cat "$CFG/settings.json")"

# P6
leftover="$(find "$TMP/p1" "$TMP/p2" "$TMP/p4" "$TMP/p5" -name 'settings.json.atelier.*' | head -1)"
[ -z "$leftover" ] && pass "P6: no temp files left behind" || fail "P6: leftover $leftover"
[ ! -e "$TMP/home/.claude" ] && [ ! -e "$TMP/home/.gitconfig" ] \
  && pass "P6: nothing written to ~/.claude or git config" || fail "P6: scratch HOME was touched: $(ls -A "$TMP/home")"

echo ""
if [ "$fails" -eq 0 ]; then echo "install-plugin-prefer-https: all assertions passed."; exit 0
else echo "install-plugin-prefer-https: $fails assertion(s) failed."; exit 1; fi
