#!/usr/bin/env bash
#
# Regression test for M7.1.F57 — the safe-commit push gate must validate
# the commit's TARGET WORKTREE, not the hook's inherited cwd ($PWD, which
# under atelier's cwd-vs-worktree rule is the main repo), and must use the
# worktree project's package manager rather than a hardcoded `pnpm`.
#
# Hermetic: builds a throwaway git repo + linked worktree under a temp dir
# and drives hooks/safe-commit.sh directly. No network, no real pnpm/npm —
# package managers are shimmed on PATH (a `<pm> run <script>` shim that
# executes the package.json script via sh). Requires git + jq (both are
# install.sh Phase-A deps and are what the hook itself needs).
#
# Run:  hooks/tests/safe-commit-worktree.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/safe-commit.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- package-manager shims --------------------------------------------------
# Each shim implements `<pm> run <script>`: read package.json#scripts[$2]
# in the cwd and exec it. Lets the test assert which PM the hook picked
# without installing anything.
SHIM_BIN="$TMP/bin"
mkdir -p "$SHIM_BIN"
for pm in pnpm npm yarn bun; do
  cat > "$SHIM_BIN/$pm" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "run" ]; then
  script="$(jq -r --arg s "$2" '.scripts[$s] // empty' package.json 2>/dev/null)"
  [ -z "$script" ] && { echo "no script: $2" >&2; exit 1; }
  exec sh -c "$script"
fi
exit 0
SHIM
  chmod +x "$SHIM_BIN/$pm"
done
export PATH="$SHIM_BIN:$PATH"

# --- helpers ----------------------------------------------------------------

# Run the hook as Claude Code would: PWD = main repo, payload = a Bash
# git-commit command targeting the worktree. Echoes the exit code.
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

# Like run_hook but echoes the hook's combined stderr (the block message)
# instead of the exit code.
run_hook_stderr() {
  local pwd_dir="$1" command_str="$2"
  local payload
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$pwd_dir" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$HOOK" <<<"$payload" 2>&1 1>/dev/null
  )
}

# Build a main repo whose `typecheck` exits with the contents of ./exitcode
# (so each working tree controls pass/fail independently), plus a lockfile
# selecting $1 as the package manager.
make_project() {
  local dir="$1" lockfile="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  cat > "$dir/package.json" <<'PKG'
{ "name": "fixture", "version": "0.0.0", "scripts": { "typecheck": "sh ./tc.sh" } }
PKG
  printf 'exit "$(cat ./exitcode 2>/dev/null || echo 0)"\n' > "$dir/tc.sh"
  printf '0\n' > "$dir/exitcode"
  : > "$dir/$lockfile"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
}

echo "F57 regression — safe-commit validates the worktree, not \$PWD"

# === Scenario 1: worktree broken, main clean → gate BLOCKS (exit 2) =========
# Proves the gate runs against the worktree's files. If it validated $PWD
# (the clean main repo) it would wrongly allow.
S1="$TMP/s1"; make_project "$S1/main" pnpm-lock.yaml
git -C "$S1/main" worktree add -q -b task/x "$S1/wt"
printf '1\n' > "$S1/wt/exitcode"          # break typecheck in the worktree only
printf 'console.log(1)\n' > "$S1/wt/feature.js"
git -C "$S1/wt" add -A                      # stage a non-docs file so the gate runs
code="$(run_hook "$S1/main" "git -C $S1/wt commit -m x")"
[ "$code" = "2" ] && pass "worktree-broken → blocked (exit 2)" \
                   || fail "worktree-broken expected exit 2, got $code"

# === Scenario 2: worktree clean, main broken → gate ALLOWS (exit 0) =========
# Proves a broken MAIN repo does not mask the worktree result — the gate
# never even looks at main.
S2="$TMP/s2"; make_project "$S2/main" pnpm-lock.yaml
git -C "$S2/main" worktree add -q -b task/y "$S2/wt"
printf '1\n' > "$S2/main/exitcode"         # break typecheck in MAIN only
printf 'console.log(1)\n' > "$S2/wt/feature.js"
git -C "$S2/wt" add -A
code="$(run_hook "$S2/main" "git -C $S2/wt commit -m x")"
[ "$code" = "0" ] && pass "main-broken/worktree-clean → allowed (exit 0)" \
                   || fail "main-broken/worktree-clean expected exit 0, got $code"

# === Scenario 3: package-manager detection — npm lockfile → `npm run` =======
# Proves the gate uses the worktree project's package manager, not pnpm.
S3="$TMP/s3"; make_project "$S3/main" package-lock.json
git -C "$S3/main" worktree add -q -b task/z "$S3/wt"
printf '1\n' > "$S3/wt/exitcode"
printf 'console.log(1)\n' > "$S3/wt/feature.js"
git -C "$S3/wt" add -A
stderr="$(run_hook_stderr "$S3/main" "git -C $S3/wt commit -m x")"
echo "$stderr" | grep -q 'npm run typecheck' \
  && pass "npm lockfile → gate reports 'npm run typecheck'" \
  || fail "npm detection: stderr did not mention 'npm run typecheck' (got: $(echo "$stderr" | tr '\n' ' '))"

echo
if [ "$fails" -eq 0 ]; then
  echo "All F57 regression checks passed."
  exit 0
else
  echo "$fails F57 regression check(s) FAILED."
  exit 1
fi
