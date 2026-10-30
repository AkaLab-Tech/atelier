#!/usr/bin/env bash
#
# Regression test for #608 (#597c) — atelier-doctor check_worktree_env_files().
# Scans task worktrees of registered projects for prod/stage env files.
# Empty fixtures: asserts names and exit codes only, never reads file contents.
#
# Run:  hooks/tests/doctor-worktree-env-files.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2015,SC1091,SC2329  # pass() always succeeds; dynamic source & callbacks
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-doctor"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

awk '/^check_worktree_env_files\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { echo "  FAIL: could not extract check_worktree_env_files()"; exit 1; }
# shellcheck disable=SC1090
source "$TMP/fn.sh"

OK="✓"; WARN="!"; SKIP="–"
HOST_LINES=(); FIX_LINES=(); FIX_AUTO=()
push_host()       { HOST_LINES+=("$1"); }
push_fix_manual() { FIX_LINES+=("$1"); }
push_fix_auto()   { FIX_AUTO+=("$1"); }

export ATELIER_CONFIG_DIR="$TMP/config"
mkdir -p "$ATELIER_CONFIG_DIR"

export PATH="$REPO_ROOT/scripts:$PATH"

all_host() { printf '%s\n' ${HOST_LINES[@]+"${HOST_LINES[@]}"}; }
all_fix()  { printf '%s\n' ${FIX_LINES[@]+"${FIX_LINES[@]}"}; }
all_auto() { printf '%s\n' ${FIX_AUTO[@]+"${FIX_AUTO[@]}"}; }
reset()    { HOST_LINES=(); FIX_LINES=(); FIX_AUTO=(); }

register() { # paths...
  jq -n '$ARGS.positional | map({key: ., value: {}}) | {projects: from_entries}' --args "$@" \
    > "$ATELIER_CONFIG_DIR/projects.json"
}

mkrepo() { # dir
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    git -C "$d" commit -q --allow-empty -m init
}

# ---------- case 1: clean project with worktree having only clean files ----------
# (e.g. .env.local, .env.example, non-env files) -> passes, reports OK
proj1="$TMP/proj1"
mkrepo "$proj1"
wt1="$TMP/proj1-wt1"
git -C "$proj1" worktree add -q -b branch1 "$wt1" HEAD
: > "$wt1/.env.local"
: > "$wt1/.env.example"
: > "$wt1/README.md"
register "$proj1"
reset
check_worktree_env_files
out="$(all_host)"
fix="$(all_fix)"
auto="$(all_auto)"
[ ${#HOST_LINES[@]} -eq 1 ] && pass "case 1: exactly 1 host line for clean project" || fail "case 1: expected 1 host line, got ${#HOST_LINES[@]}: $out"
case "$out" in
  *"$OK task worktrees clean (no prod/stage env files in registered projects)"*)
    pass "case 1: reports OK clean" ;;
  *) fail "case 1: expected OK clean, got: $out" ;;
esac
[ ${#FIX_LINES[@]} -eq 0 ] && pass "case 1: no manual fix lines" || fail "case 1: unexpected fix: $fix"
[ ${#FIX_AUTO[@]} -eq 0 ] && pass "case 1: no auto fix lines" || fail "case 1: unexpected auto fix: $auto"

# ---------- case 2: worktree with prod/stage env files ----------
# (.env.production, .env.staging, .env.prod.local) -> flagged with $WARN,
# manual fix with operator cleanup instructions, no auto-fix
proj2="$TMP/proj2"
mkrepo "$proj2"
wt2="$TMP/proj2-wt2"
git -C "$proj2" worktree add -q -b branch2 "$wt2" HEAD
: > "$wt2/.env.production"
: > "$wt2/.env.staging"
: > "$wt2/.env.prod.local"
: > "$wt2/.env.local"
register "$proj2"
reset
check_worktree_env_files
out="$(all_host)"
fix="$(all_fix)"
auto="$(all_auto)"
[ ${#HOST_LINES[@]} -eq 3 ] && pass "case 2: exactly 3 WARN lines" || fail "case 2: expected 3 host lines, got ${#HOST_LINES[@]}: $out"
case "$out" in *"$WARN task worktree contains prod/stage env file: $proj2 · $wt2 · .env.production"*) pass "case 2: flagged .env.production" ;; *) fail "case 2: missed .env.production: $out" ;; esac
case "$out" in *"$WARN task worktree contains prod/stage env file: $proj2 · $wt2 · .env.staging"*) pass "case 2: flagged .env.staging" ;; *) fail "case 2: missed .env.staging: $out" ;; esac
case "$out" in *"$WARN task worktree contains prod/stage env file: $proj2 · $wt2 · .env.prod.local"*) pass "case 2: flagged .env.prod.local" ;; *) fail "case 2: missed .env.prod.local: $out" ;; esac
case "$out" in *".env.local"*) fail "case 2: falsely flagged .env.local: $out" ;; *) pass "case 2: .env.local not flagged" ;; esac

[ ${#FIX_LINES[@]} -eq 1 ] && pass "case 2: manual fix pushed" || fail "case 2: expected 1 manual fix block, got ${#FIX_LINES[@]}"
case "$fix" in
  *"Run in the operator's own terminal"*docs/troubleshooting.md*)
    pass "case 2: manual fix contains operator cleanup instructions and references troubleshooting.md" ;;
  *) fail "case 2: manual fix contents unexpected: $fix" ;;
