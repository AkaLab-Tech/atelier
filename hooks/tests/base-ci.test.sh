#!/usr/bin/env bash
#
# Hermetic test for scripts/atelier-base-ci (#533): classification of the base
# sha's CI as green|red|pending|none|unknown. `gh` and `git` are stubbed on
# PATH. The gh stub honours `--jq` by running real jq over fixture JSON (one
# file per page for --paginate), so the helper's jq filters are exercised.
#
# Run:  hooks/tests/base-ci.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/atelier-base-ci"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not installed"; exit 0; }
[ -f "$HELPER" ] || { echo "  FAIL: $HELPER not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; FX="$TMP/fx"; WT="$TMP/wt"
mkdir -p "$BIN" "$FX" "$WT"

# --- stubs -----------------------------------------------------------------
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
# Stub git: only the calls atelier-base-ci makes. Logs argv to $STUB_LOG.
echo "git $*" >> "$STUB_LOG"
[ "$1" = "-C" ] && shift 2
case "$1" in
  fetch) exit 0 ;;
  merge-base)
    [ -n "${STUB_MB_FAIL:-}" ] && exit 1
    echo "$STUB_MB_SHA"; exit 0 ;;
  remote) echo "${STUB_ORIGIN:-https://github.com/acme/widgets.git}"; exit 0 ;;
esac
exit 1
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Stub gh api: runs real jq (--jq) over fixtures. check-runs: every
# $FX/runs*.json is one page (concatenated like --paginate). status: $FX/status.json.
echo "gh $*" >> "$STUB_LOG"
[ "$1" = "api" ] || exit 1
shift
jqx="" ep="" pag=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) jqx=$2; shift 2 ;;
    --paginate) pag=1; shift ;;
    *) ep=$1; shift ;;
  esac
done
case "$ep" in
  *check-runs*)
    [ "${STUB_GH_FAIL:-}" = runs ] && { echo "boom" >&2; exit 1; }
    [ -n "$pag" ] && echo "PAGINATE" >> "$STUB_LOG"
    for f in "$FX"/runs*.json; do jq -r "$jqx" "$f"; done ;;
  */status*)
    [ "${STUB_GH_FAIL:-}" = status ] && { echo "boom" >&2; exit 1; }
    jq -r "$jqx" "$FX/status.json" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BIN/git" "$BIN/gh"

export STUB_LOG="$TMP/stub.log" FX
export STUB_MB_SHA="abc1234"
PATH="$BIN:$PATH"

