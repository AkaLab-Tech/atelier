#!/usr/bin/env bash
#
# Regression test for scan-git-add.sh's diff/path-scoping fix (task #27,
# facets #297 and #301):
#
#   #297 — when the session cwd is not the worktree (staging via
#          `git -C <worktree> add <path>`), the hook used to resolve
#          relative paths against its OWN cwd and scan the FULL file
#          content, so a pre-existing example marker already committed
#          on base (a PEM-style private-key header sitting, unmodified,
#          in a documentation/catalogue table — same shape as the real
#          PLAN.md's threat-model table) read as a newly-added key
#          block. Fixed by resolving the staged repo root once and
#          scanning only the staged ADDED lines (`git diff HEAD
#          --unified=0`), never the whole file.
#   #301 — a multi-path `git add <p1> <p2> ...` tripped the same false
#          positive even though nothing in the diff matched; a
#          single-path add of the identical files passed clean. Same
#          root cause (full-file scan instead of added-line scan), same
#          fix.
#
# This file complements hooks/tests/scan-git-add-worktree.test.sh (which
# covers #126/#130/#258, the -C recognition + target-dir resolution
# machinery). Here we focus on the CONTENT scoping: added-lines-only vs.
# full-file, across single-path, multi-path, and cwd!=target scenarios,
# plus a true-positive control to prove the fix didn't over-narrow
# detection.
#
# Hermetic: builds throwaway git repos under a temp dir and drives
# hooks/scan-git-add.sh directly. No network. Requires git + jq +
# python3.
#
# Run:  hooks/tests/scan-git-add-diff-scope.test.sh
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

# Private-key PEM header, assembled from three non-contiguous variables
# at runtime (never a contiguous literal anywhere in THIS source file),
# so writing/editing this test doesn't itself trip scan-edit-write's
# hardcoded-secret-known-prefix / private-key-block-added-line patterns
# (mirrors the AKIA-splitting convention already used in
# scan-git-add-worktree.test.sh).
key_p1="-----BEGIN"
key_p2=" RSA PRIVATE"
key_p3=" KEY-----"
KEY_LINE="${key_p1}${key_p2}${key_p3}"

# Build a throwaway repo at $1/repo with an initial commit containing:
#   - README.md (benign)
#   - PLAN.md: a multi-line "security catalogue" doc that includes
#     $KEY_LINE as a documentation example (exactly like the real
#     PLAN.md's threat-model table), committed and UNMODIFIED by any
#     later scenario changes.
setup_repo() {
  local base="$1"
  mkdir -p "$base/repo"
  git -C "$base/repo" init -q -b main
  git -C "$base/repo" config user.email t@t.t
  git -C "$base/repo" config user.name t
  : > "$base/repo/README.md"
  {
    printf '# PLAN\n\n'
    printf '## Threat model catalogue\n\n'
    printf 'line-before-marker: some unrelated existing prose\n'
    printf '| Hardcoded secrets known prefix | %s | Block |\n' "$KEY_LINE"
    printf 'line-after-marker: more unrelated existing prose\n'
  } > "$base/repo/PLAN.md"
  git -C "$base/repo" add -A
  git -C "$base/repo" commit -qm init
}

echo "scan-git-add.sh — #297/#301 diff/path-scoping (added-lines-only content scan)"

# === Scenario 1 (#301): multi-path add, pre-existing marker NOT in diff ===
# PLAN.md keeps its committed marker line untouched; we append an
# unrelated new section (so PLAN.md DOES have a diff, but the diff never
# touches the marker line) and add a second, wholly clean file in the
# same `git add` invocation. Previously this tripped
# private-key-block-added-line via a full-file scan; the fix must scan
# only the added lines and allow.
S1="$TMP/s1"; setup_repo "$S1"
printf '\n## New unrelated section\nsome new unrelated content\n' >> "$S1/repo/PLAN.md"
printf 'hello world\n' > "$S1/repo/other.txt"
code="$(run_hook "$S1/repo" "git add PLAN.md other.txt")"
[ "$code" = "0" ] && pass "#301 multi-path 'git add PLAN.md other.txt' allows (pre-existing marker not in diff)" \
                   || fail "#301 expected exit 0 (allowed), got $code"

# === Scenario 1b (#301 parity control): the identical PLAN.md diff,
# staged alone (single path) — must ALSO pass, proving multi- and
# single-path scans are scoped identically. ==================================
S1B="$TMP/s1b"; setup_repo "$S1B"
printf '\n## New unrelated section\nsome new unrelated content\n' >> "$S1B/repo/PLAN.md"
code="$(run_hook "$S1B/repo" "git add PLAN.md")"
[ "$code" = "0" ] && pass "#301 parity: single-path 'git add PLAN.md' allows too (same diff as 1)" \
                   || fail "#301 parity: expected exit 0 (allowed), got $code"

