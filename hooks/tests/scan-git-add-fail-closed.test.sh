#!/usr/bin/env bash
#
# Regression test for scan-git-add.sh's fail-closed guard (task #27,
# facet #297 review-fix cycle 1):
#
#   The hook's `added_lines_for` signals a binary/unparseable diff by
#   writing to $PARSE_ERROR_FILE (a tempfile), because a plain variable
#   assignment made inside `added_lines_for` does NOT survive its
#   callers' `added="$(added_lines_for "$path")"` command substitution
#   (that runs the function in a subshell, so its variable changes are
#   discarded on return). Before this fix, the guard read a variable
#   that could never be set from inside that subshell, so it was DEAD
#   CODE: a binary/unparseable diff on a staged path silently returned
#   exit 0 (ALLOWED) instead of blocking. The reviewer flagged that
#   there was no regression test pinning this down — that's why the
#   dead guard passed CI in the first place. This file is that test.
#
# Hermetic: builds throwaway git repos under a temp dir and drives
# hooks/scan-git-add.sh directly. No network. Requires git + jq.
#
# Run:  hooks/tests/scan-git-add-fail-closed.test.sh
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

# Like run_hook but echoes the hook's STDERR (block/warn message), so
# callers can assert not just the exit code but which pattern fired.
run_hook_stderr() {
  local pwd_dir="$1" command_str="$2"
  local payload
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$pwd_dir" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$HOOK" <<<"$payload" 2>&1 >/dev/null
  )
}

# Build a throwaway repo at $1/repo with an initial commit containing:
#   - README.md (benign, tracked)
#   - a small binary file (tracked), so a later modification produces a
#     `git diff HEAD --unified=0` that reports "Binary files ... differ"
#     rather than textual +/- lines — the exact repro the reviewer named.
setup_repo() {
  local base="$1"
  mkdir -p "$base/repo"
  git -C "$base/repo" init -q -b main
  git -C "$base/repo" config user.email t@t.t
  git -C "$base/repo" config user.name t
  printf 'plain text file, nothing interesting here\n' > "$base/repo/README.md"
  # NUL bytes force git to classify the file as binary for diff purposes.
  printf 'BINARY\000\001\002\003DATA' > "$base/repo/blob.bin"
  git -C "$base/repo" add -A
  git -C "$base/repo" commit -qm init
}

echo "scan-git-add.sh — fail-closed on binary/unparseable diff (#297 dead-guard regression)"

# === Scenario 1 (the reviewer's exact repro): a committed binary file is
# MODIFIED, so `git diff HEAD --unified=0` reports "Binary files ...
# differ" instead of textual +/- lines. added_lines_for cannot scope
# this to added lines, so it must fail closed (block, exit 2) rather
# than silently returning "no diff text" == "nothing added". Before the
# fix, the guard reading this signal was dead code and this case wrongly
# returned exit 0. ============================================================
S1="$TMP/s1"; setup_repo "$S1"
printf 'BINARY\000\001\002\003DATA-MODIFIED-DIFFERENT-LENGTH-TOO' > "$S1/repo/blob.bin"
code="$(run_hook "$S1/repo" "git add blob.bin")"
[ "$code" = "2" ] && pass "fail-closed: modified tracked binary file (git diff -> 'Binary files differ') blocks (exit 2)" \
                   || fail "fail-closed: expected exit 2 (blocked), got $code"

err="$(run_hook_stderr "$S1/repo" "git add blob.bin")"
if printf '%s' "$err" | grep -q "diff-parse-error"; then
  pass "fail-closed: block message names pattern diff-parse-error"
else
  fail "fail-closed: expected 'diff-parse-error' in block message, got: $err"
fi

# === Scenario 2 (false-alarm guard): an ordinary MODIFIED tracked TEXT
# file — a completely normal, cleanly parseable `git diff HEAD
# --unified=0` with no binary marker and no secret content — must still
# ALLOW (exit 0). Proves the fail-closed path added in this fix is
# scoped to genuine parse failures and does not over-trigger on healthy
# diffs. ========================================================================
S2="$TMP/s2"; setup_repo "$S2"
printf 'plain text file, nothing interesting here\nand a normal added line\n' > "$S2/repo/README.md"
code="$(run_hook "$S2/repo" "git add README.md")"
[ "$code" = "0" ] && pass "false-alarm guard: ordinary modified tracked text file still allows (exit 0)" \
                   || fail "false-alarm guard: expected exit 0 (allowed), got $code"

echo
if [ "$fails" -eq 0 ]; then
  echo "All scan-git-add fail-closed checks passed."
  exit 0
else
  echo "$fails scan-git-add fail-closed check(s) FAILED."
  exit 1
fi
