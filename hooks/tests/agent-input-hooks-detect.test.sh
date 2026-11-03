#!/usr/bin/env bash
#
# Regression test for #689 — atelier-agent-input-hooks detect.
#
#   D1  no enabledPlugins                      -> empty, exit 0
#   D2  context-mode with Agent matcher        -> known=context-mode tested=yes
#   D3  disabled plugin                        -> not listed
#   D4  project settings.local.json disables   -> honoured
#   D5  unknown plugin, Agent|Task             -> known=unknown
#   D6  "*" and "" match; Bash / mcp__.* don't
#   D7  version 1.0.170                        -> tested=no
#   D8  malformed hooks.json                   -> skipped, exit 0
#   D9  atelier's own hooks/hooks.json         -> not listed
#   D10 --json parses
#   D11 inline plugin.json hooks object        -> detected
#
# Hermetic: scratch HOME + ATELIER_CONFIG_DIR, fixture plugin trees. No network.
#
# Run:  hooks/tests/agent-input-hooks-detect.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/atelier-agent-input-hooks"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

export HOME="$TMP/home"; mkdir -p "$HOME"
export ATELIER_CONFIG_DIR="$TMP/cfg"
unset CLAUDE_PROJECT_DIR

# reset: fresh config dir with empty installed_plugins.json and settings.json.
reset() {
  rm -rf "$ATELIER_CONFIG_DIR" "$TMP/plugins" "$TMP/proj"
  mkdir -p "$ATELIER_CONFIG_DIR/plugins" "$TMP/plugins"
  echo '{"version":2,"plugins":{}}' > "$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
  echo '{}' > "$ATELIER_CONFIG_DIR/settings.json"
}

# add_plugin <key> <version> <hooks.json content|NONE>  (does not enable it)
add_plugin() {
  local key="$1" ver="$2" hooks="$3" dir="$TMP/plugins/${1%%@*}-$2"
  mkdir -p "$dir/hooks"
  [ "$hooks" = NONE ] || printf '%s' "$hooks" > "$dir/hooks/hooks.json"
  local f="$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
  jq --arg k "$key" --arg v "$ver" --arg p "$dir" \
    '.plugins[$k] = [{scope:"user",installPath:$p,version:$v}]' "$f" > "$f.new" && mv "$f.new" "$f"
}

# enable <key>...
enable() {
  local f="$ATELIER_CONFIG_DIR/settings.json" k
  for k in "$@"; do
    jq --arg k "$k" '.enabledPlugins[$k] = true' "$f" > "$f.new" && mv "$f.new" "$f"
  done
}

hooks_for() { printf '{"hooks":{"PreToolUse":[{"matcher":"%s","hooks":[{"type":"command","command":"x"}]}]}}' "$1"; }

run_detect() { "$HELPER" detect "$@" 2>/dev/null; }

echo "atelier-agent-input-hooks detect (#689)"

# D1
reset
out="$(run_detect)"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "D1 no enabledPlugins -> empty, exit 0"; else fail "D1: rc=$rc out=[$out]"; fi

# D2
CM_MATCHER='Bash|WebFetch|Read|Grep|Agent|Task|mcp__plugin_context-mode_context-mode__ctx_execute'
reset
add_plugin context-mode@context-mode 1.0.169 "$(hooks_for "$CM_MATCHER")"
enable context-mode@context-mode
out="$(run_detect)"; rc=$?
exp="$(printf 'context-mode@context-mode\tcontext-mode\t1.0.169\t%s\tcontext-mode\tyes' "$CM_MATCHER")"
if [ "$rc" = 0 ] && [ "$out" = "$exp" ]; then pass "D2 context-mode -> known=context-mode tested=yes"; else fail "D2: rc=$rc out=[$out]"; fi

# D3
reset
add_plugin context-mode@context-mode 1.0.169 "$(hooks_for Agent)"
echo '{"enabledPlugins":{"context-mode@context-mode":false}}' > "$ATELIER_CONFIG_DIR/settings.json"
out="$(run_detect)"
if [ -z "$out" ]; then pass "D3 disabled plugin not listed"; else fail "D3: [$out]"; fi