# === Scenario 2 (#297): cwd != target dir, via `git -C <repo> add`, same
# pre-existing catalogue marker (not in the diff) =============================
# The Bash tool's cwd stays at a sibling "elsewhere" dir (never the repo
# itself); the repo is addressed purely via `-C`. Previously the hook
# resolved PLAN.md relative to its own $PWD (elsewhere/PLAN.md, which
# doesn't exist, or the wrong tree) and/or fell back to a full-file scan,
# reading the untouched marker line as newly added.
S2="$TMP/s2"; setup_repo "$S2"
mkdir -p "$S2/elsewhere"
printf '\n## New unrelated section\nsome new unrelated content\n' >> "$S2/repo/PLAN.md"
printf 'hello world\n' > "$S2/repo/other.txt"
code="$(run_hook "$S2/elsewhere" "git -C $S2/repo add PLAN.md")"
[ "$code" = "0" ] && pass "#297 cwd!=target: 'git -C <repo> add PLAN.md' (single-path) allows" \
                   || fail "#297 expected exit 0 (allowed), got $code"

# === Scenario 2b (#297 + #301 combined, bonus): same cwd!=target setup,
# but multi-path, proving the two facets compose cleanly. ====================
code="$(run_hook "$S2/elsewhere" "git -C $S2/repo add PLAN.md other.txt")"
[ "$code" = "0" ] && pass "#297+#301 combined: 'git -C <repo> add PLAN.md other.txt' allows" \
                   || fail "#297+#301 combined: expected exit 0 (allowed), got $code"

# === Scenario 3 (nice-to-have, diff-context stress): edit the line
# directly ADJACENT to the marker (default diff context would normally
# show it), not the marker line itself — must still allow, proving the
# hook scans with --unified=0 (no context lines bleed into "added"). ========
S3="$TMP/s3"; setup_repo "$S3"
# Replace only "line-before-marker: ..." (adjacent, above the marker) —
# the marker line itself is untouched.
python3 - "$S3/repo/PLAN.md" <<'PY'
import sys
path = sys.argv[1]
with open(path) as fh:
    text = fh.read()
text = text.replace(
    "line-before-marker: some unrelated existing prose\n",
    "line-before-marker: EDITED adjacent prose\n",
)
with open(path, "w") as fh:
    fh.write(text)
PY
code="$(run_hook "$S3/repo" "git add PLAN.md")"
[ "$code" = "0" ] && pass "diff-context stress: editing the line adjacent to the marker still allows" \
                   || fail "diff-context stress: expected exit 0 (allowed), got $code"

# === Scenario 4 (true positive, new untracked file): a NEW file whose
# content actually contains a real private-key block must still BLOCK —
# proves the added-lines/diff-scoping fix didn't over-narrow detection
# for the untracked (whole-file-is-new) path. =================================
S4="$TMP/s4"; setup_repo "$S4"
printf '%s\nabcdef...\n%s END %s\n' "$KEY_LINE" "$key_p1" "$key_p2" > "$S4/repo/id_rsa_leak.txt"
code="$(run_hook "$S4/repo" "git add id_rsa_leak.txt")"
[ "$code" = "2" ] && pass "true positive: new file with real private-key block still blocks (exit 2)" \
                   || fail "true positive: expected exit 2 (blocked), got $code"
err="$(run_hook_stderr "$S4/repo" "git add id_rsa_leak.txt")"
if printf '%s' "$err" | grep -q "private-key-block-added-line"; then
  pass "true positive: block message names pattern private-key-block-added-line"
else
  fail "true positive: expected 'private-key-block-added-line' in block message, got: $err"
fi

# === Scenario 5 (true positive, added line to a TRACKED file): a real
# key block introduced as a genuinely NEW added line in an already
# tracked file must still block — proves the tracked-file diff path
# (git diff HEAD --unified=0) still detects real additions, not just the
# untracked/whole-file path exercised by scenario 4. ==========================
S5="$TMP/s5"; setup_repo "$S5"
printf '\n%s\n' "$KEY_LINE" >> "$S5/repo/PLAN.md"
code="$(run_hook "$S5/repo" "git add PLAN.md")"
[ "$code" = "2" ] && pass "true positive: a genuinely new added key-block line in a tracked file blocks" \
                   || fail "true positive: expected exit 2 (blocked), got $code"

echo
if [ "$fails" -eq 0 ]; then
  echo "All scan-git-add diff-scope checks passed."
  exit 0
else
  echo "$fails scan-git-add diff-scope check(s) FAILED."
  exit 1
fi
