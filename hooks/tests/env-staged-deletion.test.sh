#!/usr/bin/env bash
#
# Regression test for task #762 — a staged (or about-to-be-staged) DELETION of
# an env-named file must never be blocked by block-env-commit.sh or
# scan-git-add.sh: removing a secret from version control is the fix, not the
# problem. Controls prove that adding / modifying a real env file is still
# blocked in the same repos.
#
# Hermetic: throwaway git repos under mktemp, hooks driven directly with a
# JSON payload, isolated git config. No network. Requires git + jq.
#
# Run:  hooks/tests/env-staged-deletion.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2016  # test commands are literal text; no expansion wanted
# shellcheck disable=SC2015  # `A && pass || fail`: pass never fails

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMIT_HOOK="$REPO_ROOT/hooks/block-env-commit.sh"
SCAN_HOOK="$REPO_ROOT/hooks/scan-git-add.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/home/.config"
mkdir -p "$XDG_CONFIG_HOME"

fails=0
cases=0
pass() { cases=$((cases + 1)); printf '  PASS: %s\n' "$1"; }
fail() { cases=$((cases + 1)); printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

run_hook() {
  local hook="$1" cwd="$2" cmd="$3" payload
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$cwd" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$hook" <<<"$payload" >/dev/null 2>&1
  )
  echo "$?"
}

expect_code() {
  local label="$1" want="$2" code
  code="$(run_hook "$3" "$4" "$5")"
  if [ "$code" = "$want" ]; then pass "$label"
  else fail "$label (expected exit $want, got $code)"; fi
}

hook_label() { case "$1" in "$COMMIT_HOOK") echo block-env-commit ;; *) echo scan-git-add ;; esac; }

# make_repo <name> <file>... -> a repo where each <file> is ALREADY COMMITTED
# (force-added, since the point is the removal of a tracked env file).
make_repo() {
  local d="$TMP/$1"; shift
  local f
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf '# fixture\n' > "$d/README.md"
  for f in "$@"; do
    mkdir -p "$(dirname "$d/$f")"
    printf 'API_KEY=your_api_key_here\n' > "$d/$f"
  done
  git -C "$d" add -A
  [ "$#" -gt 0 ] && git -C "$d" add -f -- "$@"
  git -C "$d" commit -qm init
  echo "$d"
}

TRACKED=(.env .env.prod .env.local .envrc scripts/.env.catalog.example)

