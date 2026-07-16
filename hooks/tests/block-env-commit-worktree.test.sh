#!/usr/bin/env bash
#
# Regression test for M7.1.F57 — block-env-commit.sh must resolve the
# TARGET WORKTREE from the command (`git -C <wt>` / `cd <wt> &&` forms)
# and point its git introspection (untracked/staged scans) at that dir,
# not at the hook's inherited $PWD (which under atelier's cwd-vs-worktree
# rule is the main repo).
#
# Hermetic: builds a throwaway git repo + linked worktree under a temp dir
# and drives hooks/block-env-commit.sh directly. No network. Requires
# git + jq (both are install.sh Phase-A deps and are all this hook needs —
# it never shells out to a package manager).
#
# Run:  hooks/tests/block-env-commit-worktree.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-env-commit.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate git config: on a machine that has run install.sh Phase C.1,
# `.env*` is in the OPERATOR'S REAL global excludesfile — by default git
# reads that from $XDG_CONFIG_HOME/git/ignore (~/.config/git/ignore) even
# with no core.excludesfile set explicitly. That would make our throwaway
# `.env` "ignored" rather than "untracked" (git's own
# `ls-files --others --exclude-standard` — same one the hook calls —
# skips ignored paths), silently defeating the wildcard-add assertions
# below. Point HOME/XDG_CONFIG_HOME at an empty dir and blank out the
# global/system gitconfig so every git invocation in this test only sees
# the fixture repos we build, never the host's install state.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/home/.config"
mkdir -p "$XDG_CONFIG_HOME"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- helpers ----------------------------------------------------------------

# Run the hook as Claude Code would: PWD = main repo, payload = a Bash
# git-add/commit command targeting the worktree. Echoes the exit code.
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

# Build a main repo + linked worktree under $1 (a scenario dir). The main
# repo is committed and clean; the worktree is on its own branch.
make_project_and_worktree() {
  local dir="$1"
  local main="$dir/main" wt="$dir/wt"
  mkdir -p "$main"
  git -C "$main" init -q -b main
  git -C "$main" config user.email t@t.t
  git -C "$main" config user.name t
  printf '# fixture\n' > "$main/README.md"
  git -C "$main" add -A
  git -C "$main" commit -qm init
  git -C "$main" worktree add -q -b "task/$(basename "$dir")" "$wt"
}

echo "F57 regression — block-env-commit resolves the worktree, not \$PWD"

# === Assertion 1: git -C <wt> add .env.local (untracked, explicit path) =====
S1="$TMP/s1"; make_project_and_worktree "$S1"
printf 'SECRET=1\n' > "$S1/wt/.env.local"
code="$(run_hook "$S1/main" "git -C $S1/wt add .env.local")"
[ "$code" = "2" ] && pass "git -C <wt> add .env.local → blocked (exit 2)" \
                   || fail "git -C <wt> add .env.local expected exit 2, got $code"

# === Assertion 2: git -C <wt> add -f .env.local (forced, explicit path) ====
S2="$TMP/s2"; make_project_and_worktree "$S2"
printf 'SECRET=1\n' > "$S2/wt/.env.local"
code="$(run_hook "$S2/main" "git -C $S2/wt add -f .env.local")"
[ "$code" = "2" ] && pass "git -C <wt> add -f .env.local → blocked (exit 2)" \
                   || fail "git -C <wt> add -f .env.local expected exit 2, got $code"

# === Assertion 3: git -C <wt> add . with untracked .env (wildcard) =========
# Proves the target_dir introspection works: the wildcard scan asks git
# (scoped to target_dir) what an add-everything would pick up.
S3="$TMP/s3"; make_project_and_worktree "$S3"
printf 'SECRET=1\n' > "$S3/wt/.env"
code="$(run_hook "$S3/main" "git -C $S3/wt add .")"
[ "$code" = "2" ] && pass "git -C <wt> add . (untracked .env) → blocked (exit 2)" \
                   || fail "git -C <wt> add . (untracked .env) expected exit 2, got $code"

