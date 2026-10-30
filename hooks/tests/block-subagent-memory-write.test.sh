#!/usr/bin/env bash
#
# Hermetic regression test for hooks/block-subagent-memory-write.sh (#666).
# Verifies that chain subagents (.agent_id / .agent_type / CLAUDE_CODE_CHILD_SESSION=1)
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
assert_block "CLAUDE_CODE_CHILD_SESSION=1: add" \
  "" "" 'atelier-memory add fact --project . --source agent-inferred --title x' CLAUDE_CODE_CHILD_SESSION=1

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

echo ""
if [ "$fails" -eq 0 ]; then
  echo "block-subagent-memory-write: all checks passed"
  exit 0
fi
echo "block-subagent-memory-write: $fails check(s) failed"
exit 1
