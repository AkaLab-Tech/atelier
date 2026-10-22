#!/usr/bin/env bash
#
# Test for #521 — hooks/lib/portable-timeout.sh (atelier_timeout) and a guard
# against new bare GNU `timeout` / `gtimeout` invocations (absent on stock
# macOS) creeping back into the shipped tree.
#
#   A. helper behaviour: rc pass-through, 124 on deadline, stdin forwarding,
#      `$(...)` capture does not hang, 125 on a bad limit, forking children.
#   B. guard: no bare `timeout`/`gtimeout` command or `command -v` probe in
#      agents/ skills/ commands/ scripts/ hooks/ install.sh bootstrap.sh
#      templates/ operator-rules.md (the helper and this file excluded),
#      with an inline positive/negative fixture set proving the matcher.
#
# Hermetic: no network, no GNU timeout needed.
# Run:  hooks/tests/portable-timeout.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/portable-timeout.sh
source "$REPO_ROOT/hooks/lib/portable-timeout.sh"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# ---------------------------------------------------------------- A. helper
echo "A. atelier_timeout behaviour"

atelier_timeout 5 true; rc=$?
[ "$rc" -eq 0 ] && pass "rc 0 passes through" || fail "rc 0 expected, got $rc"

atelier_timeout 5 bash -c 'exit 7'; rc=$?
[ "$rc" -eq 7 ] && pass "rc 7 passes through" || fail "rc 7 expected, got $rc"

start=$SECONDS
atelier_timeout 1 sleep 5; rc=$?
el=$((SECONDS - start))
[ "$rc" -eq 124 ] && pass "sleep 5 with 1s limit returns 124" || fail "124 expected, got $rc"
[ "$el" -lt 3 ] && pass "deadline fired in ${el}s (<3s)" || fail "deadline took ${el}s (>=3s)"

out="$(printf 'hello-stdin\n' | atelier_timeout 5 cat)"
[ "$out" = "hello-stdin" ] && pass "stdin reaches the child" || fail "stdin: got '$out'"

start=$SECONDS
out="$(atelier_timeout 1 sleep 5)"; rc=$?
el=$((SECONDS - start))
{ [ "$rc" -eq 124 ] && [ "$el" -lt 3 ]; } \
  && pass "\$(atelier_timeout 1 sleep 5) returns 124 in ${el}s" \
  || fail "\$() capture rc=$rc elapsed=${el}s (want 124, <3s)"

out="$(atelier_timeout 5 echo ok)"
[ "$out" = "ok" ] && pass "stdout captured on success" || fail "stdout: got '$out'"

atelier_timeout abc true; rc=$?
[ "$rc" -eq 125 ] && pass "non-integer limit 'abc' returns 125" || fail "125 expected, got $rc"
atelier_timeout "" true; rc=$?
[ "$rc" -eq 125 ] && pass "empty limit returns 125" || fail "125 expected for empty, got $rc"
atelier_timeout 1.5 true; rc=$?
[ "$rc" -eq 125 ] && pass "decimal limit returns 125" || fail "125 expected for 1.5, got $rc"

start=$SECONDS
out="$(atelier_timeout 1 bash -c 'sleep 30 & sleep 30')"; rc=$?
el=$((SECONDS - start))
{ [ "$rc" -eq 124 ] && [ "$el" -lt 5 ]; } \
  && pass "forking child holding stdout does not hang \$(...) (${el}s)" \
  || fail "forking child: rc=$rc elapsed=${el}s (want 124, <5s)"

# ----------------------------------------------------------------- B. guard
echo "B. no bare GNU timeout/gtimeout invocations"

# Reads lines on stdin; prints those that invoke GNU timeout/gtimeout in
# command position, or probe for it with `command -v`. Comment-only lines are
# dropped first. `--timeout`, `"timeout":`, `timeout-minutes` and prose do not
# match because the word must follow a command-position boundary and be
# followed by whitespace + a duration-ish token.
bare_timeout_lines() {
  grep -Ev '^[[:space:]]*#' | grep -E \
    -e '(^|[;&|(`]|\$\(|(^|[[:space:]])(then|do|else|exec|sudo|if|!))[[:space:]]*g?timeout[[:space:]]+([0-9]+([[:space:]]|$)|[$<"])' \
    -e 'command[[:space:]]+-v[[:space:]]+g?timeout'
}

must_flag() {
  if printf '%s\n' "$1" | bare_timeout_lines >/dev/null; then pass "flags: $1"
  else fail "matcher missed bad line: $1"; fi
}
must_ignore() {
  if printf '%s\n' "$1" | bare_timeout_lines >/dev/null; then fail "matcher flagged allowed line: $1"
  else pass "ignores: $1"; fi
}

must_flag 'timeout 8 pnpm view foo'
must_flag '  gtimeout 10 bash x'
must_flag 'out=$(timeout 5 curl x)'
must_flag 'foo && timeout "$N" cmd'
must_flag 'x | timeout 3 cat'
must_flag 'if timeout 2 true; then'
must_flag 'if command -v timeout >/dev/null; then'
must_flag 'command -v gtimeout'
must_flag '  exec timeout 9 bash x'

must_ignore 'cmd --timeout 30'
must_ignore '  "timeout": 10,'
must_ignore '  timeout-minutes: 15'
must_ignore '# timeout 8 pnpm view foo'
must_ignore '   # command -v timeout'
must_ignore 'The timeout 8s window elapsed.'
must_ignore 'fail "HUNG (timeout 8s exceeded, exit 124)"'
must_ignore 'atelier_timeout 8 bash x'
must_ignore 'ciWait timeout 120m'

cd "$REPO_ROOT" || { fail "cannot cd to repo root"; exit 1; }
targets=()
for t in agents skills commands scripts hooks install.sh bootstrap.sh templates operator-rules.md; do
  [ -e "$t" ] && targets+=("$t")
done

found=0
while IFS= read -r f; do
  case "$f" in
    hooks/lib/portable-timeout.sh|hooks/tests/portable-timeout.test.sh) continue ;;
  esac
  [ -f "$f" ] || continue
  hits="$(bare_timeout_lines <"$f" || true)"
  if [ -n "$hits" ]; then
    found=1
    fail "bare GNU timeout in $f: $(printf '%s' "$hits" | head -3 | tr '\n' '|')"
  fi
done < <(find "${targets[@]}" -type f ! -name '*.png' ! -name '*.jpg' 2>/dev/null)
[ "$found" -eq 0 ] && pass "no bare timeout/gtimeout invocations in shipped tree"

echo
if [ "$fails" -eq 0 ]; then echo "All assertions passed."; exit 0; fi
echo "$fails assertion(s) failed."; exit 1
