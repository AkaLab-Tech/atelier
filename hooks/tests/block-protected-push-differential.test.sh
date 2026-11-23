#!/usr/bin/env bash
#
# Differential test for #808 — hooks/block-protected-push.sh (this revision)
# versus a pinned pre-#808 baseline.
#
# The hardening only ever adds blocks: layer 1 is the baseline detection
# unchanged and layer 2 can only add. This test pins that property over the whole
# existing corpus: it runs block-protected-push.test.sh (the #194 / #195 / #35
# matrix) and block-protected-push-hardening.test.sh (the #808 matrix) with
# BPP_HOOK pointing at a recording wrapper. For every command the two test files
# feed the hook (in the real cwd and repository state of that case) the wrapper
# runs BOTH the baseline hook and this revision's hook on the same payload and
# logs the two exit codes; the verdict the test file sees is this revision's.
#
# Asserted here:
#   1. both test files still pass with this revision's verdicts;
#   2. no command the baseline blocks (exit 2) is allowed by this revision;
#   3. the corpus is non-trivial (the baseline blocks a real share of it, and
#      this revision blocks at least as many commands as the baseline does).
#
# The baseline is the pre-#808 hook, committed as a fixture under
# hooks/tests/fixtures/block-protected-push-baseline/ (source commit recorded
# in the README there), or BPP_BASELINE_ROOT=<dir containing hooks/> when set.
# It never depends on a git ref, so it behaves the same in shallow and full
# clones. A missing fixture is a failure.
#
# Hermetic: no network, scratch dirs under mktemp -d.
#
# Run:  hooks/tests/block-protected-push-differential.test.sh
# Exit: 0 = all assertions pass, 1 = failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "#808 differential — block-protected-push versus the pinned pre-#808 baseline"

# --- locate the baseline hook tree -----------------------------------------------
BASELINE_SHA="bb96cd11d20d93f12f816d3122c74ed27f35c9a0"
BASE_ROOT="${BPP_BASELINE_ROOT:-$REPO_ROOT/hooks/tests/fixtures/block-protected-push-baseline}"
if [ ! -f "$BASE_ROOT/hooks/block-protected-push.sh" ] || [ ! -f "$BASE_ROOT/hooks/lib/log-decision.sh" ]; then
  fail "baseline hook fixture is missing under $BASE_ROOT"
  exit 1
fi
pass "baseline hook located"

if [ -z "${BPP_BASELINE_ROOT:-}" ]; then
  if git -C "$REPO_ROOT" cat-file -e "${BASELINE_SHA}^{commit}" 2>/dev/null; then
    if git -C "$REPO_ROOT" show "${BASELINE_SHA}:hooks/block-protected-push.sh" 2>/dev/null \
        | cmp -s - "$BASE_ROOT/hooks/block-protected-push.sh"; then
      pass "fixture is byte-identical to the hook at ${BASELINE_SHA:0:7}"
    else
      fail "fixture differs from the hook at ${BASELINE_SHA:0:7}"
    fi
  else
    echo "  NOTE: commit ${BASELINE_SHA:0:7} not present locally (shallow clone); fixture provenance check skipped"
  fi
fi

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

# --- recording wrapper -----------------------------------------------------------
DIFFLOG="$TMP/diff.log"
: > "$DIFFLOG"
cat > "$TMP/wrap.sh" <<'WRAP'
#!/usr/bin/env bash
# stdin = the hook payload. Runs the baseline and the head hook on it; records
# "<baseline rc> <head rc> <command, base64 of the first 200 bytes>"; exits with
# the head hook's code. stdout / stderr of the head hook are passed through.
payload="$(cat)"
base_rc=0; head_rc=0
CLAUDE_PLUGIN_ROOT="$BPP_BASE_ROOT" bash "$BPP_BASE_ROOT/hooks/block-protected-push.sh" \
  <<<"$payload" >/dev/null 2>&1 || base_rc=$?
