#!/usr/bin/env bash
#
# atelier — SessionStart hook (#582): put the atelier `gh` shim first on PATH
# for every Bash call of the session by appending to $CLAUDE_ENV_FILE. The shim
# enforces the GitHub identity at exec time (scripts/shims/gh). Never blocks:
# always exits 0.

if [ -n "${XDG_CONFIG_HOME:-}" ]; then
  acd="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
  mkdir -p "$acd" 2>/dev/null || true
  printf '%s\n' "$XDG_CONFIG_HOME" > "$acd/.operator-xdg"
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -f "$CLAUDE_ENV_FILE" ]; then
    printf 'export ATELIER_ORIGINAL_XDG_CONFIG_HOME="%s"\n' "$XDG_CONFIG_HOME" >> "$CLAUDE_ENV_FILE"
  fi
fi

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