# D4
reset
add_plugin context-mode@context-mode 1.0.169 "$(hooks_for Agent)"
enable context-mode@context-mode
mkdir -p "$TMP/proj/.claude"
echo '{"enabledPlugins":{"context-mode@context-mode":false}}' > "$TMP/proj/.claude/settings.local.json"
out_user="$(run_detect)"
out_proj="$(run_detect --project "$TMP/proj")"
if [ -n "$out_user" ] && [ -z "$out_proj" ]; then pass "D4 project settings.local.json disable honoured"; else fail "D4: user=[$out_user] proj=[$out_proj]"; fi

# D5
reset
add_plugin other@mkt 2.0.0 "$(hooks_for 'Agent|Task')"
enable other@mkt
out="$(run_detect)"
if [ "$out" = "$(printf 'other@mkt\tother\t2.0.0\tAgent|Task\tunknown\tno')" ]; then pass "D5 unknown plugin -> unknown"; else fail "D5: [$out]"; fi

# D6
for m in '*' ''; do
  reset
  add_plugin p@mkt 1.0.0 "$(hooks_for "$m")"; enable p@mkt
  out="$(run_detect)"
  if grep -q -- '^p@mkt' <<<"$out"; then pass "D6 matcher '$m' matches"; else fail "D6 matcher '$m': [$out]"; fi
done
for m in 'Bash' 'mcp__.*'; do
  reset
  add_plugin p@mkt 1.0.0 "$(hooks_for "$m")"; enable p@mkt
  out="$(run_detect)"
  if [ -z "$out" ]; then pass "D6 matcher '$m' does not match"; else fail "D6 matcher '$m': [$out]"; fi
done

# D7
reset
add_plugin context-mode@context-mode 1.0.170 "$(hooks_for Agent)"; enable context-mode@context-mode
out="$(run_detect)"
if [ "$out" = "$(printf 'context-mode@context-mode\tcontext-mode\t1.0.170\tAgent\tcontext-mode\tno')" ]; then pass "D7 1.0.170 -> tested=no"; else fail "D7: [$out]"; fi

# D8
reset
add_plugin bad@mkt 1.0.0 '{ this is not json'
add_plugin good@mkt 1.0.0 "$(hooks_for Agent)"
enable bad@mkt good@mkt
out="$(run_detect)"; rc=$?
if [ "$rc" = 0 ] && ! grep -q -- '^bad@mkt' <<<"$out" && grep -q -- '^good@mkt' <<<"$out"; then
  pass "D8 malformed hooks.json skipped, exit 0"; else fail "D8: rc=$rc out=[$out]"; fi

# D9
reset
add_plugin atelier@akalab-tech 0.37.0 "$(cat "$REPO_ROOT/hooks/hooks.json")"
enable atelier@akalab-tech
out="$(run_detect)"; rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "D9 atelier's own hooks.json not listed"; else fail "D9: rc=$rc out=[$out]"; fi

# D10
reset
add_plugin context-mode@context-mode 1.0.169 "$(hooks_for Agent)"; enable context-mode@context-mode
js="$(run_detect --json)"
if [ "$(printf '%s' "$js" | jq -r 'length')" = 1 ] \
  && [ "$(printf '%s' "$js" | jq -r '.[0] | [.plugin,.name,.version,.matcher,.known,.tested] | join(",")')" = "context-mode@context-mode,context-mode,1.0.169,Agent,context-mode,yes" ]; then
  pass "D10 --json parses with expected fields"; else fail "D10: [$js]"; fi
reset
js="$(run_detect --json)"
if [ "$js" = "[]" ]; then pass "D10 --json empty -> []"; else fail "D10 empty: [$js]"; fi

# D11 inline plugin.json hooks object
reset
add_plugin inline@mkt 3.1.0 NONE
dir="$TMP/plugins/inline-3.1.0"; mkdir -p "$dir/.claude-plugin"
echo '{"name":"inline","hooks":{"PreToolUse":[{"matcher":"Task","hooks":[{"type":"command","command":"x"}]}]}}' > "$dir/.claude-plugin/plugin.json"
enable inline@mkt
out="$(run_detect)"
if [ "$out" = "$(printf 'inline@mkt\tinline\t3.1.0\tTask\tunknown\tno')" ]; then pass "D11 inline plugin.json hooks detected"; else fail "D11: [$out]"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
