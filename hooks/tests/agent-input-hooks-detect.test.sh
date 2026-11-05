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
#   H1-H5 handling: neutralised; hooks-not-registered / render-failed /
#         untested-version; other plugins always unhandled (#729)
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
exp="$(printf 'context-mode@context-mode\tcontext-mode\t1.0.169\t%s\tcontext-mode\tyes\tunhandled\thooks-not-registered' "$CM_MATCHER")"
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
if [ "$out" = "$(printf 'other@mkt\tother\t2.0.0\tAgent|Task\tunknown\tno\tunhandled\tother-plugin')" ]; then pass "D5 unknown plugin -> unknown"; else fail "D5: [$out]"; fi

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
if [ "$out" = "$(printf 'context-mode@context-mode\tcontext-mode\t1.0.170\tAgent\tcontext-mode\tno\tunhandled\tuntested-version')" ]; then pass "D7 1.0.170 -> tested=no"; else fail "D7: [$out]"; fi

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

# D9b atelier's own key is never listed, even with an Agent matcher (#728), under any marketplace
reset
add_plugin atelier@akalab-tech 0.37.0 "$(hooks_for Agent)"
add_plugin atelier@other-mkt 0.37.0 "$(hooks_for Agent)"
add_plugin other@mkt 2.0.0 "$(hooks_for Agent)"
enable atelier@akalab-tech atelier@other-mkt other@mkt
out="$(run_detect)"; rc=$?
if [ "$rc" = 0 ] && ! grep -q -- '^atelier@' <<<"$out" && grep -q -- '^other@mkt' <<<"$out"; then
  pass "D9b atelier@* with Agent matcher never listed; other plugins still are"; else fail "D9b: rc=$rc out=[$out]"; fi

# D10
reset
add_plugin context-mode@context-mode 1.0.169 "$(hooks_for Agent)"; enable context-mode@context-mode
js="$(run_detect --json)"
if [ "$(printf '%s' "$js" | jq -r 'length')" = 1 ] \
  && [ "$(printf '%s' "$js" | jq -r '.[0] | [.plugin,.name,.version,.matcher,.known,.tested,.handling,.reason] | join(",")')" = "context-mode@context-mode,context-mode,1.0.169,Agent,context-mode,yes,unhandled,hooks-not-registered" ]; then
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
if [ "$out" = "$(printf 'inline@mkt\tinline\t3.1.0\tTask\tunknown\tno\tunhandled\tother-plugin')" ]; then pass "D11 inline plugin.json hooks detected"; else fail "D11: [$out]"; fi

# handling (#729): fixture context-mode with a renderable routing block
cm_with_render() { # <version> <ok|bad>
  add_plugin context-mode@context-mode "$1" "$(hooks_for Agent)"
  local d="$TMP/plugins/context-mode-$1"; mkdir -p "$d/hooks/core"
  echo 'export const createToolNamer = () => ({});' > "$d/hooks/core/tool-naming.mjs"
  if [ "$2" = ok ]; then
    echo 'export const createRoutingBlock = () => "<context_window_protection>x</context_window_protection>";' > "$d/hooks/routing-block.mjs"
  else
    echo 'export const createRoutingBlock = () => "";' > "$d/hooks/routing-block.mjs"
  fi
  enable context-mode@context-mode
}
atelier_with_hooks() { # <both|strip-only|readd-only>
  local strip='{"matcher":"Agent","hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}\"/hooks/strip-context-mode-agent-block.sh"}]}'
  local readd='{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}\"/hooks/readd-context-mode-block.sh"}]}'
  local pre="[$strip]" sub="[$readd]"
  [ "$1" = readd-only ] && pre='[]'
  [ "$1" = strip-only ] && sub='[]'
  add_plugin atelier@akalab-tech 0.38.0 "{\"hooks\":{\"PreToolUse\":$pre,\"SubagentStart\":$sub}}"
  enable atelier@akalab-tech
}
handling_of() { run_detect --json | jq -r '.[] | select(.name == "context-mode") | .handling + "/" + .reason'; }
command -v node >/dev/null 2>&1 || { echo "  SKIP: node not on PATH (handling cases)"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }

