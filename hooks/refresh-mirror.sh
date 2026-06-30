#!/usr/bin/env bash
#
# atelier — SessionStart hook that surfaces a one-line instruction to run
# crt's EXISTING offline-mirror auto-refresh for non-`files` repos with
# offlineMirror: true. Per the Claude Code SessionStart hook contract, stdout
# becomes session context (same as orient-session.sh). TASK_034.
#
# Deliberately CHEAP + FAIL-OPEN: delegates all gating and message generation
# to `atelier-refresh-mirror`, which reads only the filesystem + jq (no `gh`,
# no remote `git`) — matching the discipline of orient-session.sh and
# daily-housekeeping.sh so session start gains no latency or permission
# prompts. The actual board read + mirror regen is performed by the AI layer
# acting on the surfaced instruction (crt's roadmap-tracking-flow skill's
# "Mirror auto-refresh on activation" procedure).

set -uo pipefail

ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
# atelier not installed for this session → stay silent.
[ -d "$ATELIER_CONFIG_DIR" ] || exit 0

# Resolve the helper: prefer PATH, else the plugin's own scripts dir.
refresh="$(command -v atelier-refresh-mirror 2>/dev/null || true)"
[ -n "$refresh" ] || refresh="${CLAUDE_PLUGIN_ROOT:-}/scripts/atelier-refresh-mirror"
[ -x "$refresh" ] || exit 0

dir="${CLAUDE_PROJECT_DIR:-$PWD}"
out="$("$refresh" "$dir" 2>/dev/null || true)"
[ -n "$out" ] || exit 0

printf '%s\n' "$out"