reset() {
  rm -f "$FX"/*.json "$STUB_LOG"; : > "$STUB_LOG"
  unset STUB_GH_FAIL STUB_MB_FAIL STUB_ORIGIN
  echo '{"statuses":[],"state":"pending","total_count":0}' > "$FX/status.json"
  echo '{"total_count":0,"check_runs":[]}' > "$FX/runs1.json"
}

OUT="" RC=0
run() { OUT="$("$HELPER" "$@" 2>"$TMP/err")"; RC=$?; }
field() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }

# expect <label> <class> [checks-substring]
expect() {
  local label="$1" cls="$2" sub="${3:-}"
  [ "$RC" -eq 0 ] && pass "$label: exit 0" || fail "$label: exit $RC (want 0)"
  [ "$(field base_ci)" = "$cls" ] && pass "$label: base_ci=$cls" \
    || fail "$label: base_ci='$(field base_ci)' (want $cls)"
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 4 ] && pass "$label: four output lines" \
    || fail "$label: output is not four lines: $OUT"
  [ -n "$(field reason)" ] && pass "$label: reason non-empty" || fail "$label: empty reason"
  if [ -n "$sub" ]; then
    case "$(field checks)" in
      *"$sub"*) pass "$label: checks contains '$sub'" ;;
      *) fail "$label: checks='$(field checks)' lacks '$sub'" ;;
    esac
  fi
}

snap() { (cd "$WT" && find . -print | sort; ls -la "$WT" | wc -l); }
BEFORE="$(snap)"

# --- green ------------------------------------------------------------------
reset
cat > "$FX/runs1.json" <<'EOF'
{"total_count":3,"check_runs":[
 {"name":"lint","status":"completed","conclusion":"success"},
 {"name":"types","status":"completed","conclusion":"neutral"},
 {"name":"opt","status":"completed","conclusion":"skipped"}]}
EOF
run --worktree "$WT" --base main
expect "green" green "lint:success"
[ "$(field base_sha)" = "abc1234" ] && pass "green: base_sha from merge-base" || fail "green: base_sha='$(field base_sha)'"
grep -q 'repos/acme/widgets/commits/abc1234/check-runs' "$STUB_LOG" \
  && pass "green: slug+sha in check-runs endpoint" || fail "green: endpoint wrong: $(cat "$STUB_LOG")"
grep -q 'merge-base HEAD origin/main' "$STUB_LOG" && pass "green: merge-base HEAD origin/main" || fail "green: merge-base args"

# green via legacy status success only
reset
echo '{"statuses":[{"context":"ci/legacy","state":"success"}],"state":"success","total_count":1}' > "$FX/status.json"
run --worktree "$WT" --base main
expect "green-legacy" green "ci/legacy:success"

# --sha skips merge-base
reset
cat > "$FX/runs1.json" <<'EOF'
{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}
EOF
run --worktree "$WT" --base main --sha deadbee
expect "explicit-sha" green
[ "$(field base_sha)" = "deadbee" ] && pass "explicit-sha: echoed" || fail "explicit-sha: base_sha='$(field base_sha)'"
grep -q 'merge-base' "$STUB_LOG" && fail "explicit-sha: merge-base should not run" || pass "explicit-sha: merge-base skipped"

# --- red via check run --------------------------------------------------------
reset
cat > "$FX/runs1.json" <<'EOF'
{"check_runs":[
 {"name":"lint","status":"completed","conclusion":"success"},
 {"name":"test","status":"completed","conclusion":"failure"},
 {"name":"slow","status":"in_progress","conclusion":null}]}
EOF
run --worktree "$WT" --base main
expect "red-check" red "test:failure"

# --- red via legacy status ----------------------------------------------------
reset
cat > "$FX/runs1.json" <<'EOF'
{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}
EOF
echo '{"statuses":[{"context":"ci/legacy","state":"failure"}],"state":"failure","total_count":1}' > "$FX/status.json"
run --worktree "$WT" --base main
expect "red-status" red "ci/legacy:failure"

reset
echo '{"statuses":[{"context":"ci/legacy","state":"error"}],"state":"error","total_count":1}' > "$FX/status.json"
run --worktree "$WT" --base main
expect "red-status-error" red "ci/legacy:error"

# --- pending ----------------------------------------------------------------
reset
cat > "$FX/runs1.json" <<'EOF'
{"check_runs":[
 {"name":"lint","status":"completed","conclusion":"success"},
 {"name":"test","status":"queued","conclusion":null}]}
EOF
run --worktree "$WT" --base main
expect "pending-run" pending "test:queued"

reset
echo '{"statuses":[{"context":"ci/legacy","state":"pending"}],"state":"pending","total_count":1}' > "$FX/status.json"
run --worktree "$WT" --base main
expect "pending-status" pending "ci/legacy:in_progress"

# --- none -------------------------------------------------------------------
reset   # 0 runs + legacy pending/total_count:0
run --worktree "$WT" --base main
expect "none" none

# --- paginate multi-page ------------------------------------------------------
reset
cat > "$FX/runs1.json" <<'EOF'
{"total_count":2,"check_runs":[{"name":"page1","status":"completed","conclusion":"success"}]}
EOF
cat > "$FX/runs2.json" <<'EOF'
{"total_count":2,"check_runs":[{"name":"page2","status":"completed","conclusion":"failure"}]}
EOF
run --worktree "$WT" --base main
expect "paginate" red "page1:success"
case "$(field checks)" in *page2:failure*) pass "paginate: page 2 included" ;; *) fail "paginate: page 2 missing: $(field checks)" ;; esac
grep -q '^PAGINATE$' "$STUB_LOG" && pass "paginate: --paginate passed to gh" || fail "paginate: --paginate not passed"

# --- gh errors -> unknown -----------------------------------------------------
reset; export STUB_GH_FAIL=runs
run --worktree "$WT" --base main
expect "gh-runs-error" unknown
reset; export STUB_GH_FAIL=status
run --worktree "$WT" --base main
expect "gh-status-error" unknown

# --- merge-base failure -> unknown ---------------------------------------------
reset; export STUB_MB_FAIL=1
run --worktree "$WT" --base main
expect "merge-base-fail" unknown
case "$(field reason)" in *merge-base*) pass "merge-base-fail: reason names merge-base" ;; *) fail "merge-base-fail: reason='$(field reason)'" ;; esac
grep -q 'check-runs' "$STUB_LOG" && fail "merge-base-fail: gh must not be called" || pass "merge-base-fail: gh not called"

# --- non-GitHub origin -> unknown ---------------------------------------------
reset; export STUB_ORIGIN="git@github.com:acme/widgets.git"
run --worktree "$WT" --base main
expect "ssh-origin" unknown

# --- origin/ stripping --------------------------------------------------------
reset
run --worktree "$WT" --base origin/develop
expect "origin-strip" none
grep -q 'merge-base HEAD origin/develop' "$STUB_LOG" && pass "origin-strip: origin/origin/ not produced" || fail "origin-strip: $(grep merge-base "$STUB_LOG")"
grep -q 'origin/origin' "$STUB_LOG" && fail "origin-strip: doubled prefix" || pass "origin-strip: no doubled prefix"
grep -q 'fetch --quiet origin develop' "$STUB_LOG" && pass "origin-strip: fetch uses bare branch" || fail "origin-strip: fetch args"

# --- usage errors -> exit 2 ---------------------------------------------------
for args in "" "--worktree $WT" "--base main" "--worktree $WT --base" "--worktree $WT --base origin/" "--bogus x --worktree $WT --base main"; do
  # shellcheck disable=SC2086
  "$HELPER" $args >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && pass "usage '$args': exit 2" || fail "usage '$args': exit $rc (want 2)"
done

# --- read-only: nothing written to the worktree --------------------------------
AFTER="$(snap)"
[ "$BEFORE" = "$AFTER" ] && pass "worktree untouched after all runs" || fail "worktree changed: before=[$BEFORE] after=[$AFTER]"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "base-ci (#533): all assertions passed."
  exit 0
else
  echo "base-ci (#533): $fails assertion(s) failed."
  exit 1
fi
