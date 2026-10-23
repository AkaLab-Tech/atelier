#!/usr/bin/env bash
#
# Regression test for #399 — the safe-commit push gate honours
# `safeCommit.testScope` from the project's `.atelier.json`:
#   "changed" runs `test:changed` instead of `test` when the script exists,
#   falls back to `test` (logged) when it does not; "full", an absent file,
#   an absent key and an unknown value all run `test`. The config is read
#   from the directory holding package.json first, then from the git
#   toplevel of the commit's target worktree.
#
# Hermetic: builds throwaway git repos under a temp dir and drives
# hooks/safe-commit.sh directly. No network, no real pnpm — the package
# manager is shimmed on PATH (a `<pm> run <script>` shim that executes
# the package.json script via sh). Each fixture script appends a marker
# to ./ran.txt so the test can assert which script actually ran.
# Requires git + jq (install.sh Phase-A deps, what the hook itself needs).
#
# Run:  hooks/tests/safe-commit-test-scope.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/safe-commit.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- package-manager shim ---------------------------------------------------
SHIM_BIN="$TMP/bin"
mkdir -p "$SHIM_BIN"
cat > "$SHIM_BIN/pnpm" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "run" ]; then
  script="$(jq -r --arg s "$2" '.scripts[$s] // empty' package.json 2>/dev/null)"
  [ -z "$script" ] && { echo "no script: $2" >&2; exit 1; }
  exec sh -c "$script"
fi
exit 0
SHIM
chmod +x "$SHIM_BIN/pnpm"
export PATH="$SHIM_BIN:$PATH"

# --- helpers ----------------------------------------------------------------

LOG_ROOT="$TMP/logs"
LOG_FILE="$LOG_ROOT/.task-log/hook-decisions.jsonl"

# Run the hook as Claude Code would: PWD = $1, payload = the Bash command
# in $2. Echoes the exit code. The decision log is reset per run so each
# scenario asserts only its own lines.
run_hook() {
  local pwd_dir="$1" command_str="$2"
  local payload
  rm -rf "$LOG_ROOT"
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$pwd_dir" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$LOG_ROOT" \
      bash "$HOOK" <<<"$payload" >/dev/null 2>&1
  )
  echo "$?"
}

# Like run_hook but echoes the hook's stderr (the block message).
run_hook_stderr() {
  local pwd_dir="$1" command_str="$2"
  local payload
  rm -rf "$LOG_ROOT"
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$pwd_dir" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$LOG_ROOT" \
      bash "$HOOK" <<<"$payload" 2>&1 1>/dev/null
  )
}

# Build a repo at $1 whose package.json defines `test` (marker "full") and,
# unless $2 is "no-changed", `test:changed` (marker "changed", exit code
# from $3, default 0). Commits the fixture so later scenarios can stage a
# non-docs file on top.
make_project() {
  local dir="$1" variant="${2:-with-changed}" changed_exit="${3:-0}"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  if [ "$variant" = "no-changed" ]; then
    cat > "$dir/package.json" <<'PKG'
{ "name": "fixture", "version": "0.0.0",
  "scripts": { "test": "echo full >> ./ran.txt" } }
PKG
  else
    cat > "$dir/package.json" <<PKG
{ "name": "fixture", "version": "0.0.0",
  "scripts": { "test": "echo full >> ./ran.txt",
               "test:changed": "echo changed >> ./ran.txt; exit $changed_exit" } }
PKG
  fi
  : > "$dir/pnpm-lock.yaml"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
}

# Stage a non-docs file so the F48 docs-only short-circuit does not fire.
stage_feature() {
  printf 'console.log(1)\n' > "$1/feature.js"
  git -C "$1" add -A
}

write_scope() {
  printf '{ "safeCommit": { "testScope": "%s" } }\n' "$2" > "$1/.atelier.json"
}

