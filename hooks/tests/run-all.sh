#!/usr/bin/env bash
#
# Runs every hooks/tests/*.test.sh (same glob as .github/workflows/structural.yml)
# with bounded concurrency, prints each file's output whole in discovery order,
# then a per-file duration summary. Not named *.test.sh, so it is never itself
# discovered.
#
# Usage: hooks/tests/run-all.sh [-j N] [--serial] [--only <glob>] [--timings]
#   -j N         concurrent test files (default: $ATELIER_TEST_JOBS, else
#                nproc, else sysctl -n hw.ncpu, else 4)
#   --serial     same as -j 1
#   --only GLOB  only files whose basename matches GLOB (e.g. 'atelier-memory*')
#   --timings    print the full duration table instead of the slowest 15
# Exit: 0 = every test passed, 1 = a failure (or zero tests discovered).

set -uo pipefail

# Tests that cannot run beside others (shared global state). They run one at a
# time after the parallel batch. Format: basename of the test file.
SERIAL_ONLY=(
)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
jobs_n="${ATELIER_TEST_JOBS:-}"
only=""
full=0
while [ $# -gt 0 ]; do
  case "$1" in
    -j) jobs_n="${2:-}"; shift 2 ;;
    -j*) jobs_n="${1#-j}"; shift ;;
    --serial) jobs_n=1; shift ;;
    --only) only="${2:-}"; shift 2 ;;
    --timings) full=1; shift ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run-all: unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$jobs_n" ]; then
  jobs_n="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi
case "$jobs_n" in ''|*[!0-9]*|0) echo "run-all: -j needs a positive integer" >&2; exit 2 ;; esac

shopt -s nullglob
tests=()
for t in "$HERE"/*.test.sh; do
  if [ -n "$only" ]; then
    # shellcheck disable=SC2254
    case "$(basename "$t")" in $only) ;; *) continue ;; esac
  fi
  tests+=("$t")
done
if [ "${#tests[@]}" -eq 0 ]; then
  echo "run-all: no tests discovered in $HERE" >&2
  exit 1
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

is_serial_only() {
  local b="$1" s
  for s in ${SERIAL_ONLY[@]+"${SERIAL_ONLY[@]}"}; do [ "$s" = "$b" ] && return 0; done
  return 1
}

run_one() { # <index> <file>
  local i="$1" t="$2" s e rc
  s="$(date +%s)"
  bash "$t" >"$OUT/$i.out" 2>&1 3>&- </dev/null
  rc=$?
  e="$(date +%s)"
  printf '%s %s\n' "$rc" "$((e - s))" >"$OUT/$i.res"
}

# Token-pipe semaphore: portable to bash 3.2 (no wait -n), no polling.
run_batch() { # <jobs> <index>...
  local n="$1" k i
  shift
  [ "$#" -gt 0 ] || return 0
  mkfifo "$OUT/sem"
  exec 3<>"$OUT/sem"
  for ((k = 0; k < n; k++)); do printf x >&3; done
  for i in "$@"; do
    read -r -n 1 -u 3 _
    ( run_one "$i" "${tests[$i]}"; printf x >&3 ) &
  done
  wait
  exec 3>&-
  rm -f "$OUT/sem"
}

par=(); ser=()
for i in "${!tests[@]}"; do
  if is_serial_only "$(basename "${tests[$i]}")"; then ser+=("$i"); else par+=("$i"); fi
done

wall_start="$(date +%s)"
run_batch "$jobs_n" ${par[@]+"${par[@]}"}
run_batch 1 ${ser[@]+"${ser[@]}"}
wall=$(( $(date +%s) - wall_start ))

fails=0; failed=(); rows=""
for i in "${!tests[@]}"; do
  name="$(basename "${tests[$i]}")"
  printf '=== %s ===\n' "$name"
  cat "$OUT/$i.out"
  read -r rc dur <"$OUT/$i.res"
  if [ "$rc" != 0 ]; then
    echo "::error file=${tests[$i]}::regression failed"
    fails=$((fails + 1)); failed+=("$name")
  fi
  rows="${rows}${dur} ${rc} ${name}"$'\n'
done

echo
echo "=== durations (slowest first) ==="
sorted="$(printf '%s' "$rows" | sort -rn -k1,1)"
if [ "$full" = 1 ]; then printf '%s\n' "$sorted"; else printf '%s\n' "$sorted" | head -15; fi | \
  while read -r dur rc name; do printf '%5ss  %s%s\n' "$dur" "$name" "$([ "$rc" != 0 ] && echo '  [FAIL]')"; done
sum=0; while read -r dur _; do sum=$((sum + dur)); done <<<"$(printf '%s' "$rows")"
echo
echo "files: ${#tests[@]}  passed: $(( ${#tests[@]} - fails ))  failed: $fails  jobs: $jobs_n  wall: ${wall}s  sum-of-files: ${sum}s"
if [ "$fails" -gt 0 ]; then
  printf 'FAILED: %s\n' "${failed[*]}"
  exit 1
fi
echo "ALL PASS"
