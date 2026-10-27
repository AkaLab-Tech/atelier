#!/usr/bin/env bash
#
# atelier — PreToolUse tamper guard for the operator-consent state (#638 / #639).
# Blocks any Bash / Edit / Write / MultiEdit / NotebookEdit / Read call whose tool
# input references `state/consent` or the resolved
# $ATELIER_CONFIG_DIR/state/consent path, so an agent cannot read pending
# records, forge a grant, or rewrite the ledger. Not consent-eligible itself.
#
# Residual gap (documented in PLAN.md §3): hooks run as the same OS user, and an
# obfuscated write (string pieces, variable indirection, a script written then
# run) can evade this text-level check. The template's
# Edit/Write(**/state/consent/**) deny is a second layer, not a closure.
#
# Contract: stdin JSON { tool_name, tool_input }; exit 0 allow, exit 2 block.
# jq missing -> fail open (like the other block-* hooks).

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="block-consent-tamper"

input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$tool_name" in
  Bash|Edit|Write|MultiEdit|NotebookEdit|Read) ;;
  *) exit 0 ;;
esac

strings="$(printf '%s' "$input" | jq -r '[.tool_input // {} | .. | strings] | join("\n")' 2>/dev/null || true)"
[ -n "$strings" ] || exit 0

resolved="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}/state/consent"
lower="$(printf '%s' "$strings" | tr '[:upper:]' '[:lower:]')"
resolved_lower="$(printf '%s' "$resolved" | tr '[:upper:]' '[:lower:]')"

if printf '%s' "$lower" | grep -Fq 'state/consent' || printf '%s' "$lower" | grep -Fq "$resolved_lower"; then
  cat >&2 <<MSG
🚫 atelier:block-consent-tamper BLOCKED
   Tool:    $tool_name
   Reason:  the call references the operator-consent state directory (state/consent)
   Rule:    PLAN.md §3 "Operator consent override (#638)" — consent state is written only by atelier's hooks, never by tool calls.
   Override: none from inside this session.
MSG
  log_decision "$HOOK_NAME" "$tool_name" "consent-state" "block" "tool input references state/consent"
  exit 2
fi

exit 0
