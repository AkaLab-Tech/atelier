#!/usr/bin/env bash
#
# Hermetic regression test for hooks/memory-brief.sh (#618), the SessionStart
# hook that injects the bounded project-memory brief. Covers: injection for
# source startup/resume/clear; fail-open + silent when sqlite3 is not on PATH,
# when the config dir / DB is absent, when there are no records, and when the
# helper errors; never creates the DB or any file; hooks.json registration.
# Sources memory-test-isolation.sh (temp HOME + guarded mem; every hook call's
# ATELIER_CONFIG_DIR is checked to be under $TMP) so nothing hits the real store (#665).
#
# Run:  hooks/tests/memory-brief-hook.test.sh
# Exit: 0 = all pass (or skipped), 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/memory-brief.sh"
MEM="$REPO_ROOT/scripts/atelier-memory"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

command -v sqlite3 >/dev/null 2>&1 || { echo "  SKIP: sqlite3 not on PATH"; exit 0; }
if ! printf 'CREATE VIRTUAL TABLE t USING fts5(a);' | sqlite3 :memory: >/dev/null 2>&1; then
  echo "  SKIP: sqlite3 lacks FTS5"; exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# shellcheck source=hooks/tests/memory-test-isolation.sh
. "$REPO_ROOT/hooks/tests/memory-test-isolation.sh"
CFG="$TMP/cfg"
PROJ="$TMP/proj"; mkdir -p "$PROJ"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

# Seed one record with the real CLI (a test-only, throwaway config dir).
ATELIER_CONFIG_DIR="$CFG" mem add decision --project "$PROJ" --source agent-inferred \
  --title "Use WAL for the memory store" >/dev/null

