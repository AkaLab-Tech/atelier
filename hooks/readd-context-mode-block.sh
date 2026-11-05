#!/usr/bin/env bash
#
# atelier hook: readd-context-mode-block (#728), SubagentStart (every subagent)
#
# Counterpart of strip-context-mode-agent-block.sh: delivers context-mode's routing block to
# the subagent as additionalContext, rendered at runtime from the installed context-mode.
# Fails open: no usable context-mode or any error -> no output, exit 0.

set -uo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0
cat >/dev/null 2>&1 || true

block="$("${CLAUDE_PLUGIN_ROOT:?}/scripts/atelier-agent-input-hooks" render-block 2>/dev/null)" || exit 0
case "$block" in *"<context_window_protection>"*) ;; *) exit 0 ;; esac

jq -n -c --rawfile b <(printf '%s' "$block") \
  '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: $b}}'
exit 0
