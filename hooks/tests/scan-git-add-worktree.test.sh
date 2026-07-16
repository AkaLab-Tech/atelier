#!/usr/bin/env bash
#
# Regression test for scan-git-add.sh's three fixes:
#   #126 — the "ask" decision must be emitted as the harness-readable
#          {"hookSpecificOutput": {...}} envelope on stdout (a top-level
#          permissionDecision is silently ignored by Claude Code).
#   #130 — `git -C <path> add ...` (the atelier convention for addressing
#          a task worktree from a cwd that stays at the main repo) must
#          be recognised at all. Previously it fell through to exit 0 —
#          a silent, total bypass of the secret scanner.
#   #258 — once recognised, the `-C <path>` target must actually be
#          resolved and scanned (ls-files/diff/-f/-d checks all need to
#          run against the worktree, not the hook's inherited $PWD).
#
# Hermetic: builds a throwaway git repo + linked worktree under a temp dir
# and drives hooks/scan-git-add.sh directly. No network. Requires git +
# jq + python3 (all install.sh Phase-A deps and what the hook itself
# needs for its entropy check).
#
# Run:  hooks/tests/scan-git-add-worktree.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/scan-git-add.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- helpers ----------------------------------------------------------------

# Run the hook as Claude Code would: PWD = $1, payload = a Bash command
# string built from $2. Echoes the exit code; stdout/stderr are discarded.
run_hook() {
  local pwd_dir="$1" command_str="$2"
  local payload
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$pwd_dir" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$HOOK" <<<"$payload" >/dev/null 2>&1
  )
  echo "$?"
}

# Like run_hook but echoes the hook's STDOUT (the ask-decision JSON, if
# any) instead of the exit code.
run_hook_stdout() {
  local pwd_dir="$1" command_str="$2"
  local payload
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$pwd_dir" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$HOOK" <<<"$payload" 2>/dev/null
  )
}

# Build a throwaway main repo with one commit, plus a linked worktree, at
# $1/main and $1/wt.
setup_repo_and_worktree() {
  local base="$1"
  mkdir -p "$base/main"
  git -C "$base/main" init -q -b main
  git -C "$base/main" config user.email t@t.t
  git -C "$base/main" config user.name t
  : > "$base/main/README.md"
  git -C "$base/main" add -A
  git -C "$base/main" commit -qm init
  git -C "$base/main" worktree add -q -b "task/$(basename "$base")" "$base/wt"
}

echo "scan-git-add.sh — #126 schema, #130 git -C trigger, #258 -C-aware path resolution"

# === Scenario 1 (#126): ask-decision is the harness-readable envelope =====
# High-entropy blob on its own line — clears the added_line_entropy
# pattern's min_length=32 / min_entropy=4.5 threshold comfortably (two
# concatenated 40-byte-base64 chunks) without looking like an AKIA/PAT/
# private-key literal, so no higher-priority BLOCK pattern fires first.
S1="$TMP/s1"; setup_repo_and_worktree "$S1"
blob="$(head -c 40 /dev/urandom | base64 | tr -d '\n')$(head -c 40 /dev/urandom | base64 | tr -d '\n')"
printf '%s\n' "$blob" > "$S1/wt/blob.txt"
out="$(run_hook_stdout "$S1/main" "git -C $S1/wt add blob.txt")"
if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask" and .hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null 2>&1; then
  pass "#126 high-entropy blob -> ask envelope under hookSpecificOutput"
else
  fail "#126 expected {hookSpecificOutput:{hookEventName,permissionDecision:ask}} JSON on stdout, got: $out"
fi
code="$(run_hook "$S1/main" "git -C $S1/wt add blob.txt")"
[ "$code" = "0" ] && pass "#126 ask decision still exits 0 (add proceeds, operator prompted)" \
                   || fail "#126 expected exit 0 for ask decision, got $code"

# === Scenario 2 (#130 + #258): git -C <wt> add . blocks an AWS key ========
# Proves the -C form is now scanned at all (previously silent bypass,
# exit 0) AND that the scan runs against the WORKTREE (not $PWD=main).
# config.txt (not .env*) so it isn't skipped by core.excludesfile when
# resolved via `git ls-files --others --exclude-standard` for the `.`
# wildcard expansion.
S2="$TMP/s2"; setup_repo_and_worktree "$S2"
# Built from two separate variables (not a contiguous literal in this
# source file) so this test fixture doesn't itself trip scan-edit-write's
# hardcoded-secret-known-prefix pattern when this file is Written/Edited.
akia_prefix="AKIA"
akia_body="IOSFODNN7EXAMPLE"
printf 'AWS_KEY=%s%s\n' "$akia_prefix" "$akia_body" > "$S2/wt/config.txt"
code="$(run_hook "$S2/main" "git -C $S2/wt add .")"
[ "$code" = "2" ] && pass "#130/#258 git -C <wt> add . blocks AWS key in worktree" \
                   || fail "#130/#258 expected exit 2 (blocked), got $code"

# === Scenario 3 (#258): git -C <wt> add .env blocks (path-level, resolved
# in the worktree) ===========================================================
S3="$TMP/s3"; setup_repo_and_worktree "$S3"
printf 'SECRET=x\n' > "$S3/wt/.env"
code="$(run_hook "$S3/main" "git -C $S3/wt add .env")"
[ "$code" = "2" ] && pass "#258 git -C <wt> add .env blocks (env-file-added, resolved in worktree)" \
                   || fail "#258 expected exit 2 (blocked), got $code"

# === Scenario 4 (#258 control): git -C <wt> add <clean file> allows =======
S4="$TMP/s4"; setup_repo_and_worktree "$S4"
printf 'hello world\n' > "$S4/wt/cleanfile.txt"
code="$(run_hook "$S4/main" "git -C $S4/wt add cleanfile.txt")"
[ "$code" = "0" ] && pass "#258 git -C <wt> add <clean file> allows (exit 0)" \
                   || fail "#258 expected exit 0 (allowed), got $code"

# === Scenario 5 (regression): bare `git add .env` with cwd=worktree still
# blocks — proves the original contiguous-`git add` path is untouched by
# the `-C` broadening. ========================================================
S5="$TMP/s5"; setup_repo_and_worktree "$S5"
printf 'SECRET=x\n' > "$S5/wt/.env"
code="$(run_hook "$S5/wt" "git add .env")"
[ "$code" = "2" ] && pass "regression: bare 'git add .env' with cwd=worktree still blocks" \
                   || fail "regression: expected exit 2, got $code"

echo
if [ "$fails" -eq 0 ]; then
  echo "All scan-git-add checks passed."
  exit 0
else
  echo "$fails scan-git-add check(s) FAILED."
  exit 1
fi
