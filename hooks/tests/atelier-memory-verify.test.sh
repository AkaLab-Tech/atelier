#!/usr/bin/env bash
#
# Hermetic regression test for `atelier-memory verify` (#610d, #621).
# Verifies:
# - Missing file ref -> reported as stale ('file:PATH missing').
# - Closed issue ref / merged PR ref -> reported as stale (stubbed gh issue/pr view).
# - Branch / worktree ref -> checked against git branch and git worktree list.
# - Held record referencing a closed record -> reported as stale ('record:ID resolved').
# - --apply: writes board-derived closing/superseding records atomically; records table
#   remains append-only (no deleted/overwritten rows).
# - Backends:
#   * github-project (stubbed gh and offline mirror)
#   * files (ROADMAP.md [x] and HISTORY.md)
#   * linear (reports board freshness check deferred, skips issue/pr but checks file/git)
# - Brief integration: reflects 'unverified' before verify, 'verified <date>' after.
#
# Run:  hooks/tests/atelier-memory-verify.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEM="$REPO_ROOT/scripts/atelier-memory"

command -v sqlite3 >/dev/null 2>&1 || { echo "  SKIP: sqlite3 not on PATH"; exit 0; }
if ! printf 'CREATE VIRTUAL TABLE t USING fts5(a);' | sqlite3 :memory: >/dev/null 2>&1; then
  echo "  SKIP: sqlite3 lacks FTS5"; exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# shellcheck source=hooks/tests/memory-test-isolation.sh
. "$REPO_ROOT/hooks/tests/memory-test-isolation.sh"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
CFG="$ATELIER_CONFIG_DIR"
DB="$CFG/atelier/memory.db"
VAULT="$TMP/vault"
export ATELIER_MEMORY_VAULT="$VAULT"
mkdir -p "$VAULT"

dbq() { printf '%s' "$1" | sqlite3 "$DB"; }

# --- Stub gh on PATH -------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Deterministic gh CLI stub for issue and PR status queries
case "$*" in
  *"issue view"*|*"pr view"*)
    for a in "$@"; do
      case "$a" in
        "101") echo "CLOSED"; exit 0 ;;
        "102") echo "OPEN"; exit 0 ;;
        "201") echo "MERGED"; exit 0 ;;
        "202") echo "OPEN"; exit 0 ;;
      esac
    done
    echo "OPEN"
    exit 0
    ;;
  *)
    echo "gh stub: unhandled args $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

# --- Set up git repository fixture -----------------------------------------
PROJ="$TMP/work/project-alpha"
mkdir -p "$PROJ"
(
  cd "$PROJ" || exit 1
  git init -q
  git config user.name "Test Operator"
  git config user.email "operator@example.com"
  echo "# Test Project" > README.md
  echo "existing content" > exists.txt
  git add README.md exists.txt
  git commit -q -m "initial commit"
  git branch live-feature
)

jq -n --arg p "$PROJ" '{projects: {($p): {name: "alpha"}}}' > "$CFG/projects.json"

# --- 1. Missing file ref -> reported as stale ------------------------------
mem add request --project "$PROJ" --source agent-inferred \
  --title "Check missing file" --ref "file:nonexistent.txt" >/dev/null

mem add request --project "$PROJ" --source agent-inferred \
  --title "Check existing file" --ref "file:exists.txt" >/dev/null

v_out_file="$(mem verify --project "$PROJ" 2>&1)"
if grep -q "R-1 file:nonexistent.txt missing" <<<"$v_out_file" \
   && ! grep -q "R-2" <<<"$v_out_file"; then
  pass "missing file ref reported as stale ('file:nonexistent.txt missing'), existing file ref ignored"
else
  fail "missing file ref check failed (output: $v_out_file)"
fi

# --- 2. Branch and worktree refs -------------------------------------------
mem add request --project "$PROJ" --source agent-inferred \
  --title "Check live branch" --ref "branch:live-feature" >/dev/null

mem add request --project "$PROJ" --source agent-inferred \
  --title "Check deleted branch" --ref "branch:deleted-feature" >/dev/null

mem add request --project "$PROJ" --source agent-inferred \
  --title "Check missing worktree" --ref "worktree:task-999-missing" >/dev/null

v_out_git="$(mem verify --project "$PROJ" 2>&1)"
if grep -q "R-4 branch:deleted-feature missing" <<<"$v_out_git" \
   && grep -q "R-5 worktree:task-999-missing missing" <<<"$v_out_git" \
   && ! grep -q "R-3" <<<"$v_out_git"; then
  pass "missing branch and missing worktree reported as stale; existing branch not flagged"
