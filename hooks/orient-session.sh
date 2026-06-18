#!/usr/bin/env bash
#
# atelier — SessionStart hook that prints a cheap, prioritized "what to do next"
# for the session's project directory. Per the Claude Code SessionStart contract,
# stdout becomes session context (same as load-operator-rules.sh), so the model
# leads its first reply with it. TASK_016 Phase 1.
#
# Deliberately CHEAP + FAIL-OPEN: it delegates to `atelier-orient`, which reads
# only the filesystem + jq (no `gh`, no remote `git`) — matching the discipline
# of daily-housekeeping.sh so session start gains no latency or permission prompts.

set -uo pipefail

ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
# atelier not installed for this session → stay silent.
[ -d "$ATELIER_CONFIG_DIR" ] || exit 0

# Resolve the helper: prefer PATH, else the plugin's own scripts dir.
orient="$(command -v atelier-orient 2>/dev/null || true)"
[ -n "$orient" ] || orient="${CLAUDE_PLUGIN_ROOT:-}/scripts/atelier-orient"
[ -x "$orient" ] || exit 0

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
out="$("$orient" "$dir" 2>/dev/null || true)"
[ -n "$out" ] || exit 0

printf '%s\n' "$out"
printf '\nWhen you greet the operator, open with the single suggested next step above (one line); offer the rest only if asked.\n'
