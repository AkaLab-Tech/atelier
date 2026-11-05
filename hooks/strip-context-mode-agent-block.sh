#!/usr/bin/env bash
#
# atelier hook: strip-context-mode-agent-block (#728), PreToolUse/Agent
#
# context-mode rewrites Agent dispatches (appends its routing block to the prompt), which
# auto mode's reviewer can refuse once ("a hook changed this call's input"). This hook
# removes every exact copy of the block from tool_input.prompt; the SubagentStart hook
# (readd-context-mode-block.sh) delivers it to the subagent instead. See
# docs/research/context-mode-agent-strip-2026-11.md.
#
# Fails open: any error, no usable context-mode, or jq missing -> no output, exit 0.
# Never emits permissionDecision and never changes subagent_type.

set -uo pipefail
trap 'exit 0' ERR

# Hold until the strip result is the last hook output: last hook to finish wins (research P2, H8).
HOLD_MS=400

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }
start_ms="$(now_ms)" || exit 0

command -v jq >/dev/null 2>&1 || exit 0
input="$(cat 2>/dev/null || true)"
printf '%s' "$input" | jq -e '.tool_input | type == "object"' >/dev/null 2>&1 || exit 0

block="$("${CLAUDE_PLUGIN_ROOT:?}/scripts/atelier-agent-input-hooks" render-block 2>/dev/null)" || exit 0
case "$block" in *"<context_window_protection>"*) ;; *) exit 0 ;; esac

out="$(printf '%s' "$input" | jq -c --arg b "$block" '
  .tool_input
  | if (.prompt | type) == "string" then .prompt |= (split($b) | join("")) else . end
  | {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: .}}' 2>/dev/null)" || exit 0
[ -n "$out" ] || exit 0

elapsed=$(( $(now_ms) - start_ms ))
if [ "$elapsed" -lt "$HOLD_MS" ]; then
  perl -MTime::HiRes=sleep -e "sleep(($HOLD_MS - $elapsed) / 1000)"
fi
printf '%s\n' "$out"
exit 0
