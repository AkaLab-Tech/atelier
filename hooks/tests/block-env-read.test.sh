#!/usr/bin/env bash
#
# Regression test for hooks/block-env-read.sh — the PreToolUse(Bash) hook that
# blocks shell reads / copies / moves / deletes of protected `.env*` files
# while allowing name-only listing and the .example/.sample/.template/.dist
# templates (task #605, slice 597e; task #625).
#
# Hermetic: fixtures live in `mktemp -d`; the hook is driven directly with a
# JSON payload. Assertions use only exit codes, stderr text, log entries and
# file names. No test ever reads a fixture's contents, and no real .env file
# is touched. Requires jq (the hook fails open without it).
#
# Run:  hooks/tests/block-env-read.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2016  # test commands are literal text; no expansion wanted

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

# Fixture dirs for cwd-dependent rules (passed through HOOK_CWD).
HOOK_CWD=""
ABS="$TMP/abs"; mkdir -p "$ABS"; : > "$ABS/.env.example"          # no env file present
CLEANTREE="$TMP/cleantree"; mkdir -p "$CLEANTREE/src"
: > "$CLEANTREE/.env"; : > "$CLEANTREE/src/a.ts"; : > "$CLEANTREE/src/.env.example"
DIRTYTREE="$TMP/dirtytree"; mkdir -p "$DIRTYTREE/src"
: > "$DIRTYTREE/src/a.ts"; : > "$DIRTYTREE/src/.env"