# === Assertion 4: cd <wt> && git add . with untracked .env (cd-prefix) =====
S4="$TMP/s4"; make_project_and_worktree "$S4"
printf 'SECRET=1\n' > "$S4/wt/.env"
code="$(run_hook "$S4/main" "cd $S4/wt && git add .")"
[ "$code" = "2" ] && pass "cd <wt> && git add . (untracked .env) → blocked (exit 2)" \
                   || fail "cd <wt> && git add . (untracked .env) expected exit 2, got $code"

# === Assertion 5 (CONTROL): git -C <wt> add src/index.ts, no .env* present =
S5="$TMP/s5"; make_project_and_worktree "$S5"
mkdir -p "$S5/wt/src"
printf 'export const x = 1;\n' > "$S5/wt/src/index.ts"
code="$(run_hook "$S5/main" "git -C $S5/wt add src/index.ts")"
[ "$code" = "0" ] && pass "git -C <wt> add src/index.ts (no .env*) → allowed (exit 0)" \
                   || fail "control expected exit 0, got $code"

# === Assertion 6: git -C <wt> commit -a -m x (modified tracked dotenv) ====
# The leaking bypass the reviewer caught: `.env.local` is TRACKED (force-
# added and committed), then modified but left unstaged. `commit -a`
# re-stages tracked-modified files at commit time — must now block.
S6="$TMP/s6"; make_project_and_worktree "$S6"
printf 'SECRET=1\n' > "$S6/wt/.env.local"
git -C "$S6/wt" add -f .env.local
git -C "$S6/wt" commit -qm "add tracked dotenv"
printf 'SECRET=2\n' > "$S6/wt/.env.local"
code="$(run_hook "$S6/main" "git -C $S6/wt commit -a -m x")"
[ "$code" = "2" ] && pass "git -C <wt> commit -a -m x (modified tracked dotenv) → blocked (exit 2)" \
                   || fail "git -C <wt> commit -a -m x expected exit 2, got $code"

# === Assertion 7: git -C <wt> commit -am x (attached -a flag variant) ======
S7="$TMP/s7"; make_project_and_worktree "$S7"
printf 'SECRET=1\n' > "$S7/wt/.env.local"
git -C "$S7/wt" add -f .env.local
git -C "$S7/wt" commit -qm "add tracked dotenv"
printf 'SECRET=2\n' > "$S7/wt/.env.local"
code="$(run_hook "$S7/main" "git -C $S7/wt commit -am x")"
[ "$code" = "2" ] && pass "git -C <wt> commit -am x (modified tracked dotenv) → blocked (exit 2)" \
                   || fail "git -C <wt> commit -am x expected exit 2, got $code"

# === Assertion 8 (CONTROL): cd <wt> && git commit -a -m x, modified tracked
#     dotenv — proves the cwd form still blocks (sibling parity with -C) ====
S8="$TMP/s8"; make_project_and_worktree "$S8"
printf 'SECRET=1\n' > "$S8/wt/.env.local"
git -C "$S8/wt" add -f .env.local
git -C "$S8/wt" commit -qm "add tracked dotenv"
printf 'SECRET=2\n' > "$S8/wt/.env.local"
code="$(run_hook "$S8/main" "cd $S8/wt && git commit -a -m x")"
[ "$code" = "2" ] && pass "cd <wt> && git commit -a -m x (modified tracked dotenv) → blocked (exit 2)" \
                   || fail "cd <wt> && git commit -a -m x expected exit 2, got $code"

# === Assertion 9 (CONTROL): git -C <wt> commit -a -m x, only a normal
#     tracked source file modified, no dotenv anywhere → no false positive =
S9="$TMP/s9"; make_project_and_worktree "$S9"
mkdir -p "$S9/wt/src"
printf 'export const x = 1;\n' > "$S9/wt/src/index.ts"
git -C "$S9/wt" add src/index.ts
git -C "$S9/wt" commit -qm "add source file"
printf 'export const x = 2;\n' > "$S9/wt/src/index.ts"
code="$(run_hook "$S9/main" "git -C $S9/wt commit -a -m x")"
[ "$code" = "0" ] && pass "git -C <wt> commit -a -m x (no dotenv, modified source only) → allowed (exit 0)" \
                   || fail "control expected exit 0, got $code"

echo
if [ "$fails" -eq 0 ]; then
  echo "All F57 block-env-commit regression checks passed."
  exit 0
else
  echo "$fails F57 block-env-commit regression check(s) FAILED."
  exit 1
fi