else
  fail "branch/worktree ref check failed (output: $v_out_git)"
fi

# --- 3. Held item referencing a closed record -> stale (resolved) ----------
mem add question --project "$PROJ" --source agent-inferred --title "Blocker question" >/dev/null
mem add held --project "$PROJ" --source agent-inferred --title "Blocked by Q-1" --ref "record:Q-1" >/dev/null

# Before closing Q-1, H-1 is not stale
v_held_1="$(mem verify --project "$PROJ" 2>&1)"
if ! grep -q "H-1" <<<"$v_held_1"; then
  pass "held item referencing open record Q-1 is not stale"
else
  fail "held item flagged prematurely: $v_held_1"
fi

# Close Q-1
mem close Q-1 --by "resolved in discussion" >/dev/null
v_held_2="$(mem verify --project "$PROJ" 2>&1)"
if grep -q "H-1 record:Q-1 resolved" <<<"$v_held_2"; then
  pass "held item referencing closed record Q-1 is reported stale ('record:Q-1 resolved')"
else
  fail "held item not reported stale after target closed: $v_held_2"
fi

# --- 4. github-project backend with stubbed gh (closed issue / merged PR) --
cat > "$PROJ/.roadmap.json" <<'EOF'
{
  "backend": "github-project"
}
EOF

mem add request --project "$PROJ" --source agent-inferred \
  --title "Req for issue 101" --ref "issue:owner/repo#101" >/dev/null

mem add request --project "$PROJ" --source agent-inferred \
  --title "Req for issue 102" --ref "issue:owner/repo#102" >/dev/null

mem add request --project "$PROJ" --source agent-inferred \
  --title "Req for PR 201" --ref "pr:owner/repo#201" >/dev/null

mem add request --project "$PROJ" --source agent-inferred \
  --title "Req for PR 202" --ref "pr:owner/repo#202" >/dev/null

v_gh="$(mem verify --project "$PROJ" 2>&1)"
if grep -q "R-6 issue:owner/repo#101 closed" <<<"$v_gh" \
   && ! grep -q "R-7" <<<"$v_gh" \
   && grep -q "R-8 pr:owner/repo#201 merged" <<<"$v_gh" \
   && ! grep -q "R-9" <<<"$v_gh"; then
  pass "github-project backend: closed issue reported as closed, merged PR reported as merged; open ones untouched"
else
  fail "github-project backend check failed: $v_gh"
fi

# --- 5. files backend (ROADMAP.md and HISTORY.md) --------------------------
cat > "$PROJ/.roadmap.json" <<'EOF'
{
  "backend": "files"
}
EOF
cat > "$PROJ/ROADMAP.md" <<'EOF'
# Roadmap
- [x] #301 Completed task
- [ ] #302 Open task
EOF
cat > "$PROJ/HISTORY.md" <<'EOF'
# History
- #303 Shipped feature
EOF

mem add request --project "$PROJ" --source agent-inferred \
  --title "Task 301" --ref "issue:owner/repo#301" >/dev/null

mem add request --project "$PROJ" --source agent-inferred \
  --title "Task 302" --ref "issue:owner/repo#302" >/dev/null

mem add request --project "$PROJ" --source agent-inferred \
  --title "PR 303" --ref "pr:owner/repo#303" >/dev/null

v_files="$(mem verify --project "$PROJ" 2>&1)"
if grep -q "R-10 issue:owner/repo#301 closed" <<<"$v_files" \
   && ! grep -q "R-11" <<<"$v_files" \
   && grep -q "R-12 pr:owner/repo#303 merged" <<<"$v_files"; then
  pass "files backend: ROADMAP.md [x] flags issue as closed, HISTORY.md flags PR as merged; open task untouched"
else
  fail "files backend check failed: $v_files"
fi

# --- 6. linear backend (defers board check, but still checks file/git) -----
cat > "$PROJ/.roadmap.json" <<'EOF'
{
  "backend": "linear"
}
EOF

v_linear="$(mem verify --project "$PROJ" 2>&1)"
if grep -q "linear: board freshness check is deferred (no Linear bash API)" <<<"$v_linear"; then
  pass "linear backend prints deferred notice"
else
  fail "linear deferred notice missing: $v_linear"
fi