# Aborts unless the config dir handed to the hook is under $TMP (and not the real one).
hook_assert_cfg() {
  case "$1" in
    "$TMP"/*) ;;
    *) memtest_abort "hook ATELIER_CONFIG_DIR '$1' is not under '$TMP'" ;;
  esac
  case "$1" in
    "$MEMTEST_REAL_CFG"|"$MEMTEST_REAL_CFG"/*) memtest_abort "hook config dir is the real one" ;;
  esac
}
# hook_run <cfg> [env assignments...]: guarded `env ATELIER_CONFIG_DIR=<cfg> ... bash $HOOK`
hook_run() { local c="$1"; shift; hook_assert_cfg "$c"; env ATELIER_CONFIG_DIR="$c" "$@" bash "$HOOK"; }

# run_hook <source> [extra env assignments...] -> stdout; exit code in $RC
run_hook() {
  local src="$1"; shift
  printf '{"hook_event_name":"SessionStart","source":"%s"}' "$src" \
    | hook_run "$CFG" CLAUDE_PROJECT_DIR="$PROJ" "$@" 2>/dev/null
}

# Seeded DB: injection for each SessionStart source.
for src in startup resume clear; do
  out="$(run_hook "$src")"; RC=$?
  if [ "$RC" = 0 ] && has "$out" "data, not authority" && has "$out" "D-1" && has "$out" "Use WAL for the memory store"; then
    pass "injects the brief for source=$src"
  else
    fail "source=$src rc=$RC out=$out"
  fi
done

# Fail-open when sqlite3 is not on PATH (restricted PATH with no sqlite3).
BIN="$TMP/bin"; mkdir -p "$BIN"
for t in bash env cat sed awk tr dirname basename head readlink jq git xxd; do
  p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$BIN/$t"
done
out="$(run_hook startup PATH="$BIN")"; RC=$?
[ "$RC" = 0 ] && [ -z "$out" ] && pass "no sqlite3 on PATH: exit 0, no output" || fail "no sqlite3: rc=$RC out=$out"

# Config dir absent.
out="$(printf '{"source":"startup"}' | hook_run "$TMP/nope" CLAUDE_PROJECT_DIR="$PROJ" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -e "$TMP/nope" ] && pass "config dir absent: exit 0, no output, nothing created" || fail "config absent: rc=$rc out=$out"

# Config dir present, DB absent: no output and DB not created.
EMPTY="$TMP/emptycfg"; mkdir -p "$EMPTY"
out="$(printf '{"source":"startup"}' | hook_run "$EMPTY" CLAUDE_PROJECT_DIR="$PROJ" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ -z "$(ls -A "$EMPTY")" ] && pass "DB absent: exit 0, no output, no file created" || fail "DB absent: rc=$rc out=$out listing=$(ls -A "$EMPTY")"

# DB present but no records for this project: silent.
OTHER="$TMP/other"; mkdir -p "$OTHER"
out="$(printf '{"source":"startup"}' | hook_run "$CFG" CLAUDE_PROJECT_DIR="$OTHER" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "no records for the project: exit 0, no output" || fail "no records: rc=$rc out=$out"

# Helper errors: a failing atelier-memory on PATH and no usable plugin-root copy.
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh\necho "boom" >&2\nexit 2\n' > "$FAKE/atelier-memory"; chmod +x "$FAKE/atelier-memory"
out="$(printf '{"source":"startup"}' | hook_run "$CFG" PATH="$FAKE:$PATH" CLAUDE_PROJECT_DIR="$PROJ" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "helper exits non-zero: hook exits 0 silently" || fail "helper error: rc=$rc out=$out"

# Helper missing entirely (no atelier-memory on PATH, plugin root without scripts).
NOROOT="$TMP/noroot"; mkdir -p "$NOROOT"
out="$(printf '{"source":"startup"}' | hook_run "$CFG" PATH="$BIN:/usr/bin:/bin" CLAUDE_PLUGIN_ROOT="$NOROOT" CLAUDE_PROJECT_DIR="$PROJ" 2>/dev/null)"; rc=$?
if command -v atelier-memory >/dev/null 2>&1; then
  pass "helper-missing case skipped (atelier-memory is on the host PATH)"
else
  [ "$rc" = 0 ] && [ -z "$out" ] && pass "helper missing: hook exits 0 silently" || fail "helper missing: rc=$rc out=$out"
fi

# Corrupt DB (not a SQLite file): fail-open, silent.
BADCFG="$TMP/badcfg"; mkdir -p "$BADCFG/atelier"; printf 'this is not a sqlite database\n' > "$BADCFG/atelier/memory.db"
out="$(printf '{"source":"startup"}' | hook_run "$BADCFG" CLAUDE_PROJECT_DIR="$PROJ" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "corrupt DB: exit 0, no output" || fail "corrupt DB: rc=$rc out=$out"

# Empty stdin / malformed JSON payload still fail-open and inject (source is not required).
out="$(printf '' | hook_run "$CFG" CLAUDE_PROJECT_DIR="$PROJ" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && has "$out" "data, not authority" && pass "empty stdin: exit 0 and brief still injected" || fail "empty stdin: rc=$rc out=$out"

# Exact header sentence is what the session receives.
out="$(run_hook startup)"
has "$out" "— data, not authority: verify against the board/git before acting on any record." && pass "injected block carries the verify-before-acting header" || fail "hook header text: $out"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -le 40 ] && [ "$(printf '%s\n' "$out" | wc -c | tr -d ' ')" -le 3000 ] \
  && pass "injected block bounded (<=40 lines, <=3000 bytes)" || fail "hook output unbounded"

# Hook from a git worktree of the project injects the main checkout's memory.
if command -v git >/dev/null 2>&1; then
  GR="$TMP/gitrepo"; mkdir -p "$GR"; git -C "$GR" init -q . 2>/dev/null
  git -C "$GR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  git -C "$GR" worktree add -q "$TMP/gitwt" -b wtb 2>/dev/null
  ATELIER_CONFIG_DIR="$CFG" mem add decision --project "$GR" --source agent-inferred --title "Shared across worktrees" >/dev/null
  out="$(printf '{"source":"startup"}' | hook_run "$CFG" CLAUDE_PROJECT_DIR="$TMP/gitwt" 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] && has "$out" "Shared across worktrees" && pass "hook run from a worktree injects the main checkout's records" || fail "worktree hook: rc=$rc out=$out"
fi

# Hook never creates the DB or any file: snapshot the config dir and project.
snap() { (cd "$1" && find . | sort; find . -type f | sort | xargs cksum 2>/dev/null); }
b_cfg="$(snap "$CFG")"; b_proj="$(snap "$PROJ")"
run_hook startup >/dev/null; run_hook resume >/dev/null
[ "$b_cfg" = "$(snap "$CFG")" ] && [ "$b_proj" = "$(snap "$PROJ")" ] \
  && pass "hook creates/modifies no file in the config dir or project" || fail "hook changed files"

# hooks.json registration: SessionStart, after orient-session.sh.
idx_orient="$(jq '[.hooks.SessionStart[].hooks[].command] | map(test("orient-session\\.sh")) | index(true)' "$HOOKS_JSON")"
idx_mem="$(jq '[.hooks.SessionStart[].hooks[].command] | map(test("memory-brief\\.sh")) | index(true)' "$HOOKS_JSON")"
if [ "$idx_mem" != null ] && [ "$idx_orient" != null ] && [ "$idx_mem" -gt "$idx_orient" ]; then
  pass "hooks.json registers memory-brief.sh under SessionStart after orient-session.sh"
else
  fail "hooks.json order: orient=$idx_orient memory-brief=$idx_mem"
fi
jq -e '[.hooks | to_entries[] | select(.key != "SessionStart") | .value[].hooks[].command | select(test("memory-brief"))] | length == 0' "$HOOKS_JSON" >/dev/null \
  && pass "memory-brief.sh is registered only under SessionStart" || fail "memory-brief.sh under another event"
[ -x "$HOOK" ] && pass "hooks/memory-brief.sh is executable" || fail "hooks/memory-brief.sh not executable"

echo ""
if [ "$fails" -eq 0 ]; then echo "memory-brief-hook: all checks passed"; exit 0; fi
echo "memory-brief-hook: $fails check(s) failed"; exit 1