for hook in "$COMMIT_HOOK" "$SCAN_HOOK"; do
  h="$(hook_label "$hook")"
  echo "$h — staged deletions of env files are never blocked"

  for f in "${TRACKED[@]}"; do
    # git rm --cached: command text alone, then with the deletion really staged.
    R="$(make_repo "rmc-$h-$(basename "$f")" "$f")"
    expect_code "$h: git rm --cached $f -> allow" 0 "$hook" "$R" "git rm --cached $f"
    git -C "$R" rm -q --cached -- "$f"
    expect_code "$h: commit with $f deletion staged (--cached) -> allow" 0 "$hook" "$R" "git commit -m remove"
    expect_code "$h: git -C <wt> commit with $f deletion staged -> allow" 0 "$hook" "$TMP" "git -C $R commit -m remove"
    expect_code "$h: commit -a with $f deletion staged -> allow" 0 "$hook" "$R" "git commit -a -m remove"
    expect_code "$h: commit -am with $f deletion staged -> allow" 0 "$hook" "$R" "git commit -am remove"
  done

  for f in .env .env.prod scripts/.env.catalog.example; do
    # git rm: removes from worktree and index.
    R="$(make_repo "rm-$h-$(basename "$f")" "$f")"
    expect_code "$h: git rm $f -> allow" 0 "$hook" "$R" "git rm $f"
    expect_code "$h: git rm -f $f -> allow" 0 "$hook" "$R" "git rm -f $f"
    git -C "$R" rm -q -- "$f"
    expect_code "$h: commit with $f removed via git rm -> allow" 0 "$hook" "$R" "git commit -m remove"
    expect_code "$h: commit -a with $f removed via git rm -> allow" 0 "$hook" "$R" "git commit -a -m remove"
  done

  echo "$h — a deleted file picked up by git add"
  for f in .env .env.prod scripts/.env.catalog.example; do
    R="$(make_repo "del-$h-$(basename "$f")" "$f")"
    rm -f "$R/$f"
    expect_code "$h: git add -A with $f deleted -> allow" 0 "$hook" "$R" "git add -A"
    expect_code "$h: git -C <wt> add -A with $f deleted -> allow" 0 "$hook" "$TMP" "git -C $R add -A"
    expect_code "$h: git add . with $f deleted -> allow" 0 "$hook" "$R" "git add ."
    expect_code "$h: git add $f (deleted path) -> allow" 0 "$hook" "$R" "git add $f"
    expect_code "$h: git -C <wt> add $f (deleted path) -> allow" 0 "$hook" "$TMP" "git -C $R add $f"
    expect_code "$h: git add -u with $f deleted -> allow" 0 "$hook" "$R" "git add -u"
    expect_code "$h: commit -a with $f deleted (unstaged) -> allow" 0 "$hook" "$R" "git commit -a -m remove"
    expect_code "$h: commit -am with $f deleted (unstaged) -> allow" 0 "$hook" "$R" "git commit -am remove"
  done

  echo "$h — deletion plus an unrelated change"
  R="$(make_repo "mixdel-$h" .env)"
  rm -f "$R/.env"
  printf 'x\n' > "$R/src.txt"
  expect_code "$h: git add -A with .env deleted and src.txt new -> allow" 0 "$hook" "$R" "git add -A"
  git -C "$R" add -A
  expect_code "$h: commit with .env deletion + src.txt staged -> allow" 0 "$hook" "$R" "git commit -m x"

  echo "$h — controls: adding or modifying a real env file is still blocked"
  # Deleted .env is fine, but a NEW .env.prod in the same tree is not.
  R="$(make_repo "ctl-new-$h" .env)"
  rm -f "$R/.env"
  printf 'API_KEY=your_api_key_here\n' > "$R/.env.prod"
  expect_code "$h: git add -A with .env deleted + .env.prod untracked -> block" 2 "$hook" "$R" "git add -A"
  expect_code "$h: git add .env.prod -> block" 2 "$hook" "$R" "git add .env.prod"

  # The deleted path is recreated (no longer a deletion): block.
  R="$(make_repo "ctl-recreate-$h" .env)"
  printf 'API_KEY=changed_value\n' > "$R/.env"
  expect_code "$h: git add .env (present, modified) -> block" 2 "$hook" "$R" "git add .env"
  expect_code "$h: git add -A with .env modified -> block" 2 "$hook" "$R" "git add -A"

  # A never-tracked, absent path is not a deletion either.
  R="$(make_repo "ctl-unknown-$h")"
  printf 'API_KEY=your_api_key_here\n' > "$R/.env"
  expect_code "$h: git add .env (new file) -> block" 2 "$hook" "$R" "git add .env"
done

echo "block-env-commit — commit-side controls"
R="$(make_repo "ctl-commit-a" .env)"
printf 'API_KEY=changed_value\n' > "$R/.env"
expect_code "block-env-commit: commit -a with tracked .env modified -> block" 2 "$COMMIT_HOOK" "$R" "git commit -a -m x"
R="$(make_repo "ctl-commit-staged" .env)"
printf 'API_KEY=changed_value\n' > "$R/.env"
git -C "$R" add -f .env
expect_code "block-env-commit: commit with .env modification staged -> block" 2 "$COMMIT_HOOK" "$R" "git commit -m x"
R="$(make_repo "ctl-commit-mixed" .env)"
git -C "$R" rm -q -- .env
printf 'API_KEY=your_api_key_here\n' > "$R/.env.prod"
git -C "$R" add -f .env.prod
expect_code "block-env-commit: .env deletion + .env.prod addition staged -> block" 2 "$COMMIT_HOOK" "$R" "git commit -m x"

echo
echo "cases: $cases, failures: $fails"
[ "$fails" -eq 0 ] && exit 0 || exit 1