fails=0
cases=0
pass() { cases=$((cases + 1)); printf '  PASS: %s\n' "$1"; }
fail() { cases=$((cases + 1)); printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

LAST_CODE=""
LAST_ERR=""
LAST_LOG=""

# run_hook <command-string>  -> echoes exit code; sets LAST_ERR / LAST_LOG.
# Runs in the current shell (not a subshell) so LAST_* globals survive.
# When HOOK_CWD is set, it is passed as the hook input `cwd`.
run_hook() {
  local payload
  if [ -n "${HOOK_CWD:-}" ]; then
    payload="$(jq -cn --arg c "$1" --arg d "$HOOK_CWD" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')"
  else
    payload="$(jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}')"
  fi
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
expect_block 'ls .env & cat .env'
expect_block 'test -f .env & cat .env'
expect_block 'ls & cat .env'
expect_allow 'ls .env 2>&1'
expect_allow 'ls .env &>/dev/null'
expect_block 'ls .env.local | xargs -I{} cp {} /tmp/x'
expect_block 'cat $(ls .env)'
expect_block 'cat `ls .env`'
expect_block 'cat $(find . -name .env)'
expect_block 'cp $(find . -name .env.local) /tmp/x'
expect_block 'for f in $(ls .env); do cat "$f"; done'
expect_block 'xargs cat <<< $(ls .env)'
expect_block 'cat <(ls .env)'
expect_block 'ls .env $(date) | xargs cat'
expect_allow 'echo $(date) && ls -a'
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
expect_block 'cat {.env,x}'
expect_allow 'git commit -F .env.example'
expect_allow 'git commit -F msg.txt'
expect_allow 'cat .env.example'
expect_allow 'cat {.env.example,x}'
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

echo "block-env-read — task #625 compound pipelines"
expect_block '{ ls .env; } | xargs cat'
expect_block '(ls .env) | xargs cat'
expect_allow '{ test -f .env; }'
expect_allow '(test -f .env)'

echo "block-env-read — task #625 case-insensitive matching"
expect_block 'cat .ENV'
expect_block 'cat .Env'
expect_block 'cat .ENV.local'
expect_allow 'cat .ENV.example'
expect_allow 'cat .Env.SAMPLE'

echo "block-env-read — task #625 recursive grep detection"
expect_block 'grep -r query .'
expect_block 'grep -rn needle'
expect_block 'grep -R needle dir/'
expect_allow 'grep -r --exclude=".env*" query .'
expect_allow 'grep -r --exclude="*.env*" query .'
expect_allow 'grep query file.txt'

echo "block-env-read — task #625 runtime --env-file flag"
expect_allow 'node --env-file=.env index.js'
expect_allow 'tsx --env-file=.env script.ts'
expect_block "node -e \"fs.readFileSync('.env')\""

echo "block-env-read — task #625 template copying"
# #686: the destination already exists in the fixture dir -> overwrite blocked.
expect_block '[ -f .env ] || cp .env.example .env'
expect_block 'cp .env.example .env'
expect_block 'cp .env.example .env.local'
HOOK_CWD="$ABS"
expect_allow 'cp .env.example .env'
expect_allow '[ -f .env ] || cp .env.example .env'
expect_allow 'cp .env.example .env.local'
HOOK_CWD=""
# #686 review fix: cwd has no env file, sub/ has one; a cd/pushd makes a
# relative destination unresolvable, an absolute one is still checked.
CDFX="$TMP/cdfx"; mkdir -p "$CDFX/sub"
: > "$CDFX/.env.example"; : > "$CDFX/sub/.env"
HOOK_CWD="$CDFX"
expect_block 'cd sub && cp .env.example .env'
expect_block 'pushd sub && cp .env.example .env'
expect_block 'cp .env.example sub/.env'
expect_allow 'cp .env.example .env'
expect_allow "cd sub && cp .env.example $CDFX/nonexistent-dest/.env"
HOOK_CWD=""
expect_block 'cp .env /tmp/copy'
expect_block 'cp .env .env.bak'
expect_block 'cp .env .env.example'

echo "block-env-read — task #686 s1 --env-file with dumping runtimes"
expect_block 'node --env-file=.env -p "JSON.stringify(process.env)"'
expect_block 'node --env-file=.env --print "process.env"'
expect_block 'node --env-file=.env -e "console.log(process.env)"'
expect_block 'node --env-file=.env --eval "console.log(process.env)"'
expect_block 'bun --env-file=.env -e "console.log(Bun.env)"'
expect_block 'docker run --rm --env-file .env alpine env'
expect_block 'docker run --rm --env-file .env alpine printenv'
expect_block 'docker-compose --env-file .env config'
expect_block 'docker compose --env-file .env config'
expect_block 'pnpm --env-file=.env exec printenv'
expect_block 'npx --env-file=.env printenv'
expect_allow 'node --env-file=.env server.js'

echo "block-env-read — task #686 s2 cp target-directory forms"
expect_block 'cp -t/tmp/leak a.example .env'
expect_block 'cp -t /tmp/leak a.example .env'
expect_block 'cp --target=/tmp/x.example a.example .env'
expect_block 'cp --target-directory=/tmp/x.example a.example .env'
expect_block 'cp -at /tmp/x.example .env'
expect_block 'cp -ta /tmp/x.example .env'
expect_block 'cp --targ=/tmp/x.example a.example .env'
expect_block 'cp --t=/tmp/x.example a.example .env'
expect_block 'cp --target-dir /tmp/x.example a.example .env'
# Target dirs without a 't' (the /tmp cases above pass by accident via the 't').
expect_block 'cp -t /var/x.example a.example .env*'
expect_block 'cp -t/var/leak a.example .env*'
expect_block 'cp -t /var/x a.example .env'
expect_block 'cp -t/var/x a.example .env'
expect_block 'cp -at /var/x a.example .env'
expect_block 'cp -ta /var/x a.example .env'
# Glob operands that can expand to env files, source or destination.
expect_block 'cp a.example .env*'
expect_block 'cp a.example .env?'
expect_block "cp a.example '.env[a-z]'"
# Plain template copy with an absent destination stays allowed (cwd has no .env.local).
HOOK_CWD="$CDFX"
expect_allow 'cp .env.example .env.local'
expect_allow 'cp -v .env.example .env.local'
HOOK_CWD=""

echo "block-env-read — task #686 s3 grep --exclude must cover .env"
expect_block 'grep -r --exclude=.envrc SECRET .'
expect_block "grep -r --exclude='*.env' SECRET ."
expect_allow "grep -r --exclude='.env*' X ."
expect_allow 'grep -r --exclude=.env* X .'
expect_allow "grep -r --exclude '.env*' X ."
expect_allow 'grep -r --exclude ".env*" X .'
expect_allow "grep -r --exclude='*.env*' X ."
expect_allow 'grep -r --exclude=*.env* X .'
expect_allow "grep -r --exclude '*.env*' X ."

echo "block-env-read — task #686 s4 recursive grep variants"
expect_block 'grep -d recurse SECRET .'
expect_block 'grep --directories=recurse SECRET .'
expect_block 'grep --directories recurse SECRET .'
expect_block 'env grep -r SECRET .'
expect_block 'env -i grep -r SECRET .'
expect_block 'timeout 5 grep -r SECRET .'
expect_block 'nice -n 5 grep -r SECRET .'
expect_block 'nohup grep -r SECRET .'
expect_block 'time grep -r SECRET .'
expect_block 'xargs grep -r SECRET .'
expect_block '\grep -r SECRET .'
expect_block 'ggrep -r SECRET .'
expect_block 'zgrep -r SECRET .'
expect_block 'rgrep SECRET .'

echo "block-env-read — task #686 s5 compound with substitutions"
expect_block '{ ls .env; x=$(true | true); } | xargs cat'
expect_block '`date`; (ls .env) | xargs cat'

echo "block-env-read — task #686 s6 recursive grep with path operands"
HOOK_CWD="$CLEANTREE"
expect_allow 'grep -rn TODO src/'
expect_allow 'grep -rn --exclude-dir=node_modules X src/'
expect_block 'grep -rn TODO'
expect_block 'grep -rn TODO .'

echo "block-env-read — task #686 cycle 2 substitution / xargs / stdin-fed runtimes"
: > "$CLEANTREE/server.js"
expect_block 'grep -rn SECRET src/ $(printf .)'
expect_block 'grep -rn SECRET src/ `printf .`'
expect_block 'echo . | xargs grep -rn SECRET src/'
expect_block "echo 'console.log(process.env)' | node --env-file=.env"
expect_block $'node --env-file=.env <<EOF\nconsole.log(process.env)\nEOF'
expect_block 'node --env-file=.env < x.js'
expect_block 'node --env-file=.env -'
expect_block "bun --env-file=.env exec 'echo \$SECRET'"
expect_block 'bun --env-file=.env run x'
expect_block 'bun --env-file=.env x y'
expect_block 'bunx --env-file=.env y'
expect_allow 'node --env-file=.env server.js'
expect_allow 'grep -rn TODO src/'
HOOK_CWD="$DIRTYTREE"
expect_block 'grep -rn TODO src/'
expect_block 'grep -rn --exclude-dir=node_modules X src/'
expect_block 'grep -rn TODO'
HOOK_CWD=""

echo "block-env-read — task #686 cycle 4 quoted redirects / strict operands / env -C"
# env file at root and in sub/, clean src/.
RTFX="$TMP/rtfx"; mkdir -p "$RTFX/src" "$RTFX/sub/src"
: > "$RTFX/.env"; : > "$RTFX/sub/.env"; : > "$RTFX/src/a.ts"
HOOK_CWD="$RTFX"
# Quoted redirect characters are plain operands (here: '.' still follows).
expect_block "grep -rn SECRET src/ '>' ."
expect_block 'grep -rn SECRET src/ ">" .'
expect_block "grep -rn SECRET src/ '2>' ."
expect_block "grep -rn SECRET src/ '<' ."
# Quoted path operand fails closed.
expect_block "grep -rn SECRET 'src/'"
# env -C / --chdir change the directory: the allowance fails closed.
expect_block 'env -C sub grep -rn SECRET src/'
expect_block 'env -Csub grep -rn SECRET src/'
expect_block 'env --chdir=sub grep -rn SECRET src/'
expect_block 'env --chdir sub grep -rn SECRET src/'
# Unquoted redirects and plain operands stay allowed.
expect_allow 'grep -rn TODO src/'
expect_allow 'grep -rn "foo bar" src/'
expect_allow 'grep -rn --exclude-dir=node_modules X src/'
expect_allow 'grep -rn X src/ 2>/dev/null'
HOOK_CWD="$CDFX"
expect_block 'env -C sub cp .env.example .env'
expect_block 'env --chdir=sub cp .env.example .env'
expect_allow 'cp .env.example .env'
HOOK_CWD=""

echo "block-env-read — task #715 wrappers / shell -c / preload / --include"
HOOK_CWD="$CLEANTREE"
# Gap 1: wrappers and shell -c inner pass.
expect_block 'stdbuf -o0 grep -r X .'
expect_block 'stdbuf -o 0 grep -r X .'
expect_block 'ionice -c3 grep -r X .'
expect_block 'setsid grep -r X .'
expect_block 'bash -c "grep -r X ."'
expect_block "sh -c 'grep -r X .'"
expect_block 'bash -lc "grep -r X ."'
expect_block 'zsh -c "grep -R X ."'
expect_block 'flock /tmp/l -c "grep -r X ."'
expect_allow "stdbuf -o0 grep -r --exclude='.env*' X ."
expect_allow "bash -c \"grep -r --exclude='.env*' X .\""
expect_allow 'stdbuf -oL tail -f app.log'
expect_allow 'bash -c "echo hi"'
expect_allow "sh -c 'ls src'"
# Gap 2: preload / loader flags disqualify the --env-file allowance.
expect_block 'node --env-file=.env -r ./dump.js server.js'
expect_block 'node --env-file=.env --require ./dump.js server.js'
expect_block 'node --env-file=.env --import ./dump.mjs server.js'
expect_block 'node --env-file=.env --loader ./l.mjs server.js'
expect_block 'bun --env-file=.env --preload ./p.ts server.ts'
expect_block 'NODE_OPTIONS="--require ./dump.js" node --env-file=.env server.js'
expect_allow 'node --env-file=.env server.js'
expect_allow 'tsx --env-file=.env script.ts'
# Gap 3: --include cancels the env exclude.
expect_block "grep -r --exclude='.env*' --include='.env*' X ."
expect_block "grep -r --include='.env*' --exclude='.env*' X ."
expect_block "grep -r --exclude='.env*' --include='*' X ."
expect_block 'grep -r --exclude=.env* --include .envrc X .'
expect_allow "grep -r --exclude='.env*' --include='*.ts' X ."
expect_allow "grep -r --include='*.md' --exclude='*.env*' X ."
HOOK_CWD=""

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
