#!/usr/bin/env bash
#
# atelier — SessionStart hook (#582): put the atelier `gh` shim first on PATH
# for every Bash call of the session by appending to $CLAUDE_ENV_FILE. The shim
# enforces the GitHub identity at exec time (scripts/shims/gh). Never blocks:
# always exits 0.

shim_dir=""
for d in "${ATELIER_RUNTIME_DIR:-$HOME/.local/share/atelier}/current/scripts/shims" \
         "${CLAUDE_PLUGIN_ROOT:-}/scripts/shims"; do
  if [ -x "$d/gh" ]; then shim_dir="$d"; break; fi
done

if [ -z "$shim_dir" ] || [ -z "${CLAUDE_ENV_FILE:-}" ] || [ ! -f "$CLAUDE_ENV_FILE" ]; then
  echo "atelier: gh shim not active; identity relies on the #544 hook" >&2
  exit 0
fi

printf 'export PATH="%s:$PATH"\n' "$shim_dir" >> "$CLAUDE_ENV_FILE"
exit 0
