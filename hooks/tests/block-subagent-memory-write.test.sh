#!/usr/bin/env bash
#
# Hermetic regression test for hooks/block-subagent-memory-write.sh (#666).
# Verifies that chain subagents (non-empty .agent_id / .agent_type in the payload;
# CLAUDE_CODE_CHILD_SESSION=1 is NOT a signal, #710)
# cannot write (add, supersede, close, import) to the real project memory store,
# while top-level sessions, read-only subcommands, isolated ATELIER_CONFIG_DIR
# targets, and ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE=1 overrides are allowed.
#
# Run:  hooks/tests/block-subagent-memory-write.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-subagent-memory-write.sh"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

T_HOME="$TMP/home"
ACD="$TMP/real-acd"
ISO="$TMP/iso-acd"
mkdir -p "$T_HOME/.claude-work" "$ACD" "$ISO" "$TMP/logs" "$TMP/work"
ln -s "$ACD" "$TMP/link-real-acd"
ln -s "$T_HOME/.claude-work" "$TMP/link-def-acd"
ln -s "$ISO" "$TMP/link-iso-acd"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# run_hook <agent_id> <agent_type> <command> [env assignments...]
run_hook() {
  local aid="$1" atype="$2" cmd="$3"; shift 3
  local payload
  payload="$(jq -cn --arg c "$cmd" --arg id "$aid" --arg t "$atype" '
    {tool_name:"Bash", tool_input:{command:$c}}
    + (if $id != "" then {agent_id:$id} else {} end)
    + (if $t != "" then {agent_type:$t} else {} end)
  ')"
  (
    cd "$TMP/work" || exit 99
    export HOME="$T_HOME" ATELIER_CONFIG_DIR="$ACD"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs"
    unset ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE CLAUDE_CODE_CHILD_SESSION
    env "$@" bash "$HOOK" <<<"$payload" >/dev/null 2>"$TMP/stderr"
  )
  echo "$?"
}

assert_block() {
  local name="$1" aid="$2" atype="$3" cmd="$4"; shift 4
  local rc; rc="$(run_hook "$aid" "$atype" "$cmd" "$@")"
  if [ "$rc" = "2" ] && grep -q 'atelier:block-subagent-memory-write BLOCKED' "$TMP/stderr"; then
    pass "block: $name"
  else
    fail "block: $name (exit=$rc, stderr=$(tr '\n' ' ' <"$TMP/stderr"))"
  fi
}

assert_allow() {
  local name="$1" aid="$2" atype="$3" cmd="$4"; shift 4
  local rc; rc="$(run_hook "$aid" "$atype" "$cmd" "$@")"
  if [ "$rc" = "0" ]; then
    pass "allow: $name"
  else
    fail "allow: $name (exit=$rc, stderr=$(tr '\n' ' ' <"$TMP/stderr"))"
  fi
}

