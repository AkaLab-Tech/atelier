#!/usr/bin/env bash
#
# Regression test for #728 — hooks/readd-context-mode-block.sh (SubagentStart).
#
#   A1  context-mode usable -> additionalContext is exactly the rendered block
#   A2  output shape: only hookSpecificOutput{hookEventName:SubagentStart,additionalContext};
#       no permissionDecision / decision keys
#   A3  no hold: the perl Time::HiRes=sleep hold path is not invoked (probe, not wall clock)
#   A4  fail open, no output: not installed / module missing / module throws /
#       block without <context_window_protection> / node missing
#
# Hermetic: scratch HOME + ATELIER_CONFIG_DIR, fake context-mode tree. The real
# context-mode cache is never read. No network.
#
# Run:  hooks/tests/readd-context-mode-block.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/readd-context-mode-block.sh"

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

# Hold probe: logs any `perl -MTime::HiRes=sleep` call (the strip hook's hold
# mechanism), then runs the real perl (absolute path baked in).
REAL_PERL="$(command -v perl)"
HOLD_LOG="$TMP/hold.log"
mkdir -p "$TMP/shim"
cat > "$TMP/shim/perl" <<SHIM
#!/bin/sh
case "\$*" in *Time::HiRes=sleep*) echo hold >> "$HOLD_LOG" ;; esac
exec "$REAL_PERL" "\$@"
SHIM
chmod +x "$TMP/shim/perl"

NONODE="$TMP/nonode"; mkdir -p "$NONODE"
for t in bash env jq cat dirname sed tr grep; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -s "$p" "$NONODE/$t"
done
ln -s "$TMP/shim/perl" "$NONODE/perl"

IN='{"hook_event_name":"SubagentStart","agent_type":"general-purpose"}'

# run_hook [PATH override] -> sets out, rc, elapsed, held
run_hook() {
  local s e
  : > "$HOLD_LOG"
  s="$(now_ms)"
  if [ -n "${1:-}" ]; then
    out="$(printf '%s' "$IN" | PATH="$1" "$NONODE/bash" "$HOOK" 2>/dev/null)"; rc=$?
  else
    out="$(printf '%s' "$IN" | PATH="$TMP/shim:$PATH" bash "$HOOK" 2>/dev/null)"; rc=$?
  fi
  e="$(now_ms)"; elapsed=$((e - s))
  if [ -s "$HOLD_LOG" ]; then held=yes; else held=no; fi
}

echo "readd-context-mode-block (#728)"

write_cm; install_cm
run_hook

# A1
if [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')" = "$BLOCK" ]; then
  pass "A1 additionalContext equals the rendered block"; else fail "A1: rc=$rc out=[$out]"; fi

# A2
if [ "$(printf '%s' "$out" | jq -c '[keys, (.hookSpecificOutput|keys), .hookSpecificOutput.hookEventName]')" \
     = '[["hookSpecificOutput"],["additionalContext","hookEventName"],"SubagentStart"]' ] \
   && ! grep -Eq -- 'permissionDecision|"decision"' <<<"$out"; then
  pass "A2 shape: hookSpecificOutput{hookEventName,additionalContext}, no decision keys"; else fail "A2: [$out]"; fi

# A3
if [ "$held" = no ] && [ "$elapsed" -lt 10000 ]; then pass "A3 no hold (hold path not invoked, ${elapsed}ms)"; else fail "A3: held=$held ${elapsed}ms"; fi

# A4
check_open() {
  if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "A4 $1 -> exit 0, no output"; else fail "A4 $1: rc=$rc out=[$out]"; fi
}
uninstall_cm; run_hook; check_open "not installed"
write_cm; install_cm; rm -f "$CM/hooks/core/tool-naming.mjs"; run_hook; check_open "module missing"
write_cm '(() => { throw new Error("boom"); })()'; install_cm; run_hook; check_open "module throws"
write_cm '"no protection tags here"'; install_cm; run_hook; check_open "block lacks <context_window_protection>"
write_cm; install_cm
if PATH="$NONODE" command -v node >/dev/null 2>&1; then
  echo "  SKIP: A4 node missing (could not build node-less PATH)"
else
  run_hook "$NONODE"; check_open "node missing"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
