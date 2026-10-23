#!/usr/bin/env bash
#
# Test for scripts/atelier-worktree-create (#606). Drives the real helper
# against a temp git repo with a stub `git-wt` on PATH (records its argv and
# creates the worktree with `git worktree add`). Env fixtures are EMPTY files:
# the test asserts names and exit codes only and never reads their contents.
#
# Run:  hooks/tests/atelier-worktree-create.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

# shellcheck disable=SC2015  # pass() always succeeds; A && pass || fail is intended
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/atelier-worktree-create"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# Stub git-wt: `git wt <args>` runs `git-wt <args>`. Records argv, creates the
# worktree, optionally plants STUB_PLANT (space-separated names) in it, prints
# a banner line then the path LAST.
STUBBIN="$TMP/bin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/git-wt" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_ARGV_FILE"
[ "${STUB_FAIL:-0}" = 1 ] && exit 3
branch="$2"
path="$STUB_WT_DIR/$branch"
git worktree add -q -b "$branch" "$path" HEAD >/dev/null 2>&1 || exit 4
for n in ${STUB_PLANT:-}; do : > "$path/$n"; done
echo "Switched to new worktree"
echo "$path"
STUB
chmod +x "$STUBBIN/git-wt"

n=0
# new_repo: fresh repo with empty fixtures .env .env.local .env.prod ... in the
# main checkout (untracked). Sets REPO, WTS, ARGV.
new_repo() {
  n=$((n + 1))
  REPO="$TMP/r$n/main"; WTS="$TMP/r$n/wts"; ARGV="$TMP/r$n/argv"
  mkdir -p "$REPO" "$WTS"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  local f
  for f in .env .env.local .env.prod .env.production .env.stage .env.staging; do : > "$REPO/$f"; done
  export STUB_ARGV_FILE="$ARGV" STUB_WT_DIR="$WTS"
  unset STUB_PLANT STUB_FAIL
}
# run_create <branch>: sets OUT, ERR, RC.
run_create() {
  OUT="$(PATH="$STUBBIN:$PATH" bash "$HELPER" "$REPO" "$1" --from main 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}
has() { [ -e "$WTS/$1/$2" ]; }

# 1. --no-env always passed; args forwarded; default copies only .env.local
new_repo; run_create b1
[ "$RC" -eq 0 ] && pass "create exits 0" || fail "create rc=$RC err=$ERR"
[ "$(cat "$ARGV")" = "switch b1 --from main --no-env" ] && pass "git-wt argv: switch b1 --from main --no-env" || fail "argv: $(cat "$ARGV")"
has b1 .env.local && pass "default copies .env.local" || fail "default did not copy .env.local"
! has b1 .env && pass "default does not copy .env" || fail "default copied .env"
! has b1 .env.prod && pass "default does not copy .env.prod" || fail "default copied .env.prod"
[ "$(printf '%s\n' "$OUT" | tail -n1)" = "$WTS/b1" ] && pass "worktree path is last stdout line" || fail "last line: $(printf '%s\n' "$OUT" | tail -n1)"

# 2. --no-env passed even with custom config
new_repo; echo '{"worktreeEnvFiles":[".env"]}' > "$REPO/.atelier.json"; run_create b2
grep -q -- '--no-env' "$ARGV" && pass "--no-env passed with custom config" || fail "argv: $(cat "$ARGV")"

# 3. declared .env copied; .env.local not (not listed)
has b2 .env && pass "declared .env copied" || fail "declared .env not copied (rc=$RC err=$ERR)"
! has b2 .env.local && pass "unlisted .env.local not copied when list overrides default" || fail ".env.local copied though unlisted"

# 4. prod/stage never copied even when declared, with warning naming them
new_repo
echo '{"worktreeEnvFiles":[".env.local",".env.prod",".env.production",".env.stage",".env.staging"]}' > "$REPO/.atelier.json"
run_create b4
[ "$RC" -eq 0 ] && pass "declared prod/stage: exit 0 (nothing copied)" || fail "rc=$RC err=$ERR"
for f in .env.prod .env.production .env.stage .env.staging; do
  ! has b4 "$f" && pass "$f never copied" || fail "$f was copied"
  printf '%s' "$ERR" | grep -qF -- "$f" && pass "warning names $f" || fail "no warning naming $f: $ERR"
done
has b4 .env.local && pass "valid sibling .env.local still copied" || fail ".env.local missing"

# 5. invalid entries rejected with warning
new_repo
echo '{"worktreeEnvFiles":["../.env","a/.env",".env.local"]}' > "$REPO/.atelier.json"
: > "$TMP/r$n/.env"; mkdir -p "$REPO/a"; : > "$REPO/a/.env"
run_create b5
[ "$RC" -eq 0 ] && pass "invalid entries: exit 0" || fail "rc=$RC err=$ERR"
printf '%s' "$ERR" | grep -qF -- '../.env' && pass "warning names ../.env" || fail "no warning for ../.env: $ERR"
printf '%s' "$ERR" | grep -qF -- 'a/.env' && pass "warning names a/.env" || fail "no warning for a/.env: $ERR"
[ ! -e "$WTS/.env" ] && [ ! -e "$WTS/b5/a/.env" ] && pass "invalid entries not copied" || fail "invalid entry copied"
has b5 .env.local && pass "valid entry alongside invalid still copied" || fail ".env.local missing"

# 6. never overwrites: pre-existing file in new worktree is preserved.
# Stub plants .env.local in the new worktree; main's copy has a marker size.
new_repo
printf 'main-side' > "$REPO/.env.local"
export STUB_PLANT=".env.local"
run_create b6
[ "$RC" -eq 0 ] && pass "existing file: exit 0" || fail "rc=$RC err=$ERR"
[ "$(wc -c < "$WTS/b6/.env.local" | tr -d ' ')" = "0" ] && pass "existing .env.local not overwritten" || fail ".env.local overwritten"

# 7. post-create scan: prod/stage present in new worktree -> non-zero, names listed
new_repo
export STUB_PLANT=".env.prod .env.staging"
run_create b7
[ "$RC" -eq 1 ] && pass "prod/stage in new worktree: exit 1" || fail "rc=$RC"
printf '%s' "$ERR" | grep -qF -- '.env.prod' && printf '%s' "$ERR" | grep -qF -- '.env.staging' \
  && pass "stderr lists .env.prod and .env.staging" || fail "stderr: $ERR"
printf '%s\n' "$OUT" | grep -qF -- "$WTS/b7" && fail "path printed on failure" || pass "no worktree path on stdout on failure"

# 8. git-wt failure -> exit 2
new_repo; export STUB_FAIL=1; run_create b8
[ "$RC" -eq 2 ] && pass "git-wt failure: exit 2" || fail "rc=$RC"

# 9. bad args -> exit 2
rc=0; bash "$HELPER" onlyone >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "bad args: exit 2" || fail "bad args rc=$rc"

# 10. --scan-env
d="$TMP/scan-clean"; mkdir -p "$d"; : > "$d/.env"; : > "$d/.env.local"
out="$(bash "$HELPER" --scan-env "$d" 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 0 ] && [ -z "$out" ]; } && pass "--scan-env clean: exit 0, no output" || fail "clean rc=$rc out=$out"

d="$TMP/scan-dirty"; mkdir -p "$d"; : > "$d/.env"; : > "$d/.env.prod"; : > "$d/.ENV.Production.bak"; : > "$d/.env.stage-eu"; : > "$d/.env.production_old"
out="$(bash "$HELPER" --scan-env "$d" 2>/dev/null)"; rc=$?
[ "$rc" -eq 1 ] && pass "--scan-env flagged: exit 1" || fail "dirty rc=$rc"
for f in .env.prod .ENV.Production.bak .env.stage-eu .env.production_old; do
  printf '%s\n' "$out" | grep -qxF -- "$f" && pass "--scan-env lists $f" || fail "--scan-env missed $f: $out"
done
printf '%s\n' "$out" | grep -qxF -- '.env' && fail "--scan-env flagged plain .env" || pass "--scan-env does not flag .env"

bash "$HELPER" --scan-env "$TMP/does-not-exist" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "--scan-env missing dir: exit 2" || fail "missing dir rc=$rc"
bash "$HELPER" --scan-env >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "--scan-env without dir: exit 2" || fail "no-dir rc=$rc"

echo
if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; fi
echo "$fails test(s) FAILED."; exit 1
