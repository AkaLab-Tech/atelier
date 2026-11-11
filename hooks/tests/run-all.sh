#!/usr/bin/env bash
#
# Runs every hooks/tests/*.test.sh (same glob as .github/workflows/structural.yml)
# with bounded concurrency, prints each file's output whole in discovery order,
# then a per-file duration summary. Not named *.test.sh, so it is never itself
# discovered.
#
# Usage: hooks/tests/run-all.sh [-j N] [--serial] [--only <glob>] [--shard K/N] [--timings]
#   -j N         concurrent test files, a positive integer (default:
#                $ATELIER_TEST_JOBS, else nproc, else sysctl -n hw.ncpu, else 4)
#   --serial     same as -j 1
#   --only GLOB  only files whose basename matches GLOB (e.g. 'atelier-memory*')
#   --shard K/N  run only the files whose 0-based index i in the sorted list
#                (after --only) satisfies i % N == K-1; 1 <= K <= N
#   --timings    print the full duration table instead of the slowest 15
#   A value flag (-j, --only, --shard) with no value is a usage error.
# Exit: 0 = every test passed, 1 = a failure (or zero tests discovered),
#       2 = usage error.
# Aggregation: the full suite is green only when shards 1..N each ran as their
#   own foreground call, each printed ALL PASS, each reported the same
#   "discovered: T", and their "files:" counts sum to T. A shard with no result
#   (backgrounded, denied, killed) means the gate has no result, never green.

set -uo pipefail

# Tests that cannot run beside others (shared global state). They run one at a
# time after the parallel batch. Format: basename of the test file.
SERIAL_ONLY=(
)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
usage_error() { echo "run-all: $1" >&2; usage >&2; exit 2; }

jobs_n="${ATELIER_TEST_JOBS:-}"
jobs_set=0
only=""
shard=""
full=0
while [ $# -gt 0 ]; do
  case "$1" in
    -j)
      [ $# -ge 2 ] || usage_error "-j needs a value"
      jobs_n="$2"; jobs_set=1; shift 2 ;;
    -j*) jobs_n="${1#-j}"; jobs_set=1; shift ;;
    --serial) jobs_n=1; jobs_set=1; shift ;;
    --only)
      [ $# -ge 2 ] || usage_error "--only needs a value"
      [ -n "$2" ] || usage_error "--only needs a non-empty glob"
      only="$2"; shift 2 ;;
    --shard)
      [ $# -ge 2 ] || usage_error "--shard needs a value"
      [ -n "$2" ] || usage_error "--shard needs a non-empty K/N"
      shard="$2"; shift 2 ;;
    --timings) full=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
if [ "$jobs_set" = 0 ] && [ -z "$jobs_n" ]; then
  jobs_n="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi
case "$jobs_n" in ''|*[!0-9]*|0) usage_error "-j needs a positive integer" ;; esac

shard_k=""; shard_n=""
if [ -n "$shard" ]; then
  case "$shard" in
    */*/*) usage_error "--shard needs K/N" ;;
    */*) shard_k="${shard%/*}"; shard_n="${shard#*/}" ;;
    *) usage_error "--shard needs K/N" ;;
  esac
  case "$shard_k" in ''|*[!0-9]*) usage_error "--shard needs K/N positive integers" ;; esac
  case "$shard_n" in ''|*[!0-9]*) usage_error "--shard needs K/N positive integers" ;; esac
  shard_k=$((10#$shard_k)); shard_n=$((10#$shard_n))
  { [ "$shard_k" -ge 1 ] && [ "$shard_k" -le "$shard_n" ]; } || usage_error "--shard needs 1 <= K <= N"
fi

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

discovered=${#tests[@]}
if [ -n "$shard_n" ]; then
  all=("${tests[@]}"); tests=()
  for i in "${!all[@]}"; do
    [ $((i % shard_n)) -eq $((shard_k - 1)) ] && tests+=("${all[$i]}")
  done
  if [ "${#tests[@]}" -eq 0 ]; then
    echo "files: 0  shard: $shard_k/$shard_n discovered: $discovered"
    echo "ALL PASS (empty shard)"
    exit 0
  fi
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
echo "files: ${#tests[@]}  passed: $(( ${#tests[@]} - fails ))  failed: $fails  jobs: $jobs_n  wall: ${wall}s  sum-of-files: ${sum}s${shard_n:+  shard: $shard_k/$shard_n discovered: $discovered}"
if [ "$fails" -gt 0 ]; then
  printf 'FAILED: %s\n' "${failed[*]}"
  exit 1
fi
echo "ALL PASS"
