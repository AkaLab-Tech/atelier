#!/usr/bin/env bash
#
# atelier — portable replacement for GNU `timeout` (absent on stock macOS).
#
# Sourced from hooks and tests, e.g.:
#   # shellcheck source=lib/portable-timeout.sh
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/portable-timeout.sh"
#   atelier_timeout 8 pnpm view left-pad time --json
#
# atelier_timeout <secs> <cmd> [args...]
#   - exit 124 when the deadline fired, otherwise the command's own exit code
#   - exit 125 when <secs> is not a non-negative integer
#   - stdin is forwarded to the command
#   - the command runs in its own process group (job control in a subshell) and
#     the whole group gets TERM, then KILL ~1 s later, so a forking child can
#     not keep a `$(...)` capture open past the deadline
#
# Pure bash 3.2 + sleep/kill/mktemp: no coreutils, no `wait -n`.

atelier_timeout() {
  case "${1:-}" in
    ''|*[!0-9]*) return 125 ;;
  esac
  local secs="$1"
  shift

  (
    set -m
    marker="$(mktemp "${TMPDIR:-/tmp}/atelier-timeout.XXXXXX")" || exit 125
    rm -f "$marker"

    # fd 3 keeps the command's own stderr; the subshell's stderr is muted so
    # job-control "Terminated" notices do not leak.
    "$@" <&0 2>&3 &
    pid=$!

    (
      sleep "$secs"
      : >"$marker"
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    wd=$!

    rc=0
    wait "$pid" || rc=$?

    kill -TERM -- "-$wd" 2>/dev/null || kill -TERM "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null || true

    if [ -e "$marker" ]; then
      rm -f "$marker"
      exit 124
    fi
    exit "$rc"
  ) 3>&2 2>/dev/null
}