# In linear mode, issue: and pr: refs should NOT be flagged as stale
if ! grep -E "R-10|R-12" <<<"$v_linear" \
   && grep -q "R-1 file:nonexistent.txt missing" <<<"$v_linear"; then
  pass "linear backend defers issue/pr checks but continues verifying file and git refs"
else
  fail "linear backend verification behavior mismatch: $v_linear"
fi

# Reset backend to files for apply test
cat > "$PROJ/.roadmap.json" <<'EOF'
{
  "backend": "files"
}
EOF

# --- 7. --apply: closes/supersedes stale records append-only ---------------
# Snapshot DB records before --apply
count_before="$(dbq "SELECT count(*) FROM records;")"
r1_orig="$(dbq "SELECT title || '|' || source || '|' || refs FROM records WHERE id='R-1';")"

apply_out="$(mem verify --project "$PROJ" --apply 2>&1)"
apply_r=$?

if [ "$apply_r" -eq 0 ]; then
  pass "verify --apply completed with exit 0"
else
  fail "verify --apply failed (exit=$apply_r, out=$apply_out)"
fi

# Check append-only: R-1 was NOT deleted or overwritten, only superseded_by was set
r1_after="$(dbq "SELECT title || '|' || source || '|' || refs FROM records WHERE id='R-1';")"
r1_sup="$(dbq "SELECT superseded_by FROM records WHERE id='R-1';")"
count_after="$(dbq "SELECT count(*) FROM records;")"

if [ "$r1_orig" = "$r1_after" ] && [ -n "$r1_sup" ]; then
  pass "old stale record R-1 retained original data and has superseded_by set ($r1_sup)"
else
  fail "R-1 immutability check failed (orig=$r1_orig, after=$r1_after, sup=$r1_sup)"
fi

if [ "$count_after" -gt "$count_before" ]; then
  pass "records table grew append-only ($count_before -> $count_after rows; no rows deleted)"
else
  fail "record count did not grow append-only (before=$count_before, after=$count_after)"
fi

# Check new closing record properties
sup_rec="$(dbq "SELECT type || '|' || source || '|' || created_by || '|' || coalesce(closed_by,'') FROM records WHERE id='$r1_sup';")"
if [[ "$sup_rec" =~ request\|board-derived\|atelier-memory\ verify\|verify:\ file:nonexistent.txt\ missing ]]; then
  pass "closing record has source=board-derived, author='atelier-memory verify', closed_by='verify: ...'"
else
  fail "closing record properties mismatch: $sup_rec"
fi

# Second verify should find no remaining stale records for the already resolved items
v_after_apply="$(mem verify --project "$PROJ" 2>&1)"
if ! grep -q "R-1 file:nonexistent.txt" <<<"$v_after_apply"; then
  pass "re-running verify after --apply does not re-report resolved records"
else
  fail "verify after apply still reported R-1: $v_after_apply"
fi

# --- 8. Brief integration: reflects 'unverified' before verify, 'verified <date>' after
PROJ_FRESH="$TMP/work/project-fresh"
mkdir -p "$PROJ_FRESH"
(
  cd "$PROJ_FRESH" || exit 1
  git init -q
  git config user.name "Fresh User"
  git config user.email "fresh@example.com"
  echo "test" > README.md
  git add README.md
  git commit -q -m "init"
)
jq -n --arg a "$PROJ" --arg f "$PROJ_FRESH" \
  '{projects: {($a): {name: "alpha"}, ($f): {name: "fresh"}}}' \
  > "$CFG/projects.json"

mem add request --project "$PROJ_FRESH" --source agent-inferred \
  --title "Fresh request awaiting verification" >/dev/null

# Brief before verify: unverified
brief_before="$(mem brief --project "$PROJ_FRESH" 2>&1)"
if grep -q "Open requests (unverified):" <<<"$brief_before"; then
  pass "brief reflects '(unverified)' before verify is executed"
else
  fail "brief before verify did not say (unverified): $brief_before"
fi

# Run verify on fresh project
mem verify --project "$PROJ_FRESH" >/dev/null 2>&1

today="$(date -u +%Y-%m-%d)"
brief_after="$(mem brief --project "$PROJ_FRESH" 2>&1)"
if grep -q "Open requests (verified $today):" <<<"$brief_after"; then
  pass "brief reflects 'Open requests (verified $today):' after verify is executed"
else
  fail "brief after verify did not reflect verified date: $brief_after"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "atelier-memory-verify: all checks passed"
  exit 0
fi
echo "atelier-memory-verify: $fails check(s) failed"
exit 1