# --- 1. hooks.json registration --------------------------------------------
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | endswith("/hooks/block-subagent-memory-write.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  pass "hooks/hooks.json registers block-subagent-memory-write.sh on PreToolUse (Bash)"
else
  fail "hooks/hooks.json missing block-subagent-memory-write.sh under PreToolUse (Bash)"
fi

# --- 2. Top-level session allowed on all write subcommands -----------------
assert_allow "top-level add"            "" "" 'atelier-memory add fact --project . --source agent-inferred --title x'
assert_allow "top-level supersede"      "" "" 'atelier-memory supersede F-1 --source agent-inferred --title y'
assert_allow "top-level close"          "" "" 'atelier-memory close Q-1 --by D-1'
assert_allow "top-level import"         "" "" 'atelier-memory import --project .'
assert_allow "top-level ingest"         "" "" 'atelier-memory ingest'
assert_allow "top-level verify --apply" "" "" 'atelier-memory verify --project . --apply'

# --- 3. Subagent identification signals (.agent_id, .agent_type, env) ------
assert_block "agent_id set: add" \
  "sub-1" "" 'atelier-memory add fact --project . --source agent-inferred --title x'
assert_block "agent_type set: add" \
  "" "atelier:implementer" 'atelier-memory add fact --project . --source agent-inferred --title x'

# #710: CLAUDE_CODE_CHILD_SESSION=1 is set in top-level sessions too; a payload
# without agent_id/agent_type must stay allowed for every write.
CCS=CLAUDE_CODE_CHILD_SESSION=1
assert_allow "top-level + CLAUDE_CODE_CHILD_SESSION=1: add" "" "" \
  'atelier-memory add fact --project . --source agent-inferred --title x' "$CCS"
assert_allow "top-level + CLAUDE_CODE_CHILD_SESSION=1: supersede" "" "" \
  'atelier-memory supersede F-1 --source agent-inferred --title y' "$CCS"
assert_allow "top-level + CLAUDE_CODE_CHILD_SESSION=1: close" "" "" \
  'atelier-memory close Q-1 --by D-1' "$CCS"
assert_allow "top-level + CLAUDE_CODE_CHILD_SESSION=1: import" "" "" \
  'atelier-memory import --project .' "$CCS"
assert_allow "top-level + CLAUDE_CODE_CHILD_SESSION=1: ingest" "" "" \
  'atelier-memory ingest' "$CCS"
assert_allow "top-level + CLAUDE_CODE_CHILD_SESSION=1: verify --apply" "" "" \
  'atelier-memory verify --project . --apply' "$CCS"
assert_allow "top-level + CLAUDE_CODE_CHILD_SESSION=1: render (no vault override)" "" "" \
  'atelier-memory render' "$CCS"

# The subagent block still holds when the env var is present.
assert_block "agent_id + CLAUDE_CODE_CHILD_SESSION=1: add" \
  "sub-1" "" 'atelier-memory add fact --project . --source agent-inferred --title x' "$CCS"
assert_block "agent_type alone + CLAUDE_CODE_CHILD_SESSION=1: add" \
  "" "atelier:implementer" 'atelier-memory add fact --project . --source agent-inferred --title x' "$CCS"
assert_block "agent_id + CLAUDE_CODE_CHILD_SESSION=1: render --vault ~/Atelier" \
  "sub-1" "" 'atelier-memory render --vault ~/Atelier' "$CCS"

# Block message names the triggering signal and the top-level route.
run_hook "sub-1" "" 'atelier-memory add fact --project . --source agent-inferred --title x' >/dev/null
if grep -q 'agent_id=sub-1' "$TMP/stderr"; then
  pass "block message names the signal (agent_id=sub-1)"
else
  fail "block message missing 'agent_id=sub-1' (stderr=$(tr '\n' ' ' <"$TMP/stderr"))"
fi
if grep -q 'top-level session runs atelier-memory add' "$TMP/stderr"; then
  pass "block message gives the top-level route"
else
  fail "block message missing the top-level route (stderr=$(tr '\n' ' ' <"$TMP/stderr"))"
fi
run_hook "" "atelier:implementer" 'atelier-memory add fact --project . --source agent-inferred --title x' >/dev/null
if grep -q 'agent_type=atelier:implementer' "$TMP/stderr"; then
  pass "block message names the signal (agent_type=atelier:implementer)"
else
  fail "block message missing 'agent_type=atelier:implementer' (stderr=$(tr '\n' ' ' <"$TMP/stderr"))"
fi

# #710: --version is read-only for everyone.
assert_allow "top-level --version" "" "" 'atelier-memory --version'
assert_allow "subagent --version" "sub-1" "implementer" 'atelier-memory --version'
assert_allow "subagent --version 2>/dev/null" "sub-1" "implementer" 'atelier-memory --version 2>/dev/null'

# --- 4. Subagent blocked across all write subcommands & path variants ------
assert_block "subagent supersede" "sub-1" "implementer" \
  'atelier-memory supersede F-1 --source agent-inferred --title y'
assert_block "subagent close" "sub-1" "implementer" \
  'atelier-memory close Q-1 --by D-1'
assert_block "subagent import (no --dry-run)" "sub-1" "implementer" \
  'atelier-memory import --project .'
assert_block "subagent ingest" "sub-1" "implementer" \
  'atelier-memory ingest'
assert_block "subagent verify --apply" "sub-1" "implementer" \
  'atelier-memory verify --project . --apply'
assert_block "subagent via scripts/atelier-memory path" "sub-1" "implementer" \
  'scripts/atelier-memory add decision --project . --source agent-inferred --title d'
assert_block "subagent via \$MEM variable" "sub-1" "implementer" \
  'MEM=scripts/atelier-memory; "$MEM" add fact --project . --source agent-inferred --title x'

# --- 5. Subagent blocked when ATELIER_CONFIG_DIR is unset, empty, or real ---
assert_block "unset ATELIER_CONFIG_DIR before add" "sub-1" "tester" \
  'unset ATELIER_CONFIG_DIR; atelier-memory add fact --project . --source agent-inferred --title x'
assert_block "env -u ATELIER_CONFIG_DIR" "sub-1" "tester" \
  'env -u ATELIER_CONFIG_DIR atelier-memory add fact --project . --source agent-inferred --title x'
assert_block "env --unset=ATELIER_CONFIG_DIR" "sub-1" "tester" \
  'env --unset=ATELIER_CONFIG_DIR atelier-memory close Q-1 --by x'
assert_block "env -i without isolated ATELIER_CONFIG_DIR" "sub-1" "tester" \
  'env -i HOME="$HOME" atelier-memory add fact --project . --source agent-inferred --title x'
assert_block "ATELIER_CONFIG_DIR=\"\" inline" "sub-1" "tester" \
  'ATELIER_CONFIG_DIR="" atelier-memory add fact --project . --source agent-inferred --title x'
assert_block "export ATELIER_CONFIG_DIR=\"\"" "sub-1" "tester" \
  'export ATELIER_CONFIG_DIR=""; atelier-memory import'
assert_block "ATELIER_CONFIG_DIR=~/.claude-work" "sub-1" "tester" \
  'ATELIER_CONFIG_DIR=~/.claude-work atelier-memory add fact --project . --source agent-inferred --title x'
assert_block 'ATELIER_CONFIG_DIR=$HOME/.claude-work' "sub-1" "tester" \
  'ATELIER_CONFIG_DIR="$HOME/.claude-work" atelier-memory add fact --project . --source agent-inferred --title x'
assert_block 'ATELIER_CONFIG_DIR=$ATELIER_CONFIG_DIR' "sub-1" "tester" \
  'ATELIER_CONFIG_DIR="$ATELIER_CONFIG_DIR" atelier-memory add fact --project . --source agent-inferred --title x'
assert_block "ATELIER_CONFIG_DIR=real dir literal" "sub-1" "tester" \
  "ATELIER_CONFIG_DIR=$ACD atelier-memory add fact --project . --source agent-inferred --title x"
assert_block "symlink to real ATELIER_CONFIG_DIR" "sub-1" "tester" \
  "ATELIER_CONFIG_DIR=$TMP/link-real-acd atelier-memory add fact --project . --source agent-inferred --title x"
assert_block "symlink to ~/.claude-work" "sub-1" "tester" \
  "ATELIER_CONFIG_DIR=$TMP/link-def-acd atelier-memory add fact --project . --source agent-inferred --title x"
assert_block "unexported shell assignment" "sub-1" "tester" \
  "ATELIER_CONFIG_DIR=$ISO; atelier-memory add fact --project . --source agent-inferred --title x" \
  -u ATELIER_CONFIG_DIR
assert_block "bash -c subshell write" "sub-1" "tester" \
  'bash -c "atelier-memory add fact --project . --source agent-inferred --title x"'
assert_block "command substitution \$(...)" "sub-1" "tester" \
  'out="$(atelier-memory add fact --project . --source agent-inferred --title x)"'

# --- 6. Subagent allowed on read-only subcommands --------------------------
assert_allow "subagent list"   "sub-1" "implementer" 'atelier-memory list --project .'
assert_allow "subagent show"   "sub-1" "implementer" 'atelier-memory show D-1'
assert_allow "subagent search" "sub-1" "implementer" 'atelier-memory search foo --project .'
assert_allow "subagent brief"  "sub-1" "implementer" 'atelier-memory brief --project .'
assert_allow "subagent verify" "sub-1" "implementer" 'atelier-memory verify --project .'
assert_allow "subagent path"   "sub-1" "implementer" 'atelier-memory path'
assert_allow "subagent render" "sub-1" "implementer" 'atelier-memory render'
assert_allow "subagent render --full" "sub-1" "implementer" 'atelier-memory render --full'
assert_allow "subagent --help" "sub-1" "implementer" 'atelier-memory --help'
assert_allow "subagent import --dry-run" "sub-1" "implementer" 'atelier-memory import --dry-run --project .'

# --- 7. Subagent allowed with isolated ATELIER_CONFIG_DIR or override ------
assert_allow "inline isolated ATELIER_CONFIG_DIR" "sub-1" "tester" \
  "ATELIER_CONFIG_DIR=$ISO atelier-memory add fact --project . --source agent-inferred --title x"
assert_allow "symlink to isolated dir" "sub-1" "tester" \
  "ATELIER_CONFIG_DIR=$TMP/link-iso-acd atelier-memory add fact --project . --source agent-inferred --title x"
assert_allow "inline isolated ATELIER_CONFIG_DIR ingest" "sub-1" "tester" \
  "ATELIER_CONFIG_DIR=$ISO atelier-memory ingest"
assert_allow "inline isolated ATELIER_CONFIG_DIR verify --apply" "sub-1" "tester" \
  "ATELIER_CONFIG_DIR=$ISO atelier-memory verify --project . --apply"
assert_allow 'ATELIER_CONFIG_DIR=$(mktemp -d)' "sub-1" "tester" \
  'ATELIER_CONFIG_DIR="$(mktemp -d)" atelier-memory add fact --project . --source agent-inferred --title x'
assert_allow "in-command TMP=\$(mktemp -d) then ATELIER_CONFIG_DIR=\$TMP/cfg" "sub-1" "tester" \
  'TMP="$(mktemp -d)"; ATELIER_CONFIG_DIR="$TMP/cfg" atelier-memory add fact --project . --source agent-inferred --title x'
assert_allow "in-command TMP=\$(mktemp -d) then export ATELIER_CONFIG_DIR=\$TMP/cfg" "sub-1" "tester" \
  'TMP="$(mktemp -d)"; export ATELIER_CONFIG_DIR="$TMP/cfg"; atelier-memory add fact --project . --source agent-inferred --title x'
assert_allow "inherited isolated ATELIER_CONFIG_DIR in bash -c" "sub-1" "tester" \
  "ATELIER_CONFIG_DIR=$ISO bash -c 'atelier-memory add fact --project . --source agent-inferred --title x'"
assert_allow "ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE=1 env" "sub-1" "implementer" \
  'atelier-memory add fact --project . --source agent-inferred --title x' ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE=1
assert_allow "ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE=1 inline" "sub-1" "implementer" \
  'ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE=1 atelier-memory close Q-1 --by D-1'

# --- 8. #684: relative ATELIER_CONFIG_DIR, function/xargs prefixes, unknown subs ----
mkdir -p "$T_HOME/.claude-work/sub"
assert_block "relative ATELIER_CONFIG_DIR=. (cwd is the real config dir)" "sub-1" "implementer" \
  'cd ~/.claude-work && ATELIER_CONFIG_DIR=. atelier-memory add fact --project . --source agent-inferred --title x'
assert_block "relative ATELIER_CONFIG_DIR=sub" "sub-1" "implementer" \
  'ATELIER_CONFIG_DIR=sub atelier-memory add fact --project . --source agent-inferred --title x'
assert_block "function keyword wrapper" "sub-1" "implementer" \
  'function f { atelier-memory add x; }; f'
assert_block "function keyword with parens" "sub-1" "implementer" \
  'function f() { atelier-memory add x; }; f'
assert_block "NAME() wrapper" "sub-1" "implementer" \
  'f() { atelier-memory add x; }; f'
assert_block "xargs -I{} placeholder subcommand" "sub-1" "implementer" \
  'printf add | xargs -I{} atelier-memory {} x'
assert_block "xargs -I {} separated placeholder subcommand" "sub-1" "implementer" \
  'printf add | xargs -I {} atelier-memory {} x'
assert_block "xargs with no subcommand supplied" "sub-1" "implementer" \
  'printf add | xargs atelier-memory'
assert_block "xargs -n 1 add" "sub-1" "implementer" \
  'printf x | xargs -n 1 atelier-memory add'
assert_allow "function wrapper with isolated ATELIER_CONFIG_DIR" "sub-1" "implementer" \
  "function f { ATELIER_CONFIG_DIR=$ISO atelier-memory add x; }; f"
assert_allow "xargs -I{} with isolated ATELIER_CONFIG_DIR" "sub-1" "implementer" \
  "printf add | ATELIER_CONFIG_DIR=$ISO xargs -I{} atelier-memory {} x"
assert_allow "xargs read-only subcommand" "sub-1" "implementer" \
  'printf x | xargs -n 1 atelier-memory show'
assert_block "unknown future subcommand goes through the write check" "sub-1" "implementer" \
  'atelier-memory frobnicate --project .'
assert_allow "unknown subcommand with isolated ATELIER_CONFIG_DIR" "sub-1" "implementer" \
  "ATELIER_CONFIG_DIR=$ISO atelier-memory frobnicate --project ."

# --- 9. #684: render into a non-isolated vault ------------------------------
assert_block "render --vault ~/Atelier with isolated config dir" "sub-1" "implementer" \
  "ATELIER_CONFIG_DIR=$ISO atelier-memory render --vault ~/Atelier"
assert_block "render --vault=\$HOME/Atelier" "sub-1" "implementer" \
  'atelier-memory render --vault=$HOME/Atelier'
assert_block "render --vault \$HOME" "sub-1" "implementer" \
  'atelier-memory render --vault "$HOME"'
assert_block "render --vault /" "sub-1" "implementer" \
  'atelier-memory render --vault /'
assert_block "render --vault inside the real config dir" "sub-1" "implementer" \
  "atelier-memory render --vault $ACD/vault"
assert_block "inline ATELIER_MEMORY_VAULT=~/Atelier + render" "sub-1" "implementer" \
  'ATELIER_MEMORY_VAULT=~/Atelier atelier-memory render --full'
assert_block "exported ATELIER_MEMORY_VAULT + render" "sub-1" "implementer" \
  'export ATELIER_MEMORY_VAULT=$HOME/Atelier; atelier-memory render'
assert_block "inherited ATELIER_MEMORY_VAULT=~/Atelier + render" "sub-1" "implementer" \
  'atelier-memory render' ATELIER_MEMORY_VAULT="$T_HOME/Atelier"
assert_block "ATELIER_MEMORY_VAULT=~/Atelier + add in isolated config dir" "sub-1" "implementer" \
  "ATELIER_CONFIG_DIR=$ISO ATELIER_MEMORY_VAULT=~/Atelier atelier-memory add fact --project . --source agent-inferred --title x"
assert_allow "render --vault isolated path" "sub-1" "implementer" \
  "atelier-memory render --vault $TMP/iso-vault"
assert_allow "ATELIER_MEMORY_VAULT isolated + render" "sub-1" "implementer" \
  'atelier-memory render' ATELIER_MEMORY_VAULT="$TMP/iso-vault"
assert_allow "ATELIER_MEMORY_VAULT=off + render" "sub-1" "implementer" \
  'atelier-memory render' ATELIER_MEMORY_VAULT=off
assert_allow "isolated config dir + isolated vault + add" "sub-1" "implementer" \
  "ATELIER_CONFIG_DIR=$ISO ATELIER_MEMORY_VAULT=$TMP/iso-vault atelier-memory add fact --project . --source agent-inferred --title x"
assert_allow "ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE=1 bypasses the vault check" "sub-1" "implementer" \
  'ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE=1 atelier-memory render --vault ~/Atelier'

# --- 10. #780: --help/-h/--version as an option VALUE is not a read-only flag ----
VALUE_OPTS="--project --source --title --body --quote --ref --supersedes --by --type --vault"
for opt in $VALUE_OPTS; do
  for flag in --help -h --version; do
    assert_block "add fact $opt $flag (value, not a read-only flag)" "sub-1" "implementer" \
      "atelier-memory add fact $opt $flag"
  done
done
assert_block "supersede --title --help" "sub-1" "implementer" 'atelier-memory supersede F-1 --title --help'
assert_block "close --by --version" "sub-1" "implementer" 'atelier-memory close Q-1 --by --version'
assert_block "import --title --help" "sub-1" "implementer" 'atelier-memory import --title --help'
assert_block "import --title --dry-run (value, not the dry-run flag)" "sub-1" "implementer" \
  'atelier-memory import --title --dry-run'
assert_block "ingest --source -h" "sub-1" "implementer" 'atelier-memory ingest --source -h'
assert_block "verify --apply with --title --help value" "sub-1" "implementer" \
  'atelier-memory verify --apply --title --help'
assert_block "render --title --help into the real vault" "sub-1" "implementer" \
  'atelier-memory render --title --help --vault ~/Atelier'
assert_block "render --title --vault \$TMP/iso keeps --vault as a value, inherited real vault" "sub-1" "implementer" \
  "atelier-memory render --title --vault $TMP/iso" ATELIER_MEMORY_VAULT="$T_HOME/Atelier"
assert_allow "verify --title --apply is a read-only verify (--apply is the value)" "sub-1" "implementer" \
  'atelier-memory verify --title --apply'

# Genuine read-only help/version still allowed, for subagents and the top-level session
for who in "sub-1 implementer" ""; do
  # shellcheck disable=SC2086
  set -- $who
  aid="${1:-}"; atype="${2:-}"; label="${aid:-top-level}"
  for f in --help -h --version; do
    assert_allow "$label atelier-memory $f" "$aid" "$atype" "atelier-memory $f"
  done
  for r in list show search brief; do
    assert_allow "$label atelier-memory $r --help" "$aid" "$atype" "atelier-memory $r --help"
  done
done

# Drift guard: every parse_opts value option of scripts/atelier-memory is in the hook's MEM_VALUE_OPTS
parse_names="$TMP/parse-value-opts.txt"
hook_line="$TMP/hook-mem-value-opts.txt"
awk '/^parse_opts\(\)/{f=1;next} f&&/^}/{f=0} f&&/needs a value/{ if (match($0,/--[a-z-]+\)/)) print substr($0,RSTART,RLENGTH-1) }' \
  "$REPO_ROOT/scripts/atelier-memory" >"$parse_names"
grep '^MEM_VALUE_OPTS=' "$HOOK" >"$hook_line"
# shellcheck disable=SC2086
if [ "$(wc -l <"$parse_names" | tr -d ' ')" = "$(printf '%s\n' $VALUE_OPTS | wc -l | tr -d ' ')" ]; then
  pass "parse_opts value-option count matches the test list ($(wc -l <"$parse_names" | tr -d ' '))"
else
  fail "parse_opts value options drifted from the test list: $(tr '\n' ' ' <"$parse_names")"
fi
hook_opts_val="$(cat "$hook_line")"
while IFS= read -r o; do
  case "$hook_opts_val" in
    *" $o "*) pass "MEM_VALUE_OPTS lists $o" ;;
    *) fail "MEM_VALUE_OPTS in the hook is missing parse_opts value option $o" ;;
  esac
