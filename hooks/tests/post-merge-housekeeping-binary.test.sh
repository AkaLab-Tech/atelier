#!/usr/bin/env bash
#
# Regression test for #26 — atelier-housekeeping binary safety-rail contract.
#
# The auto-merge skill's new step 5 delegates entirely to:
#   atelier-housekeeping --project <root> --yes --no-stamp
# This file exercises that binary under those exact flags against a hermetic
# git fixture repo, verifying the safety rails the skill relies on.
#
# Cases:
#   Case 1 — merged orphan swept: a local task/* branch fully merged into
#             main (via --no-ff so git branch --merged detects it without
#             requiring gh) is deleted by the binary.
#   Case 2 — active task skipped: a task/* branch referenced in
#             IN_PROGRESS.md is never deleted.
#   Case 3 — unmerged branch kept: a branch not merged into main and with
#             no gh PR state goes to "needs review", not to the delete list.
#   Case 4 — idempotent: a second run immediately after cleanup exits 0
#             and prints "nothing to clean up".
#   Case 5 — --no-stamp: the ATELIER_CONFIG_DIR/housekeeping-last-check
#             stamp file is NOT written when --no-stamp is given.
#   Case 6 — dirty worktree skipped: a worktree with uncommitted changes
#             is never auto-removed, even when its backing branch is merged.
#   Case 7 — protected branch untouched: main is never deleted.
#   Case 8 — --yes required in non-TTY: without --yes the binary exits
#             non-zero when there are items to delete, proving the flag is
#             load-bearing in the skill's invocation.
#   Case 9 — closed-unmerged remote branch → needs_review (gh shim): a
#             separate hermetic fixture with a `gh` shim on PATH reporting
#             CLOSED for a remote origin/task/* branch's PR. Verifies the #113
#             fix: the branch lands in needs_review, NOT remote_branches (the
#             delete list) — regression guard against destroying unmerged
#             work behind a closed PR.
#
# NOTE on --no-ff vs squash: production auto-merge uses squash-merge, after
# which git branch --merged cannot detect the branch (squash commits are not
# in the fast-forward ancestry). In production the binary relies on
# pr_state() (requiring gh) for those. This hermetic test uses --no-ff so
# that the "merged into main" path is exercisable without network access;
# the gh-dependent path is not testable offline and is left to the
# acceptance-criteria prose.
#
# Requires: git + jq (both are install.sh Phase-A deps and the binary's own
#           requirements). If either is missing the test self-skips.
#
# Run:  hooks/tests/post-merge-housekeeping-binary.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOUSEKEEPING="$REPO_ROOT/scripts/atelier-housekeeping"

command -v jq  >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(mktemp -d)"
# Canonicalize to the real path (macOS: /var/... → /private/var/...) so that
# the path we register in projects.json matches what the binary resolves via
# cd -P when it validates --project against projects.json.
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "post-merge housekeeping binary (#26) — safety-rail regression"

# ---------------------------------------------------------------------------
# Build the fixture git repo
# ---------------------------------------------------------------------------

REPO="$TMP/fixture"
CFG="$TMP/cfg"
WTS="$TMP/worktrees"
mkdir -p "$REPO" "$CFG" "$WTS"

# Initialise the repo on branch 'main'.
git -C "$REPO" init -q -b main 2>/dev/null \
  || { git -C "$REPO" init -q; git -C "$REPO" symbolic-ref HEAD refs/heads/main; }
git -C "$REPO" config user.email "fixture@test"
git -C "$REPO" config user.name  "Fixture"

printf 'initial\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm "init"

# task/1-old-merged: merged into main via --no-ff, branch intentionally left
# as a stale local orphan (simulates a prior auto-merge that deleted the
# remote but not the local branch).
git -C "$REPO" checkout -q -b task/1-old-merged
printf 'done\n' > "$REPO/t1.txt"
git -C "$REPO" add t1.txt
git -C "$REPO" commit -qm "task 1 work"
git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --no-ff task/1-old-merged -m "Merge task/1-old-merged"
# Branch is merged but NOT deleted — this is the orphan the sweep must clean.

# task/2-active: not merged; referenced in IN_PROGRESS.md as the active task.
git -C "$REPO" checkout -q -b task/2-active
printf 'wip\n' > "$REPO/t2.txt"
git -C "$REPO" add t2.txt
git -C "$REPO" commit -qm "task 2 wip"
git -C "$REPO" checkout -q main

# task/3-unmerged: not merged into main; no PR state available without gh.
# The binary must put this in the "needs review" list, never delete it.
git -C "$REPO" checkout -q -b task/3-unmerged
printf 'unm\n' > "$REPO/t3.txt"
git -C "$REPO" add t3.txt
git -C "$REPO" commit -qm "task 3 unmerged"
git -C "$REPO" checkout -q main

