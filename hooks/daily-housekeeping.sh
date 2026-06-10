#!/usr/bin/env bash
#
# atelier — SessionStart hook that nudges the operator, at most once per
# calendar day, to run the worktree/branch housekeeping sweep.
#
# This hook is deliberately CHEAP and FAIL-OPEN: it touches no git or gh,
# only a date stamp under $ATELIER_CONFIG_DIR. The real enumeration (which
# does hit git/gh) and the operator-authorized deletion live in the
# `atelier-housekeeping` helper, invoked via /atelier:housekeeping. Keeping
# the hook lightweight avoids adding latency or permission prompts to every
# session start.
#
# Per the Claude Code SessionStart hook contract, text printed to stdout
# becomes session context. We print a single nudge line and stamp today's
# date so the nudge does not re-fire for the rest of the day. Wired by
# hooks/hooks.json in this same plugin.

set -euo pipefail

ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
STAMP_FILE="$ATELIER_CONFIG_DIR/housekeeping-last-check"

# Fail soft: without a config dir atelier is not installed for this session;
# stay silent rather than block the session.
[ -d "$ATELIER_CONFIG_DIR" ] || exit 0

TODAY="$(date +%F 2>/dev/null || true)"
[ -n "$TODAY" ] || exit 0   # date unavailable → say nothing

LAST=""
[ -f "$STAMP_FILE" ] && LAST="$(head -n1 "$STAMP_FILE" 2>/dev/null || true)"

# Already nudged or swept today → silent.
[ "$LAST" = "$TODAY" ] && exit 0

# Record today's date so the nudge fires at most once per calendar day,
# regardless of whether the operator actually runs the sweep.
printf '%s\n' "$TODAY" > "$STAMP_FILE" 2>/dev/null || true

cat <<'EOF'
[atelier] Daily housekeeping is due. Run /atelier:housekeeping to review
orphan worktrees and merged/closed task branches (local + remote) across your
registered projects. It only enumerates and asks first — nothing is deleted
without your explicit authorization.
EOF
