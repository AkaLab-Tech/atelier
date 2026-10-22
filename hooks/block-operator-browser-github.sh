#!/usr/bin/env bash
#
# atelier — PreToolUse hook on the Claude in Chrome MCP tools
# (mcp__claude-in-chrome__*, plus any plugin-namespaced variant). Blocks any
# call that targets GitHub, so an agent cannot act as the operator through the
# operator's logged-in Chrome (post a review, approve, comment, read private
# pages). Agents use `gh` under the atelier identity for everything GitHub.
#
# Why this hook exists (#544): Claude in Chrome drives the operator's real
# Chrome profile, which is logged in to GitHub as the operator. The Bash-side
# guard (block-operator-gh-identity.sh) cannot see this path.
#
# Blocked: any string in the tool input (url, javascript_tool code, typed text,
# queries, ...) that references github.com, any *.github.com or api.github.com.
# That covers `navigate`, `tabs_create_mcp` and every other URL-taking call,
# and `javascript_tool` code mentioning GitHub (fetch / XHR included).
#
# Residual gaps (documented in PLAN.md §3): link-click navigation inside an
# already-open page and javascript_tool run against a tab that is ALREADY on
# GitHub (the hook does not see tab URLs); redirectors; obfuscated hosts.
# Strongest control: the operator revokes github.com in the Claude in Chrome
# extension's site permissions. This hook is defense in depth.
#
# Contract per Claude Code hooks reference (PreToolUse):
#   stdin  — JSON: { tool_name, tool_input: { ... } }
#   exit 0 — allow;  exit 2 — block (stderr explains)
#   jq missing — fail OPEN (exit 0).

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="block-operator-browser-github"

input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"

case "$tool_name" in
  mcp__claude-in-chrome__*|mcp__plugin_*claude-in-chrome*) ;;
  *) exit 0 ;;
esac

strings="$(printf '%s' "$input" | jq -r '[.tool_input // {} | .. | strings] | join("\n")' 2>/dev/null || true)"
[ -n "$strings" ] || exit 0

github_re='(^|[^a-z0-9-])([a-z0-9-]+\.)*github\.com($|[^a-z0-9-])'
if printf '%s' "$strings" | tr '[:upper:]' '[:lower:]' | grep -Eq "$github_re"; then
  cat >&2 <<MSG
🚫 atelier:block-operator-browser-github BLOCKED
   Tool:    $tool_name
   Reason:  the call references github.com / *.github.com / api.github.com
   Detail:  Claude in Chrome runs in the operator's own browser profile, logged in to GitHub as the operator; anything done there is done as the operator.
   Rule:    PLAN.md §3 / operator-rules.md — agents never act under the operator's GitHub identity, and agents do not browse GitHub in Chrome at all (read-only included).
   Action:  use \`gh\` under the atelier identity for GitHub (PRs, reviews, issues, API reads). For any other site, continue in Chrome.
   Override: none from inside this session.
MSG
  log_decision "$HOOK_NAME" "$tool_name" "github-in-chrome" "block" "tool input references GitHub"
  exit 2
fi

exit 0
