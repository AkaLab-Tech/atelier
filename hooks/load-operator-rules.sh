#!/usr/bin/env bash
#
# atelier — SessionStart hook that loads operator-rules.md into Claude's
# session context.
#
# Per the Claude Code SessionStart hook contract, any text this script
# prints to stdout becomes context available to Claude for the entire
# session. Wired by hooks/hooks.json in this same plugin.
#
# CLAUDE_PLUGIN_ROOT is set by Claude Code at hook execution time and
# points at the installed plugin's root directory. See
# https://code.claude.com/docs/en/plugins-reference#environment-variables.

set -euo pipefail

RULES_FILE="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/operator-rules.md"

if [ ! -f "$RULES_FILE" ]; then
  # Fail soft: print a one-line note to stderr (does NOT enter the model
  # context) and exit 0 so the session is not blocked by a missing rules
  # file. Hard-failing would lock the operator out of every session.
  printf '!! atelier: operator-rules.md not found at %s\n' "$RULES_FILE" >&2
  exit 0
fi

cat "$RULES_FILE"
