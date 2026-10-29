# shellcheck shell=bash
# Sourced by the memory tests (#665); not a test itself. Forces a temp HOME and
# ATELIER_CONFIG_DIR and fails closed if any atelier-memory call would resolve
# its DB outside $TMP or inside the caller's real config dir.
# Requires: $TMP (canonical temp dir) and $MEM (path to scripts/atelier-memory).

[ -n "${TMP:-}" ] || { echo "memory-test-isolation: TMP not set" >&2; exit 1; }
[ -n "${MEM:-}" ] || { echo "memory-test-isolation: MEM not set" >&2; exit 1; }

# Abort the whole test even from a $(...) / pipeline / background subshell, where a
# plain `exit` would only end the subshell and could masquerade as a quiet pass.
memtest_abort() {
  echo "memory-test-isolation: ABORT: $*" >&2
  kill -TERM $$ 2>/dev/null
  exit 1
}

_memtest_canon() { if [ -d "$1" ]; then (cd -P "$1" && pwd -P); else printf '%s' "$1"; fi; }

# Captured before the overrides below; they identify what must never be touched.
MEMTEST_REAL_HOME="$(_memtest_canon "$HOME")"
MEMTEST_REAL_CFG="$(_memtest_canon "${ATELIER_CONFIG_DIR:-$HOME/.claude-work}")"

mkdir -p "$TMP/home" "$TMP/cfg"
export HOME="$TMP/home"
export ATELIER_CONFIG_DIR="$TMP/cfg"

# Aborts (exit 1) unless the DB path for the current environment is under $TMP
# and not under the real config dir. An empty ATELIER_CONFIG_DIR is refused: it
# would silently fall back to $HOME/.claude-work.
memtest_assert_isolated() {
  local p real
  if [ -z "${ATELIER_CONFIG_DIR:-}" ]; then
    memtest_abort "ATELIER_CONFIG_DIR is empty/unset (would fall back to \$HOME/.claude-work)"
  fi
  p="$(bash "$MEM" path 2>/dev/null)" || p=""
  case "$p" in
    "$TMP"/*) ;;
    *) memtest_abort "DB path '$p' is not under test temp dir '$TMP'" ;;
  esac
  for real in "$MEMTEST_REAL_CFG" "$MEMTEST_REAL_HOME/.claude-work"; do
    case "$p" in
      "$real"|"$real"/*) memtest_abort "DB path '$p' is under the real config dir '$real'" ;;
    esac
  done
  return 0
}

mem() { memtest_assert_isolated || exit 1; bash "$MEM" "$@"; }
