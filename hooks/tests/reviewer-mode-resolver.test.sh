#!/usr/bin/env bash
#
# Tests for #459 — scripts/atelier-reviewer-mode (resolves
# autoMerge.reviewerApprovalMode from the BASE ref, never the PR head) and the
# surfaces that consume it (reviewer.md, task-orchestrator.md, install.sh).
#
# Hermetic: a fixture git repo in a temp dir; `origin/main` is a plain ref
# created with `git update-ref`, so no network or remote is needed.
#
# Run:  hooks/tests/reviewer-mode-resolver.test.sh
# Exit: 0 = all passed, 1 = at least one failed.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/atelier-reviewer-mode"
REVIEWER="$ROOT/agents/reviewer.md"
ORCH="$ROOT/agents/task-orchestrator.md"
INSTALL="$ROOT/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAILN=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "  FAIL: $1"; }
chk_prose() { grep -qF -- "$2" "$1" 2>/dev/null && pass "$3" || fail "$3 — '$2' not in $1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"; exit 0
fi

REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
echo seed > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" -c core.hooksPath=/dev/null commit -q -m seed
SEED="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" update-ref refs/remotes/origin/main HEAD

# set_base <content|-> : make origin/main point at a commit with .atelier.json
# holding <content> ('-' = no file at all), leaving the working tree clean.
set_base() {
  git -C "$REPO" checkout -q -f --detach "$SEED"
  if [ "$1" = "-" ]; then
    git -C "$REPO" rm -q -f --ignore-unmatch .atelier.json
  else
    printf '%s' "$1" > "$REPO/.atelier.json"
    git -C "$REPO" add .atelier.json
  fi
  git -C "$REPO" -c core.hooksPath=/dev/null commit -q --allow-empty -m "base $RANDOM"
  git -C "$REPO" update-ref refs/remotes/origin/main HEAD
}

# run_case <label> <base-content|-> <expected-stdout> <expected-exit>
run_case() {
  local label="$1" content="$2" want="$3" wantrc="$4" out rc
  set_base "$content"
  out="$("$HELPER" "$REPO" --base origin/main 2>/dev/null)"; rc=$?
  if [ "$out" = "$want" ] && [ "$rc" = "$wantrc" ]; then pass "$label"
  else fail "$label — got '$out' rc=$rc, want '$want' rc=$wantrc"; fi
}

echo "== resolution from base =="
run_case "absent .atelier.json -> approve" "-" "approve" 0
run_case "absent autoMerge block -> approve" '{"other":1}' "approve" 0
run_case "absent field -> approve" '{"autoMerge":{"x":true}}' "approve" 0
run_case "verdict" '{"autoMerge":{"reviewerApprovalMode":"verdict"}}' "verdict" 0
run_case "approve" '{"autoMerge":{"reviewerApprovalMode":"approve"}}' "approve" 0
run_case "advisory" '{"autoMerge":{"reviewerApprovalMode":"advisory"}}' "advisory" 0

echo "== fail closed =="
run_case "garbage value -> invalid-mode, exit 2" '{"autoMerge":{"reviewerApprovalMode":"bogus"}}' 'invalid-mode:"bogus"' 2
run_case "number -> exit 2" '{"autoMerge":{"reviewerApprovalMode":5}}' 'invalid-mode:5' 2
run_case "boolean -> exit 2" '{"autoMerge":{"reviewerApprovalMode":true}}' 'invalid-mode:true' 2
run_case "unparseable JSON -> exit 2" '{not json' 'invalid-mode:unparseable' 2
run_case "non-object top level -> exit 2" '[1,2]' 'invalid-mode:{"malformed":[1,2]}' 2
run_case "non-object autoMerge -> exit 2" '{"autoMerge":"yes"}' 'invalid-mode:{"malformed":"yes"}' 2

echo "== base wins over head =="
set_base '{"autoMerge":{"reviewerApprovalMode":"verdict"}}'
# Head commit relaxes the mode, and so does the working tree.
git -C "$REPO" checkout -q --detach HEAD
printf '%s' '{"autoMerge":{"reviewerApprovalMode":"advisory"}}' > "$REPO/.atelier.json"
git -C "$REPO" add .atelier.json
git -C "$REPO" -c core.hooksPath=/dev/null commit -q -m "head relaxes"
printf '%s' '{"autoMerge":{"reviewerApprovalMode":"approve"}}' > "$REPO/.atelier.json"
out="$("$HELPER" "$REPO" --base origin/main 2>/dev/null)"; rc=$?
[ "$out" = "verdict" ] && [ "$rc" = 0 ] && pass "base verdict wins over head advisory and worktree approve" \
  || fail "base should win — got '$out' rc=$rc"
git -C "$REPO" checkout -q -- .atelier.json

echo "== usage / errors =="
"$HELPER" "$REPO" --base refs/nope/none >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" = 2 ] && [ -s "$TMP/err" ] && pass "unresolvable ref -> exit 2 with stderr" || fail "unresolvable ref: rc=$rc"
"$HELPER" "$REPO" >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" = 2 ] && [ -s "$TMP/err" ] && pass "missing --base -> exit 2 with stderr" || fail "missing --base: rc=$rc"
"$HELPER" --base origin/main >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" = 2 ] && pass "missing project-dir -> exit 2" || fail "missing project-dir: rc=$rc"

echo "== prose pins =="
chk_prose "$REVIEWER" 'atelier-reviewer-mode <main-checkout> --base origin/<base>' "reviewer.md calls the helper with --base origin/<base>"
chk_prose "$REVIEWER" 'Decision: mode-invalid' "reviewer.md defines Decision: mode-invalid"
chk_prose "$REVIEWER" 'post **nothing**' "reviewer.md posts nothing on mode-invalid"
chk_prose "$REVIEWER" 'never from the reviewed head' "reviewer.md takes the mode from base, not head"
chk_prose "$ORCH" 'When `reviewer` returned `mode-invalid`' "orchestrator has the mode-invalid handler"
STATUS='held: unknown autoMerge.reviewerApprovalMode "<v>" — fix .atelier.json on <base>'
n="$(grep -F -- '- Status:' "$ORCH" | grep -cF -- "$STATUS")"
[ "$n" = 2 ] && pass "held status in both Status vocabularies" || fail "held status in Status lines: $n (want 2)"
chk_prose "$ORCH" 'never includes a mode, a `--approve` command, or authorization wording' "reviewer brief carries no mode or --approve"

echo "== install.sh =="
chk_prose "$INSTALL" '_phase_c_1_symlink_helper atelier-reviewer-mode' "install.sh registers atelier-reviewer-mode"

echo
echo "passed: $PASS  failed: $FAILN"
[ "$FAILN" -eq 0 ]
