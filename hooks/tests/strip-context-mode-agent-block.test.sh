#!/usr/bin/env bash
#
# Regression test for #728 — hooks/strip-context-mode-agent-block.sh (PreToolUse/Agent).
#
#   S1  0 copies of the block in prompt   -> updatedInput identical to tool_input
#   S2  1 copy                            -> removed
#   S3  2 copies with text between them   -> both removed, text kept
#   S4  subagent_type "Bash" (and other fields) unchanged
#   S5  output shape: only hookSpecificOutput{hookEventName,updatedInput}; no permissionDecision
#   S6  context-mode usable -> elapsed >= hold threshold (400 ms)
#   S7  fail open, no output, faster than the hold: not installed / module missing /
#       module throws / block without <context_window_protection> / node missing
#
# Hermetic: scratch HOME + ATELIER_CONFIG_DIR, fake context-mode tree. The real
# context-mode cache is never read. No network.
#
# Run:  hooks/tests/strip-context-mode-agent-block.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/strip-context-mode-agent-block.sh"
HOLD_MS=400

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "  SKIP: node not on PATH"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "  SKIP: perl not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

export HOME="$TMP/home"; mkdir -p "$HOME"
export ATELIER_CONFIG_DIR="$TMP/cfg"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
unset CLAUDE_PROJECT_DIR
mkdir -p "$ATELIER_CONFIG_DIR/plugins"

BLOCK='<context_window_protection>
  <rule>use "ctx" & $HOME \ tools</rule>
</context_window_protection>'

CM="$TMP/cm"
# write_cm [js-expression-for-block]  (default: the BLOCK literal)
write_cm() {
  local expr="${1:-}"
  [ -n "$expr" ] || expr="$(printf '%s' "$BLOCK" | jq -Rs .)"
  rm -rf "$CM"; mkdir -p "$CM/hooks/core"
  printf 'export function createRoutingBlock() { return %s; }\n' "$expr" > "$CM/hooks/routing-block.mjs"
  echo 'export function createToolNamer(platform) { return { platform }; }' > "$CM/hooks/core/tool-naming.mjs"
  echo '{"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":"x"}]}]}}' > "$CM/hooks/hooks.json"
}
install_cm() {
  jq -n --arg p "$CM" '{version:2,plugins:{"context-mode@context-mode":[{scope:"user",installPath:$p,version:"1.0.169"}]}}' \
    > "$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
  echo '{"enabledPlugins":{"context-mode@context-mode":true}}' > "$ATELIER_CONFIG_DIR/settings.json"
}
uninstall_cm() {
  echo '{"version":2,"plugins":{}}' > "$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
  echo '{}' > "$ATELIER_CONFIG_DIR/settings.json"
}

# PATH without node: symlinks to the few tools the hook + helper need.
NONODE="$TMP/nonode"; mkdir -p "$NONODE"
for t in bash env jq perl cat dirname sed tr grep; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -s "$p" "$NONODE/$t"
done

# input_for <prompt> [subagent_type] -> hook stdin JSON
input_for() {
  jq -n -c --arg p "$1" --arg t "${2:-general-purpose}" \
    '{hook_event_name:"PreToolUse",tool_name:"Agent",tool_input:{description:"d",prompt:$p,subagent_type:$t}}'
}

# run_hook <stdin-json> [PATH override] -> sets out, rc, elapsed
run_hook() {
  local s e
  s="$(now_ms)"
  if [ -n "${2:-}" ]; then
    out="$(printf '%s' "$1" | PATH="$2" "$NONODE/bash" "$HOOK" 2>/dev/null)"; rc=$?
  else
    out="$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)"; rc=$?
  fi
  e="$(now_ms)"; elapsed=$((e - s))
}

echo "strip-context-mode-agent-block (#728)"

write_cm; install_cm
PRE='Do the task.'

# S1: 0 copies
in="$(input_for "$PRE")"
run_hook "$in"
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -c '.hookSpecificOutput.updatedInput')" = "$(printf '%s' "$in" | jq -c '.tool_input')" ]; then
  pass "S1 0 copies -> updatedInput identical to tool_input"; else fail "S1: rc=$rc out=[$out]"; fi

# S2: 1 copy
run_hook "$(input_for "$PRE$BLOCK")"
got="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.prompt')"
if [ "$rc" = 0 ] && [ "$got" = "$PRE" ]; then pass "S2 1 copy removed"; else fail "S2: rc=$rc got=[$got]"; fi

# S3: 2 copies with text between
run_hook "$(input_for "A${BLOCK}B middle ${BLOCK}C")"
got="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.prompt')"
if [ "$rc" = 0 ] && [ "$got" = "AB middle C" ]; then pass "S3 2 copies removed, text between kept"; else fail "S3: rc=$rc got=[$got]"; fi

# S4: Bash subagent_type and other fields unchanged
run_hook "$(input_for "$PRE$BLOCK" Bash)"
if [ "$(printf '%s' "$out" | jq -c '.hookSpecificOutput.updatedInput | [.subagent_type,.description]')" = '["Bash","d"]' ]; then
  pass "S4 subagent_type Bash and description unchanged"; else fail "S4: [$out]"; fi

# S5: output shape
run_hook "$(input_for "$PRE$BLOCK")"
if [ "$(printf '%s' "$out" | jq -c '[keys, (.hookSpecificOutput|keys), .hookSpecificOutput.hookEventName]')" \
     = '[["hookSpecificOutput"],["hookEventName","updatedInput"],"PreToolUse"]' ] \
   && ! grep -q -- permissionDecision <<<"$out"; then
  pass "S5 shape: hookSpecificOutput{hookEventName,updatedInput}, no permissionDecision"; else fail "S5: [$out]"; fi

# S6: hold
run_hook "$(input_for "$PRE$BLOCK")"
if [ -n "$out" ] && [ "$elapsed" -ge "$HOLD_MS" ]; then pass "S6 elapsed ${elapsed}ms >= ${HOLD_MS}ms"; else fail "S6: elapsed=${elapsed}ms out=[$out]"; fi

# S7: fail open, no hold
check_open() { # <label>
  if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$elapsed" -lt "$HOLD_MS" ]; then
    pass "S7 $1 -> exit 0, no output, ${elapsed}ms < ${HOLD_MS}ms"; else fail "S7 $1: rc=$rc elapsed=${elapsed}ms out=[$out]"; fi
}
IN="$(input_for "$PRE$BLOCK")"

uninstall_cm; run_hook "$IN"; check_open "not installed"

write_cm; install_cm; rm -f "$CM/hooks/routing-block.mjs"; run_hook "$IN"; check_open "module missing"

write_cm '(() => { throw new Error("boom"); })()'; install_cm; run_hook "$IN"; check_open "module throws"

write_cm '"no protection tags here"'; install_cm; run_hook "$IN"; check_open "block lacks <context_window_protection>"

write_cm; install_cm
if PATH="$NONODE" command -v node >/dev/null 2>&1; then
  echo "  SKIP: S7 node missing (could not build node-less PATH)"
else
  run_hook "$IN" "$NONODE"; check_open "node missing"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
