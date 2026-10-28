#!/usr/bin/env bash
#
# atelier — SessionStart hook that injects the bounded project-memory brief
# (#618). stdout becomes session context. Fail-open and silent: no sqlite3, no
# DB, no records or any error -> exit 0 with no output. Read-only: `atelier-memory
# brief` opens the DB read-only and this hook never creates a file.

set -uo pipefail

ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
[ -d "$ATELIER_CONFIG_DIR" ] || exit 0
command -v sqlite3 >/dev/null 2>&1 || exit 0

mem="$(command -v atelier-memory 2>/dev/null || true)"
[ -n "$mem" ] || mem="${CLAUDE_PLUGIN_ROOT:-}/scripts/atelier-memory"
[ -x "$mem" ] || exit 0

out="$("$mem" brief --project "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || true)"
[ -n "$out" ] || exit 0

printf '%s\n' "$out"
exit 0
