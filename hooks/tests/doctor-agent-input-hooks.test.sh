#!/usr/bin/env bash
#
# Regression test for #689 — atelier-doctor check_agent_input_hooks().
#
#   C1 no matching plugin                 -> OK line
#   C2 context-mode in tested range       -> WARN with version + range
#   C3 context-mode outside tested range  -> WARN containing "outside"
#   C4 unknown plugin matching Agent      -> WARN naming plugin + matcher
#   C5 MANUAL_OUT and the fix arrays stay empty in every scenario
#   C6 helper not found                   -> SKIP
#
# Hermetic: function extracted from scripts/atelier-doctor, push_* stubbed,
# the real helper reached through a PATH shim, scratch HOME/ATELIER_CONFIG_DIR.
# No network.
#
# Run:  hooks/tests/doctor-agent-input-hooks.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/atelier-doctor"
HELPER="$REPO_ROOT/scripts/atelier-agent-input-hooks"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

export HOME="$TMP/home"; mkdir -p "$HOME"
export ATELIER_CONFIG_DIR="$TMP/cfg"
unset CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT

FN_FILE="$TMP/fns.sh"
awk '/^check_agent_input_hooks\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' "$DOCTOR" > "$FN_FILE"
grep -q 'check_agent_input_hooks()' "$FN_FILE" || { echo "  FAIL: could not extract function from $DOCTOR"; exit 1; }
# shellcheck disable=SC1090
source "$FN_FILE"

HOST_OUT="$TMP/host_out"; MANUAL_OUT="$TMP/manual_out"
FIX_BLOCKS=(); FIX_AUTO_COMMANDS=()
push_host()       { printf '%s\n' "$*" >> "$HOST_OUT"; }
push_fix_manual() { printf '%s\n' "$*" >> "$MANUAL_OUT"; }
export OK="OKMARK" WARN="WARNMARK" SKIP="SKIPMARK" FAIL="FAILMARK"

# PATH shim exposing the real helper (and no `claude`, so no CC suffix).
SHIM="$TMP/shim"; mkdir -p "$SHIM"
ln -s "$HELPER" "$SHIM/atelier-agent-input-hooks"
BASE_PATH="$PATH"

reset_cfg() {
  rm -rf "$ATELIER_CONFIG_DIR" "$TMP/plugins"
  mkdir -p "$ATELIER_CONFIG_DIR/plugins" "$TMP/plugins"
  echo '{"version":2,"plugins":{}}' > "$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
  echo '{}' > "$ATELIER_CONFIG_DIR/settings.json"
  rm -f "$HOST_OUT" "$MANUAL_OUT"; touch "$HOST_OUT" "$MANUAL_OUT"
}

# install_enabled <key> <version> <matcher>
install_enabled() {
  local key="$1" ver="$2" m="$3" dir="$TMP/plugins/${1%%@*}-$2"
  mkdir -p "$dir/hooks"
  printf '{"hooks":{"PreToolUse":[{"matcher":"%s","hooks":[{"type":"command","command":"x"}]}]}}' "$m" > "$dir/hooks/hooks.json"
  local f="$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
  jq --arg k "$key" --arg v "$ver" --arg p "$dir" '.plugins[$k] = [{scope:"user",installPath:$p,version:$v}]' "$f" > "$f.new" && mv "$f.new" "$f"
  f="$ATELIER_CONFIG_DIR/settings.json"
  jq --arg k "$key" '.enabledPlugins[$k] = true' "$f" > "$f.new" && mv "$f.new" "$f"
}

run_check() { PATH="$SHIM:$BASE_PATH" check_agent_input_hooks; }

no_fixes() { [ ! -s "$MANUAL_OUT" ] && [ "${#FIX_BLOCKS[@]}" -eq 0 ] && [ "${#FIX_AUTO_COMMANDS[@]}" -eq 0 ]; }

echo "atelier-doctor check_agent_input_hooks (#689)"

# C1
reset_cfg
run_check
if [ "$(cat "$HOST_OUT")" = "OKMARK no enabled plugin rewrites Agent/Task input (auto-mode dispatches unaffected)" ] && no_fixes; then
  pass "C1 no matching plugin -> OK"; else fail "C1: $(cat "$HOST_OUT")"; fi

# C2
reset_cfg
install_enabled context-mode@context-mode 1.0.169 'Bash|Agent|Task'
run_check
if [ "$(grep -c WARNMARK "$HOST_OUT")" = 1 ] \
  && grep -q 'WARNMARK context-mode 1.0.169: PreToolUse hook appends' "$HOST_OUT" \
  && grep -q 'tested range 1.0.169–1.0.169' "$HOST_OUT" \
  && ! grep -q outside "$HOST_OUT" && no_fixes; then
  pass "C2 in-range context-mode -> WARN with version and range"; else fail "C2: $(cat "$HOST_OUT")"; fi

# C3
reset_cfg
install_enabled context-mode@context-mode 1.0.170 'Agent'
run_check
if [ "$(grep -c WARNMARK "$HOST_OUT")" = 1 ] \
  && grep -q 'context-mode 1.0.170' "$HOST_OUT" \
  && grep -q 'version 1.0.170 is outside atelier.s tested range 1.0.169–1.0.169' "$HOST_OUT" && no_fixes; then
  pass "C3 out-of-range context-mode -> WARN containing 'outside'"; else fail "C3: $(cat "$HOST_OUT")"; fi

# C4
reset_cfg
install_enabled other@mkt 2.0.0 'Agent|Task'
run_check
if [ "$(grep -c WARNMARK "$HOST_OUT")" = 1 ] \
  && grep -q 'WARNMARK other 2.0.0: PreToolUse hook matches Agent/Task (matcher "Agent|Task")' "$HOST_OUT" && no_fixes; then
  pass "C4 unknown plugin -> WARN naming plugin and matcher"; else fail "C4: $(cat "$HOST_OUT")"; fi

# C5 (explicit, after the WARN scenarios above)
if no_fixes; then pass "C5 MANUAL_OUT and fix arrays stay empty"; else fail "C5: manual=[$(cat "$MANUAL_OUT")] blocks=${#FIX_BLOCKS[@]} auto=${#FIX_AUTO_COMMANDS[@]}"; fi

# C6: helper not found -> SKIP. Doctor-local lookup falls back to the script
# dir of the function's BASH_SOURCE (this test file's dir has no helper), and
# CLAUDE_PLUGIN_ROOT is unset.
reset_cfg
NOHELPER_PATH="$TMP/empty-bin"; mkdir -p "$NOHELPER_PATH"
PATH="$NOHELPER_PATH:/usr/bin:/bin" check_agent_input_hooks
if [ "$(cat "$HOST_OUT")" = "SKIPMARK Agent-input hooks check (atelier-agent-input-hooks not found)" ] && no_fixes; then
  pass "C6 missing helper -> SKIP"; else fail "C6: $(cat "$HOST_OUT")"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