reset; cm_with_render 1.0.169 ok; atelier_with_hooks both
h="$(handling_of)"
if [ "$h" = "neutralised/-" ]; then pass "H1 hooks registered + render ok + tested -> neutralised"; else fail "H1: [$h]"; fi
out="$(run_detect)"
if [ "$(awk -F'\t' '{print $7}' <<<"$out")" = neutralised ]; then pass "H1 TSV column 7 = neutralised"; else fail "H1 tsv: [$out]"; fi

for v in strip-only readd-only; do
  reset; cm_with_render 1.0.169 ok; atelier_with_hooks "$v"
  h="$(handling_of)"
  if [ "$h" = "unhandled/hooks-not-registered" ]; then pass "H2 $v -> hooks-not-registered"; else fail "H2 $v: [$h]"; fi
done

reset; cm_with_render 1.0.169 bad; atelier_with_hooks both
h="$(handling_of)"
if [ "$h" = "unhandled/render-failed" ]; then pass "H3 empty render -> render-failed"; else fail "H3: [$h]"; fi

reset; cm_with_render 1.0.170 ok; atelier_with_hooks both
h="$(handling_of)"
if [ "$h" = "unhandled/untested-version" ]; then pass "H4 untested version -> untested-version"; else fail "H4: [$h]"; fi

reset; add_plugin other@mkt 2.0.0 "$(hooks_for Agent)"; enable other@mkt; atelier_with_hooks both
h="$(run_detect --json | jq -r '.[0].handling')"
if [ "$h" = unhandled ]; then pass "H5 other plugin always unhandled"; else fail "H5: [$h]"; fi

# H3b render-block non-zero exit (routing-block module missing)
reset; cm_with_render 1.0.169 ok; atelier_with_hooks both
rm -f "$TMP/plugins/context-mode-1.0.169/hooks/routing-block.mjs"
h="$(handling_of)"
if [ "$h" = "unhandled/render-failed" ]; then pass "H3b render-block non-zero exit -> render-failed"; else fail "H3b: [$h]"; fi

# H3c render output lacking the <context_window_protection> tag
reset; cm_with_render 1.0.169 ok; atelier_with_hooks both
echo 'export const createRoutingBlock = () => "no tag here";' > "$TMP/plugins/context-mode-1.0.169/hooks/routing-block.mjs"
h="$(handling_of)"
if [ "$h" = "unhandled/render-failed" ]; then pass "H3c output without tag -> render-failed"; else fail "H3c: [$h]"; fi

# H6 strip hook registered on the wrong matcher -> not registered
reset; cm_with_render 1.0.169 ok
add_plugin atelier@akalab-tech 0.38.0 '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"x/hooks/strip-context-mode-agent-block.sh"}]}],"SubagentStart":[{"hooks":[{"type":"command","command":"x/hooks/readd-context-mode-block.sh"}]}]}}'
enable atelier@akalab-tech
h="$(handling_of)"
if [ "$h" = "unhandled/hooks-not-registered" ]; then pass "H6 strip on non-Agent matcher -> hooks-not-registered"; else fail "H6: [$h]"; fi

# H7 atelier installed with both hooks but NOT enabled -> not registered
reset; cm_with_render 1.0.169 ok
add_plugin atelier@akalab-tech 0.38.0 '{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"x/hooks/strip-context-mode-agent-block.sh"}]}],"SubagentStart":[{"hooks":[{"type":"command","command":"x/hooks/readd-context-mode-block.sh"}]}]}}'
h="$(handling_of)"
if [ "$h" = "unhandled/hooks-not-registered" ]; then pass "H7 disabled atelier -> hooks-not-registered"; else fail "H7: [$h]"; fi

# H8 untested version wins over missing hooks (precedence)
reset; cm_with_render 1.0.170 ok
h="$(handling_of)"
if [ "$h" = "unhandled/untested-version" ]; then pass "H8 untested version reported even without hooks"; else fail "H8: [$h]"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