done <"$parse_names"

# --- 11. #782: arguments the hook cannot see (xargs / parallel / find -exec / expansions)
block_and_top() {
  assert_block "#782 $1" "sub-1" "implementer" "$2"
  assert_allow "#782 top-level: $1" "" "" "$2"
}
block_and_top "xargs verify" 'printf -- '"'--apply\\n'"' | xargs atelier-memory verify'
block_and_top "xargs -I{} verify {}" 'printf -- '"'--apply\\n'"' | xargs -I{} atelier-memory verify {}'
block_and_top "xargs --max-args 1 add" 'xargs --max-args 1 atelier-memory add'
block_and_top "xargs -J % verify %" 'xargs -J % atelier-memory verify %'
block_and_top "xargs unknown subcommand" 'printf x | xargs atelier-memory frobnicate'
block_and_top "xargs sh -c wrapper" "xargs sh -c 'atelier-memory verify \"\$@\"' _"
block_and_top "parallel verify ::: --apply" 'parallel atelier-memory verify ::: --apply'
block_and_top "parallel -j 2 verify ::: --apply" 'parallel -j 2 atelier-memory verify ::: --apply'
block_and_top "parallel add x" 'parallel atelier-memory add x'
block_and_top "find -exec verify" 'find . -name x -exec atelier-memory verify {} \;'
block_and_top "find -exec add +" 'find . -exec atelier-memory add x {} +'
block_and_top "verify with command substitution" 'atelier-memory verify $(printf -- --apply)'
block_and_top "verify with unset variable" 'atelier-memory verify "$UNSET_VAR"'
block_and_top "verify with variable holding --apply" 'X=--apply; atelier-memory verify $X'
block_and_top "xargs render, no visible vault" 'printf x | xargs atelier-memory render'
block_and_top "xargs render with visible isolated vault" "printf x | xargs atelier-memory render --vault \"$TMP/iso-vault\""