esac
[ ${#FIX_AUTO[@]} -eq 0 ] && pass "case 2: no auto-fix commands registered" || fail "case 2: unexpected auto-fix: $auto"

# ---------- case 3: orphan sibling worktree directory ----------
# in <project>-worktrees/orphan-task/.env.production -> flagged with $WARN
proj3="$TMP/proj3"
mkrepo "$proj3"
orphan_dir="$TMP/proj3-worktrees/orphan-task"
mkdir -p "$orphan_dir"
: > "$orphan_dir/.env.production"
register "$proj3"
reset
check_worktree_env_files
out="$(all_host)"
fix="$(all_fix)"
auto="$(all_auto)"
[ ${#HOST_LINES[@]} -eq 1 ] && pass "case 3: exactly 1 WARN line for orphan sibling" || fail "case 3: expected 1 host line, got ${#HOST_LINES[@]}: $out"
case "$out" in
  *"$WARN task worktree contains prod/stage env file: $proj3 · $orphan_dir · .env.production"*)
    pass "case 3: orphan worktree flagged with WARN" ;;
  *) fail "case 3: orphan worktree not flagged correctly: $out" ;;
esac
[ ${#FIX_LINES[@]} -eq 1 ] && pass "case 3: manual fix pushed" || fail "case 3: expected 1 manual fix, got ${#FIX_LINES[@]}"
[ ${#FIX_AUTO[@]} -eq 0 ] && pass "case 3: no auto-fix commands" || fail "case 3: unexpected auto-fix: $auto"

# ---------- case 4: deduplication ----------
# Worktree present in both porcelain list and <project>-worktrees sibling dir is not flagged twice
proj4="$TMP/proj4"
mkrepo "$proj4"
mkdir -p "$TMP/proj4-worktrees"
wt4="$TMP/proj4-worktrees/task-4"
git -C "$proj4" worktree add -q -b branch4 "$wt4" HEAD
: > "$wt4/.env.production"
register "$proj4"
reset
check_worktree_env_files
out="$(all_host)"
[ ${#HOST_LINES[@]} -eq 1 ] && pass "case 4: deduplication works (flagged exactly once)" || fail "case 4: expected 1 host line, got ${#HOST_LINES[@]}: $out"
case "$out" in
  *"$WARN task worktree contains prod/stage env file: $proj4 · $wt4 · .env.production"*)
    pass "case 4: worktree flagged once" ;;
  *) fail "case 4: worktree not flagged: $out" ;;
esac

# ---------- case 5: main project repo checkout is not flagged ----------
# prod/stage env file in the main checkout (P) is NOT flagged by this check
# (it only checks task worktrees other than P itself)
proj5="$TMP/proj5"
mkrepo "$proj5"
: > "$proj5/.env.production"
: > "$proj5/.env.staging"
register "$proj5"
reset
check_worktree_env_files
out="$(all_host)"
fix="$(all_fix)"
[ ${#HOST_LINES[@]} -eq 1 ] && pass "case 5: exactly 1 host line" || fail "case 5: expected 1 line, got ${#HOST_LINES[@]}: $out"
case "$out" in
  *"$OK task worktrees clean"*)
    pass "case 5: main repo checkout with prod/stage files is ignored by worktree env check" ;;
  *) fail "case 5: expected OK clean, got: $out" ;;
esac
[ ${#FIX_LINES[@]} -eq 0 ] && pass "case 5: no fix lines for main checkout" || fail "case 5: unexpected fix: $fix"

# ---------- case 6: empty or non-git registered project handling ----------
# Non-existent dir, empty dir, non-git dir in projects.json are skipped gracefully
mkdir -p "$TMP/plain-dir"
register "$TMP/nonexistent" "$TMP/plain-dir"
reset
check_worktree_env_files
out="$(all_host)"
[ ${#HOST_LINES[@]} -eq 1 ] && pass "case 6: non-git/missing projects skipped gracefully, reports clean" || fail "case 6: expected 1 line, got ${#HOST_LINES[@]}: $out"
case "$out" in
  *"$OK task worktrees clean"*)
    pass "case 6: OK clean reported" ;;
  *) fail "case 6: unexpected output: $out" ;;
esac

# ---------- case 7: absent projects.json ----------
rm -f "$ATELIER_CONFIG_DIR/projects.json"
reset
rc=0
check_worktree_env_files || rc=$?
[ "$rc" -eq 0 ] && pass "case 7: absent projects.json returns 0" || fail "case 7: rc=$rc"
[ ${#HOST_LINES[@]} -eq 0 ] && pass "case 7: no host lines when projects.json absent" || fail "case 7: output: $(all_host)"
[ ${#FIX_LINES[@]} -eq 0 ] && pass "case 7: no fix lines when projects.json absent" || fail "case 7: fix: $(all_fix)"

# ---------- case 8: scanner missing -> SKIP line ----------
register "$proj1"
reset
OLD_PATH="$PATH"
OLD_CPR="${CLAUDE_PLUGIN_ROOT:-}"
PATH="/usr/bin:/bin"
unset CLAUDE_PLUGIN_ROOT
check_worktree_env_files
PATH="$OLD_PATH"
[ -n "$OLD_CPR" ] && export CLAUDE_PLUGIN_ROOT="$OLD_CPR"
out="$(all_host)"
[ ${#HOST_LINES[@]} -eq 1 ] && pass "case 8: exactly 1 host line when scanner missing" || fail "case 8: expected 1 line, got ${#HOST_LINES[@]}: $out"
case "$out" in
  *"$SKIP task worktrees env check (atelier-worktree-create not found)"*)
    pass "case 8: reports SKIP when scanner missing" ;;
  *) fail "case 8: expected SKIP, got: $out" ;;
esac

echo ""
if [ "$fails" -eq 0 ]; then
  echo "doctor worktree env files (#608): all assertions passed."
  exit 0
else
  echo "doctor worktree env files (#608): $fails assertion(s) failed."
  exit 1
fi
