#!/usr/bin/env bash
#
# Regression test for hooks/block-env-read.sh — the PreToolUse(Bash) hook that
# blocks shell reads / copies / moves / deletes of protected `.env*` files
# while allowing name-only listing and the .example/.sample/.template/.dist
# templates (task #605, slice 597e).
#
# Hermetic: fixtures live in `mktemp -d`; the hook is driven directly with a
# JSON payload. Assertions use only exit codes, stderr text, log entries and
# file names. No test ever reads a fixture's contents, and no real .env file
# is touched. Requires jq (the hook fails open without it).
#
# Run:  hooks/tests/block-env-read.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-env-read.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fixture dir: empty placeholder env files (never read by this test).
FX="$TMP/fx"
mkdir -p "$FX"
: > "$FX/.env"
: > "$FX/.env.local"
: > "$FX/.env.example"

fails=0
cases=0
pass() { cases=$((cases + 1)); printf '  PASS: %s\n' "$1"; }
fail() { cases=$((cases + 1)); printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

LAST_CODE=""
LAST_ERR=""
LAST_LOG=""

# run_hook <command-string>  -> echoes exit code; sets LAST_ERR / LAST_LOG.
# Runs in the current shell (not a subshell) so LAST_* globals survive.
run_hook() {
  local payload
  payload="$(jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}')"
  run_raw "$payload"
}

# run_raw <raw stdin>
run_raw() {
  local d
  d="$(mktemp -d "$TMP/run.XXXXXX")"
  (
    cd "$FX" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$d" \
      bash "$HOOK" <<<"$1" >/dev/null 2>"$d/stderr"
  )
  local code=$?
  LAST_ERR="$(cat "$d/stderr")"
  LAST_LOG=""
  [ -f "$d/.task-log/hook-decisions.jsonl" ] && LAST_LOG="$(cat "$d/.task-log/hook-decisions.jsonl")"
  LAST_CODE="$code"
}

expect_block() {
  local cmd="$1" code
  run_hook "$cmd"; code="$LAST_CODE"
  if [ "$code" != "2" ]; then
    fail "block: $cmd (expected exit 2, got $code)"
  elif ! printf '%s' "$LAST_ERR" | grep -qi 'operator-only'; then
    fail "block: $cmd (stderr lacks 'operator-only')"
  elif ! printf '%s' "$LAST_LOG" | jq -e 'select(.hook=="block-env-read" and .action=="block")' >/dev/null 2>&1; then
    fail "block: $cmd (no block entry in decision log)"
  else
    pass "block: $cmd"
  fi
}

expect_allow() {
  local cmd="$1" code
  run_hook "$cmd"; code="$LAST_CODE"
  if [ "$code" != "0" ]; then
    fail "allow: $cmd (expected exit 0, got $code)"
  else
    pass "allow: $cmd"
  fi
}

# Allow that must also be logged (name-only use of a protected name).
expect_allow_logged() {
  local cmd="$1" code
  run_hook "$cmd"; code="$LAST_CODE"
  if [ "$code" != "0" ]; then
    fail "allow+log: $cmd (expected exit 0, got $code)"
  elif ! printf '%s' "$LAST_LOG" | jq -e 'select(.hook=="block-env-read" and .action=="allow")' >/dev/null 2>&1; then
    fail "allow+log: $cmd (no allow entry in decision log)"
  else
    pass "allow+log: $cmd"
  fi
}

echo "block-env-read — blocked reads/copies/moves/deletes"
expect_block 'cat .env'
expect_block 'cat .env.local'
expect_block 'head -n 3 .env'
expect_block 'tail -f .env.production'
expect_block 'less .env'
expect_block 'more .env'
expect_block 'grep API_KEY .env'
expect_block 'rg SECRET .env.local'
expect_block "awk '{print}' .env"
expect_block "sed -n 1p .env"
expect_block 'source .env'
expect_block '. .env'
expect_block 'while read l; do :; done < .env'
expect_block 'cp .env /tmp/leak'
expect_block 'cp .env.local .env.bak'
expect_block 'mv .env .env.old'
expect_block 'rm .env'
expect_block 'rm -f .env.local'
expect_block "python3 -c \"print(open('.env').read())\""
expect_block "node -e \"console.log(require('fs').readFileSync('.env','utf8'))\""
expect_block 'cat ./.env'
# shellcheck disable=SC2016
expect_block 'cat "$PWD/.env"'
expect_block 'cat .envrc'
expect_block 'cat .env*'
expect_block 'ls && cat .env'
expect_block 'echo hi; cat .env'
expect_block 'echo hi | cat .env'
expect_block 'false || cat .env'
expect_block "echo \$(cat .env)"
# shellcheck disable=SC2016
expect_block 'echo `cat .env`'
expect_block $'ls\ncat .env'
expect_block 'FOO=1 cat .env'
expect_block 'sudo cat .env'
expect_block 'find . -name ".env*" -exec cat {} +'
expect_block 'find . -name ".env" -delete'
expect_block 'git commit -m x && cat .env'
expect_block 'git add src/a.ts; cat .env'
expect_block 'find . -name .env | xargs cat'
expect_block 'find . -name .env -print0 | xargs -0 cat'
expect_block 'ls .env | xargs cat'
expect_block 'ls .env.local | xargs -I{} cp {} /tmp/x'
expect_block 'git commit -F .env'
expect_block 'git commit --file .env'
expect_block 'git commit --file=.env'
expect_block 'git commit -t .env.local'
expect_block 'git commit --template=./sub/.env'
expect_block 'git commit -aF.env'

echo "block-env-read — allowed name-only and templates"
expect_allow_logged 'ls -a .env'
expect_allow_logged 'test -f .env'
expect_allow_logged '[ -f .env.local ]'
expect_allow_logged "find . -name '.env*'"
expect_allow 'ls -a'
expect_allow 'ls -a | grep env'
expect_allow 'ls -a | wc -l'
expect_allow 'git commit -F .env.example'
expect_allow 'git commit -F msg.txt'
expect_allow 'cat .env.example'
expect_allow 'cat .env.sample'
expect_allow 'cat .env.template'
expect_allow 'cat .env.dist'
expect_allow 'grep FOO .env.example'
expect_allow 'cp .env.example /tmp/x'
expect_allow 'git add .env.example'
expect_allow "git commit -m 'document .env handling'"
expect_allow "node -e 'console.log(process.env.HOME)'"
expect_allow "echo import.meta.env.VITE_X"
expect_allow 'cat README.md'

echo "block-env-read — malformed / missing input fails open"
for raw in '' 'not json' '{}' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}' \
           '{"tool_name":"Bash","tool_input":{"command":""}}' \
           '{"tool_name":"Read","tool_input":{"command":"cat .env"}}'; do
  run_raw "$raw"; code="$LAST_CODE"
  if [ "$code" = "0" ]; then pass "fail-open: ${raw:-<empty stdin>}"
  else fail "fail-open: ${raw:-<empty stdin>} (expected 0, got $code)"; fi
done

echo "block-env-read — decision log"
run_hook 'cat .env'; code="$LAST_CODE"
if [ "$code" = "2" ] && printf '%s' "$LAST_LOG" | jq -e 'select(.hook=="block-env-read" and .tool=="Bash" and .action=="block")' >/dev/null 2>&1; then
  pass "log: block entry has hook/tool/action"
else
  fail "log: block entry missing or malformed"
fi

echo
echo "cases: $cases, failures: $fails"
[ "$fails" -eq 0 ] && exit 0 || exit 1