ran() { cat "$1/ran.txt" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

log_has() { grep -q "\"pattern\":\"$1\"" "$LOG_FILE" 2>/dev/null; }

echo "#399 regression — safe-commit honours safeCommit.testScope"

# === 1: changed + test:changed defined → runs test:changed only ==============
S1="$TMP/s1"; make_project "$S1"; write_scope "$S1" changed; stage_feature "$S1"
code="$(run_hook "$S1" "git commit -m x")"
[ "$code" = "0" ] && [ "$(ran "$S1")" = "changed" ] \
  && pass "changed + test:changed → ran test:changed only (exit 0)" \
  || fail "changed + test:changed: expected exit 0 and ran=changed, got exit $code ran='$(ran "$S1")'"
log_has "test:changed-green" \
  && pass "changed + test:changed → log names test:changed-green" \
  || fail "changed + test:changed: log lacks test:changed-green"

# === 2: no .atelier.json → runs test =========================================
S2="$TMP/s2"; make_project "$S2"; stage_feature "$S2"
code="$(run_hook "$S2" "git commit -m x")"
[ "$code" = "0" ] && [ "$(ran "$S2")" = "full" ] \
  && pass "no .atelier.json → ran test (exit 0)" \
  || fail "no .atelier.json: expected ran=full, got exit $code ran='$(ran "$S2")'"

# === 3: explicit full → runs test ============================================
S3="$TMP/s3"; make_project "$S3"; write_scope "$S3" full; stage_feature "$S3"
code="$(run_hook "$S3" "git commit -m x")"
[ "$code" = "0" ] && [ "$(ran "$S3")" = "full" ] \
  && pass "testScope full → ran test (exit 0)" \
  || fail "testScope full: expected ran=full, got exit $code ran='$(ran "$S3")'"

# === 4: changed without test:changed → falls back to test, logged ============
S4="$TMP/s4"; make_project "$S4" no-changed; write_scope "$S4" changed; stage_feature "$S4"
code="$(run_hook "$S4" "git commit -m x")"
[ "$code" = "0" ] && [ "$(ran "$S4")" = "full" ] \
  && pass "changed without test:changed → fell back to test (exit 0)" \
  || fail "changed without test:changed: expected ran=full, got exit $code ran='$(ran "$S4")'"
log_has "test-changed-na" \
  && pass "changed without test:changed → log has test-changed-na" \
  || fail "changed without test:changed: log lacks test-changed-na"

# === 5: changed with red test:changed → blocked, stderr names the script =====
S5="$TMP/s5"; make_project "$S5" with-changed 1; write_scope "$S5" changed; stage_feature "$S5"
code="$(run_hook "$S5" "git commit -m x")"
[ "$code" = "2" ] \
  && pass "changed with red test:changed → blocked (exit 2)" \
  || fail "changed with red test:changed: expected exit 2, got $code"
stderr="$(run_hook_stderr "$S5" "git commit -m x")"
echo "$stderr" | grep -q 'pnpm run test:changed' \
  && pass "red test:changed → block message names 'pnpm run test:changed'" \
  || fail "red test:changed: stderr did not name test:changed (got: $(echo "$stderr" | tr '\n' ' '))"
log_has "test:changed-red" \
  && pass "red test:changed → log names test:changed-red" \
  || fail "red test:changed: log lacks test:changed-red"

# === 6: unknown value → runs test, logged as invalid =========================
S6="$TMP/s6"; make_project "$S6"; write_scope "$S6" banana; stage_feature "$S6"
code="$(run_hook "$S6" "git commit -m x")"
[ "$code" = "0" ] && [ "$(ran "$S6")" = "full" ] \
  && pass "testScope banana → ran test (exit 0)" \
  || fail "testScope banana: expected ran=full, got exit $code ran='$(ran "$S6")'"
log_has "test-scope-invalid" \
  && pass "testScope banana → log has test-scope-invalid" \
  || fail "testScope banana: log lacks test-scope-invalid"

# === 7: linked worktree, .atelier.json only at the worktree root =============
# PWD = main repo (atelier's cwd-vs-worktree rule), command targets the
# worktree with `git -C`. The config lives in the worktree, not in main.
S7="$TMP/s7"; make_project "$S7/main"
git -C "$S7/main" worktree add -q -b task/x "$S7/wt"
write_scope "$S7/wt" changed; stage_feature "$S7/wt"
code="$(run_hook "$S7/main" "git -C $S7/wt commit -m x")"
[ "$code" = "0" ] && [ "$(ran "$S7/wt")" = "changed" ] && [ ! -f "$S7/main/ran.txt" ] \
  && pass "linked worktree → config read from the worktree root, ran test:changed there" \
  || fail "linked worktree: expected ran=changed in wt only, got exit $code wt='$(ran "$S7/wt")' main='$(ran "$S7/main")'"

# === 8: package.json in a subdir, .atelier.json at the git toplevel ==========
# `git -C <member> commit` inside a workspace: project_root is the member,
# the config sits at the repo root — the toplevel fallback must find it.
S8="$TMP/s8"; mkdir -p "$S8"
git -C "$S8" init -q -b main
git -C "$S8" config user.email t@t.t
git -C "$S8" config user.name t
mkdir -p "$S8/app"
cat > "$S8/app/package.json" <<'PKG'
{ "name": "member", "version": "0.0.0",
  "scripts": { "test": "echo full >> ./ran.txt",
               "test:changed": "echo changed >> ./ran.txt" } }
PKG
: > "$S8/app/pnpm-lock.yaml"
write_scope "$S8" changed
git -C "$S8" add -A
git -C "$S8" commit -qm init
stage_feature "$S8/app"
code="$(run_hook "$TMP" "git -C $S8/app commit -m x")"
[ "$code" = "0" ] && [ "$(ran "$S8/app")" = "changed" ] \
  && pass "config at git toplevel, package.json in subdir → ran test:changed" \
  || fail "toplevel fallback: expected ran=changed, got exit $code ran='$(ran "$S8/app")'"

echo
if [ "$fails" -eq 0 ]; then
  echo "All #399 regression checks passed."
  exit 0
else
  echo "$fails #399 regression check(s) FAILED."
  exit 1
fi