# task/4-dirty-wt: merged into main, but its worktree has uncommitted changes.
# The binary must skip the worktree (dirty) and skip the local branch (backs
# the retained worktree), leaving both untouched.
git -C "$REPO" checkout -q -b task/4-dirty-wt
printf 'base\n' > "$REPO/t4.txt"
git -C "$REPO" add t4.txt
git -C "$REPO" commit -qm "task 4 base"
git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --no-ff task/4-dirty-wt -m "Merge task/4-dirty-wt"
WT4="$WTS/task-4"
git -C "$REPO" worktree add -q "$WT4" task/4-dirty-wt
printf 'dirty uncommitted change\n' >> "$WT4/t4.txt"   # make the worktree dirty

# IN_PROGRESS.md: marks task/2-active as the currently active task.
# The binary's referenced_in_progress() reads this file to protect active tasks.
printf '# IN_PROGRESS\n- task/2-active\n' > "$REPO/IN_PROGRESS.md"
git -C "$REPO" add IN_PROGRESS.md
git -C "$REPO" commit -qm "add IN_PROGRESS"

# Register the fixture project in the fake ATELIER_CONFIG_DIR.
jq -n --arg p "$REPO" '{"projects":{($p):{"setupVersion":"99.0.0"}}}' \
  > "$CFG/projects.json"

# ---------------------------------------------------------------------------
# Case 8: --yes is load-bearing — without it the binary must exit non-zero
#         in a non-TTY context when there are items to delete.
# (Run before the sweeping run so task/1-old-merged is still present.)
# ---------------------------------------------------------------------------
exit8=0
ATELIER_AUTO="" ATELIER_CONFIG_DIR="$CFG" \
  bash "$HOUSEKEEPING" --project "$REPO" --no-stamp \
  </dev/null >/dev/null 2>&1 || exit8=$?
if [ "$exit8" -ne 0 ]; then
  pass "case 8: --yes required — binary exited $exit8 without it in non-TTY context"
else
  fail "case 8: expected non-zero exit without --yes in non-TTY (got exit 0) — --yes is not load-bearing"
fi

# ---------------------------------------------------------------------------
# Run the binary with the exact flags the skill invokes.
# ---------------------------------------------------------------------------
run_out="$(ATELIER_CONFIG_DIR="$CFG" bash "$HOUSEKEEPING" \
             --project "$REPO" --yes --no-stamp 2>&1)"
run_exit=$?

if [ "$run_exit" -ne 0 ]; then
  fail "binary: invocation with --yes --no-stamp exited $run_exit (expected 0)"
fi

# ---------------------------------------------------------------------------
# Case 5: --no-stamp — housekeeping-last-check must NOT be written
# ---------------------------------------------------------------------------
if [ ! -f "$CFG/housekeeping-last-check" ]; then
  pass "case 5: --no-stamp — housekeeping-last-check stamp NOT written to ATELIER_CONFIG_DIR"
else
  fail "case 5: --no-stamp was given but $CFG/housekeeping-last-check was created"
fi

# ---------------------------------------------------------------------------
# Case 1: merged orphan task/1-old-merged must be deleted
# ---------------------------------------------------------------------------
if ! git -C "$REPO" rev-parse --verify task/1-old-merged >/dev/null 2>&1; then
  pass "case 1: merged orphan task/1-old-merged swept (branch deleted)"
else
  fail "case 1: task/1-old-merged still exists after sweep — expected deletion"
fi

# ---------------------------------------------------------------------------
# Case 2: active task task/2-active referenced in IN_PROGRESS.md must be kept
# ---------------------------------------------------------------------------
if git -C "$REPO" rev-parse --verify task/2-active >/dev/null 2>&1; then
  pass "case 2: active task task/2-active skipped (branch retained)"
else
  fail "case 2: task/2-active was deleted despite being referenced in IN_PROGRESS.md — safety violation"
fi

# ---------------------------------------------------------------------------
# Case 3: unmerged task/3-unmerged with no gh PR state must NOT be deleted
# ---------------------------------------------------------------------------
if git -C "$REPO" rev-parse --verify task/3-unmerged >/dev/null 2>&1; then
  pass "case 3: unmerged task/3-unmerged sent to 'needs review', not deleted"
else
  fail "case 3: task/3-unmerged was deleted despite being unmerged and having no known PR — safety violation"
fi

# ---------------------------------------------------------------------------
# Case 6: dirty worktree for task/4-dirty-wt must NOT be removed
# ---------------------------------------------------------------------------
if [ -d "$WT4" ]; then
  pass "case 6: dirty worktree $WT4 skipped (uncommitted changes protected)"
else
  fail "case 6: dirty worktree was removed despite having uncommitted changes — safety violation"
fi

# Local branch task/4-dirty-wt must also be retained (backs the kept worktree).
if git -C "$REPO" rev-parse --verify task/4-dirty-wt >/dev/null 2>&1; then
  pass "case 6b: task/4-dirty-wt branch retained (backs a worktree with uncommitted changes)"
else
  fail "case 6b: task/4-dirty-wt branch deleted — it backed a dirty worktree that should have been kept"
fi

# ---------------------------------------------------------------------------
# Case 7: protected branch 'main' must never be touched
# ---------------------------------------------------------------------------
if git -C "$REPO" rev-parse --verify main >/dev/null 2>&1; then
  pass "case 7: protected branch 'main' untouched after sweep"
