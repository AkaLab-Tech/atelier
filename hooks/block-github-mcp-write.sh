#!/usr/bin/env bash
#
# atelier — PreToolUse hook on GitHub MCP tools
# (mcp__github__*, plus plugin-namespaced variants). Blocks any write call
# that runs under the operator's personal identity (#544, #648). Agents must
# use `gh` under AtelierAuthor or AtelierReviewer for GitHub writes.
#
# Contract per Claude Code hooks reference (PreToolUse):
#   stdin  — JSON: { tool_name, tool_input: { ... } }
#   exit 0 — allow;  exit 2 — block (stderr explains)
#   jq missing — fail OPEN (exit 0) with warning to stderr.
#

set -uo pipefail

HOOK_NAME="block-github-mcp-write"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/log-decision.sh" ]; then
  # shellcheck source=lib/log-decision.sh
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/log-decision.sh"
elif [ -f "$HOOK_DIR/lib/log-decision.sh" ]; then
  # shellcheck source=lib/log-decision.sh
  source "$HOOK_DIR/lib/log-decision.sh"
fi

if ! declare -f log_decision >/dev/null 2>&1; then
  log_decision() { return 0; }
fi

input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"

case "$tool_name" in
  mcp__github__*|mcp__plugin_*github*) ;;
  *) exit 0 ;;
esac

tool_action="${tool_name##*__}"

# Identity check: If ATELIER_GITHUB_MCP_IDENTITY is set to "author" or "reviewer", allow the call.
identity="${ATELIER_GITHUB_MCP_IDENTITY:-}"
if [ "$identity" = "author" ] || [ "$identity" = "reviewer" ]; then
  log_decision "$HOOK_NAME" "$tool_name" "$tool_action" "allow" "read-only or verified identity"
  exit 0
fi

# Read vs Write partitioning:
# 1. Read tools: evaluate read patterns first (e.g. get_discussion_comments starts with get_).
# mark_all_notifications_read ends with _read but is a write tool (mark_*).
case "$tool_action" in
  mark_*) ;;
  get_*|list_*|search_*|*_read|*_get|*_list|check_*|*similarity_search|*_search)
    log_decision "$HOOK_NAME" "$tool_name" "$tool_action" "allow" "read-only or verified identity"
    exit 0
    ;;
esac

# 2. Write tools: match write patterns or fail closed.
cat >&2 <<MSG
🚫 atelier:block-github-mcp-write BLOCKED
   Tool:    $tool_name
   Action:  $tool_action
   Reason:  GitHub MCP tool runs authenticated as the operator's personal account
   Detail:  GitHub MCP write tools act under the operator's identity, which violates #544.
   Rule:    PLAN.md §3 / operator-rules.md — agents never act under the operator's GitHub identity.
   Action:  Use \`gh\` CLI commands under AtelierAuthor or AtelierReviewer instead.
   Override: none from inside this session (categorical).
MSG

log_decision "$HOOK_NAME" "$tool_name" "$tool_action" "block" "GitHub MCP write tools act under operator identity"
exit 2