CLAUDE_PLUGIN_ROOT="$BPP_HEAD_ROOT" bash "$BPP_HEAD_ROOT/hooks/block-protected-push.sh" \
  <<<"$payload" || head_rc=$?
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null | head -c 200 | base64 | tr -d '\n ')"
printf '%s %s %s\n' "$base_rc" "$head_rc" "$cmd" >> "$BPP_DIFF_LOG"
exit "$head_rc"
WRAP
chmod +x "$TMP/wrap.sh"

run_corpus() { # test-file → exit code of the file when run through the wrapper
  local f="$1" out rc
  out="$TMP/$(basename "$f").out"
  BPP_HOOK="$TMP/wrap.sh" BPP_NO_TIMING=1 BPP_BASE_ROOT="$BASE_ROOT" BPP_HEAD_ROOT="$REPO_ROOT" \
    BPP_DIFF_LOG="$DIFFLOG" bash "$f" >"$out" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$(basename "$f") passes with this revision's verdicts through the wrapper"
  else
    fail "$(basename "$f") failed through the wrapper (rc=$rc); failing lines follow"
    grep 'FAIL' "$out" | head -20 | cut -c1-300
  fi
}

run_corpus "$REPO_ROOT/hooks/tests/block-protected-push.test.sh"
run_corpus "$REPO_ROOT/hooks/tests/block-protected-push-hardening.test.sh"

# --- analyse the log -------------------------------------------------------------
total="$(wc -l < "$DIFFLOG" | tr -d ' ')"
base_blocks="$(awk '$1 == 2 { n++ } END { print n + 0 }' "$DIFFLOG")"
head_blocks="$(awk '$2 == 2 { n++ } END { print n + 0 }' "$DIFFLOG")"
regress="$(awk '$1 == 2 && $2 != 2 { n++ } END { print n + 0 }' "$DIFFLOG")"
added="$(awk '$1 != 2 && $2 == 2 { n++ } END { print n + 0 }' "$DIFFLOG")"
errors="$(awk '($1 != 0 && $1 != 2) || ($2 != 0 && $2 != 2) { n++ } END { print n + 0 }' "$DIFFLOG")"

printf '  corpus: %s commands; baseline blocks %s, this revision blocks %s (%s newly blocked)\n' \
  "$total" "$base_blocks" "$head_blocks" "$added"

if [ "$total" -ge 400 ]; then pass "corpus has $total commands (>= 400)"
else fail "corpus too small: $total commands (expected >= 400)"; fi

if [ "$base_blocks" -ge 100 ]; then pass "baseline blocks $base_blocks of the corpus (>= 100)"
else fail "baseline blocks only $base_blocks commands; the baseline hook did not run as expected"; fi

if [ "$regress" -eq 0 ]; then
  pass "every command the baseline blocks is also blocked by this revision (0 allowed by head)"
else
  fail "$regress command(s) the baseline blocks are allowed by this revision:"
  awk '$1 == 2 && $2 != 2 { print $3 }' "$DIFFLOG" | head -20 | while read -r b; do
    printf '    %s\n' "$(printf '%s' "$b" | base64 -d 2>/dev/null | head -c 160)"
  done
fi

if [ "$head_blocks" -ge "$base_blocks" ]; then pass "this revision blocks at least as many commands as the baseline ($head_blocks >= $base_blocks)"
else fail "this revision blocks fewer commands ($head_blocks) than the baseline ($base_blocks)"; fi

if [ "$added" -ge 1 ]; then pass "the hardening adds blocks over the baseline ($added newly blocked)"
else fail "no command is newly blocked: the pinned pre-#808 baseline may have been altered or replaced"; fi

if [ "$errors" -eq 0 ]; then pass "no hook run exited with a code other than 0 or 2"
else
  fail "$errors hook run(s) exited with a code other than 0 or 2 (baseline rc, head rc, command):"
  awk '($1 != 0 && $1 != 2) || ($2 != 0 && $2 != 2) { print $1, $2, $3 }' "$DIFFLOG" | head -20 | while read -r b h c; do
    printf '    %s %s %s\n' "$b" "$h" "$(printf '%s' "$c" | base64 -d 2>/dev/null | head -c 160)"
  done
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "All #808 differential checks passed."
  exit 0
else
  echo "$fails #808 differential check(s) FAILED."
  exit 1
fi