else
  fail "case 7: 'main' branch was deleted — protected branch safety violated"
fi

# ---------------------------------------------------------------------------
# Case 4: idempotency — a second run must exit 0 and report nothing to do
# ---------------------------------------------------------------------------
second_out="$(ATELIER_CONFIG_DIR="$CFG" bash "$HOUSEKEEPING" \
                --project "$REPO" --yes --no-stamp 2>&1)"
second_exit=$?
if [ "$second_exit" -eq 0 ] && printf '%s\n' "$second_out" | grep -q "nothing to clean up"; then
  pass "case 4: idempotent — second run exits 0 with 'nothing to clean up'"
else
  fail "case 4: second run exit=$second_exit; output did not contain 'nothing to clean up' — output: $(printf '%s\n' "$second_out" | tail -5)"
fi

# ---------------------------------------------------------------------------
# Case 9: closed-unmerged remote branch → needs_review (gh shim)
#
# Separate hermetic fixture (REPO9/CFG9) — not the swept $REPO — with a
# fake `gh` on PATH so HAVE_GH=true and pr_state() resolves CLOSED for the
# remote origin/task/9-closed-unmerged branch without any network access.
# Regression guard for #113: a closed-without-merge remote branch must be
# routed to needs_review, never to remote_branches (the delete list).
# ---------------------------------------------------------------------------
REPO9="$TMP/fixture9"
CFG9="$TMP/cfg9"
BIN9="$TMP/bin9"
mkdir -p "$REPO9" "$CFG9" "$BIN9"

git -C "$REPO9" init -q -b main 2>/dev/null \
  || { git -C "$REPO9" init -q; git -C "$REPO9" symbolic-ref HEAD refs/heads/main; }
git -C "$REPO9" config user.email "fixture9@test"
git -C "$REPO9" config user.name  "Fixture9"

printf 'initial\n' > "$REPO9/README.md"
git -C "$REPO9" add README.md
git -C "$REPO9" commit -qm "init"

# A github.com origin remote so repo_slug() resolves a non-empty owner/name.
git -C "$REPO9" remote add origin https://github.com/fixture/closed-unmerged.git

# Build the unmerged commit on a throwaway local branch, then point a
# remote-tracking ref at it directly (no push / no network) and delete the
# local branch so ONLY the remote-branch enumeration path handles it.
git -C "$REPO9" checkout -q -b task/9-closed-unmerged
printf 'unmerged work\n' > "$REPO9/t9.txt"
git -C "$REPO9" add t9.txt
git -C "$REPO9" commit -qm "task 9 unmerged work"
SHA9="$(git -C "$REPO9" rev-parse task/9-closed-unmerged)"
git -C "$REPO9" checkout -q main
git -C "$REPO9" branch -D task/9-closed-unmerged >/dev/null 2>&1
git -C "$REPO9" update-ref refs/remotes/origin/task/9-closed-unmerged "$SHA9"

# No IN_PROGRESS.md reference, no local task/9-* branch, no worktree — the
# remote-branch path is the only one that can touch this fixture.

# Fake `gh`: makes `command -v gh` succeed (HAVE_GH=true) and makes
# pr_state()'s `gh pr list ... --jq '.[0].state // "NONE"'` resolve to
# CLOSED by printing exactly that to stdout.
cat > "$BIN9/gh" <<'GHSHIM'
#!/usr/bin/env bash
printf 'CLOSED'
exit 0
GHSHIM
chmod +x "$BIN9/gh"

jq -n --arg p "$REPO9" '{"projects":{($p):{"setupVersion":"99.0.0"}}}' \
  > "$CFG9/projects.json"

out9="$(PATH="$BIN9:$PATH" ATELIER_CONFIG_DIR="$CFG9" \
          bash "$HOUSEKEEPING" --project "$REPO9" --report --json 2>/dev/null)"

if [ -z "$out9" ] || ! printf '%s' "$out9" | jq -e . >/dev/null 2>&1; then
  fail "case 9: closed-unmerged remote branch → needs_review, not remote_branches (gh shim CLOSED) — no parseable JSON output: $out9"
elif printf '%s' "$out9" | jq -e '[.needs_review[]?|select(.target=="origin/task/9-closed-unmerged")]|length>0' >/dev/null 2>&1 \
   && printf '%s' "$out9" | jq -e '[.remote_branches[]?|select(.target=="origin/task/9-closed-unmerged" or .target=="task/9-closed-unmerged")]|length==0' >/dev/null 2>&1; then
  pass "case 9: closed-unmerged remote branch → needs_review, not remote_branches (gh shim CLOSED)"
else
  fail "case 9: closed-unmerged remote branch → needs_review, not remote_branches (gh shim CLOSED) — output: $out9"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "post-merge-housekeeping-binary (#26): all assertions passed."
  exit 0
else
  echo "post-merge-housekeeping-binary (#26): $fails assertion(s) failed."
  exit 1
fi