assert_allow "#782 xargs verify with isolated ATELIER_CONFIG_DIR" "sub-1" "implementer" \
  "printf -- '--apply\\n' | ATELIER_CONFIG_DIR=$ISO xargs atelier-memory verify"
assert_allow "#782 parallel verify with isolated mktemp ATELIER_CONFIG_DIR" "sub-1" "implementer" \
  'ATELIER_CONFIG_DIR="$(mktemp -d)" parallel atelier-memory verify ::: --apply'
assert_allow "#782 find -exec add with isolated ATELIER_CONFIG_DIR" "sub-1" "implementer" \
  "ATELIER_CONFIG_DIR=$ISO find . -exec atelier-memory add {} \\;"
assert_allow "#782 xargs render with isolated config dir and isolated vault" "sub-1" "implementer" \
  "printf x | ATELIER_CONFIG_DIR=$ISO xargs atelier-memory render --vault $TMP/iso-vault"
assert_allow "#782 ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE=1 with xargs verify" "sub-1" "implementer" \
  "printf -- '--apply\\n' | ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE=1 xargs atelier-memory verify"

assert_allow "#782 xargs -n 1 show (read-only)" "sub-1" "implementer" \
  'printf x | xargs -n 1 atelier-memory show'
assert_allow "#782 parallel show ::: Q-1 (read-only)" "sub-1" "implementer" \
  'parallel atelier-memory show ::: Q-1'
assert_allow "#782 xargs import --dry-run" "sub-1" "implementer" \
  'printf x | xargs atelier-memory import --dry-run'
assert_allow "#782 show with variable id (read-only)" "sub-1" "implementer" \
  'atelier-memory show "$ID"'
assert_allow "#782 verify --project with variable (no --apply)" "sub-1" "implementer" \
  'atelier-memory verify --project "$P"'
assert_allow "#782 add with command-substitution body and isolated config dir" "sub-1" "implementer" \
  "ATELIER_CONFIG_DIR=$ISO atelier-memory add fact --project . --source agent-inferred --title x --body \"\$(cat f)\""
assert_allow "#782 fully visible render with visible isolated vault" "sub-1" "implementer" \
  "atelier-memory render --vault $TMP/iso-vault"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "block-subagent-memory-write: all checks passed"
  exit 0
fi
echo "block-subagent-memory-write: $fails check(s) failed"
exit 1
