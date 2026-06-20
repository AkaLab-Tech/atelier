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

# Operator chat language (atelier-set-language → $ATELIER_CONFIG_DIR/operator.json).
# Emitted FIRST — before the operator-rules.md dump below — on purpose: the rules
# file is ~26 KB, and the harness truncates large hook stdout to a short head
# preview before it enters the model context. A directive appended *after* the
# rules dump lands ~26 KB into the stream, past that cutoff, so the model never
# sees it and defaults to mirroring the operator (usually English) — the bug this
# ordering fixes. Front-loading keeps the directive in the first bytes, which
# always survive truncation. When set, atelier addresses the operator in that
# language for all chat / status / questions — independent of `.atelier.json`
# deliverableLanguage (which governs commits / PRs / code / docs). Fail-open:
# no jq or no setting → say nothing, the existing "mirror the operator" rule stands.
_op_file="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}/operator.json"
if [ -f "$_op_file" ] && command -v jq >/dev/null 2>&1; then
  _op_lang="$(jq -r '.language // empty' "$_op_file" 2>/dev/null || true)"
  if [ -n "${_op_lang:-}" ]; then
    printf '## Operator chat language\n\nAddress the operator in **%s** for all chat, status, and question messages this session — regardless of the language of the project content, these rules, or any injected context. This does NOT change `deliverableLanguage`: commit messages, PR titles/descriptions, code comments, and generated docs/artifacts still follow the project'"'"'s deliverable language.\n\n' "$_op_lang"
  fi
fi

RULES_FILE="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/operator-rules.md"

if [ ! -f "$RULES_FILE" ]; then
  # Fail soft: print a one-line note to stderr (does NOT enter the model
  # context) and exit 0 so the session is not blocked by a missing rules
  # file. Hard-failing would lock the operator out of every session.
  printf '!! atelier: operator-rules.md not found at %s\n' "$RULES_FILE" >&2
  exit 0
fi

cat "$RULES_FILE"
