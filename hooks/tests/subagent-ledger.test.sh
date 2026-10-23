#!/usr/bin/env bash
#
# Regression test for #577 — scripts/atelier-subagent-ledger (per-worktree
# dispatch ledger) and hooks/subagent-ledger.sh (SubagentStop closer +
# PreToolUse/SubagentHandback guard for task-orchestrator).
#
# Hermetic: temp dirs, its own ATELIER_CONFIG_DIR, no network, no sleeps.
# Age is simulated by rewriting ledger timestamps, never by waiting.
#
# Run:  hooks/tests/subagent-ledger.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEDGER="$REPO_ROOT/scripts/atelier-subagent-ledger"
HOOK="$REPO_ROOT/hooks/subagent-ledger.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -r -f "$TMP"' EXIT
export ATELIER_CONFIG_DIR="$TMP/config"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
mkdir -p "$ATELIER_CONFIG_DIR"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   - $1"; }
bad() { fail=$((fail+1)); echo "  FAIL - $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in: $2)" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 (unexpected '$3' in: $2)" ;; *) ok "$1" ;; esac; }

new_wt() { local d="$TMP/wt-$1"; mkdir -p "$d"; (cd "$d" && pwd -P); }

# Rewrite every start ts in the worktree ledger to "$2 seconds ago".
age_entry() {
  local secs="$2" f="$1/.task-log/subagents.jsonl" now
  now="$(date -u +%s)"
  jq -c --argjson old "$((now - secs))" 'if .event=="start" then .ts=$old else . end' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

# Run the hook on a payload; sets OUT (stderr) and RC.
run_hook() {
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>&1 >/dev/null)"; RC=$?
}
hb_payload() { # agent_type message
  jq -cn --arg t "$1" --arg m "$2" \
    '{hook_event_name:"PreToolUse", tool_name:"SubagentHandback", agent_type:$t, tool_input:{message:$m}}'
}

echo "== helper: round trip and exit codes"
WT="$(new_wt a)"
"$LEDGER" live --worktree "$WT" >/dev/null 2>&1; eq "live with no ledger exits 0" "$?" "0"
"$LEDGER" start --worktree "$WT" --agent-id ag1 --type implementer --step 3 >/dev/null 2>&1; eq "start exits 0" "$?" "0"
out="$("$LEDGER" live --worktree "$WT" 2>&1)"; rc=$?
eq "live with an open entry exits 3" "$rc" "3"
eq "live line has id/type/step/fresh" "$(printf '%s' "$out" | awk -F'\t' '{print $1"|"$2"|"$3"|"$5}')" "ag1|implementer|3|fresh"
"$LEDGER" start --worktree "$WT" --agent-id ag1 --type implementer --step 3 >/dev/null 2>&1
eq "start is idempotent while open (one start event)" "$(jq -s '[.[]|select(.event=="start")]|length' "$WT/.task-log/subagents.jsonl")" "1"
eq "index entry points to the worktree" "$(cat "$ATELIER_CONFIG_DIR/state/subagent-ledger/ag1")" "$WT"
"$LEDGER" finish --agent-id ag1 --state "done" >/dev/null 2>&1; eq "finish via index exits 0" "$?" "0"
"$LEDGER" live --worktree "$WT" >/dev/null 2>&1; eq "live after finish exits 0" "$?" "0"
if [ ! -e "$ATELIER_CONFIG_DIR/state/subagent-ledger/ag1" ]; then ok "finish removes the index entry"; else bad "index entry survived finish"; fi
eq "finish event records state done" "$(jq -rs '[.[]|select(.event=="finish")][0].state' "$WT/.task-log/subagents.jsonl")" "done"

echo "== helper: error exits"
"$LEDGER" start --worktree "$TMP/nope" --agent-id x --type t >/dev/null 2>&1; eq "start with missing worktree exits 2" "$?" "2"
"$LEDGER" start --worktree "$WT" --type t >/dev/null 2>&1; eq "start without agent id exits 2" "$?" "2"
"$LEDGER" start --worktree "$WT" --agent-id 'a/b' --type t >/dev/null 2>&1; eq "start with invalid id chars exits 2" "$?" "2"
"$LEDGER" start --worktree "$WT" --agent-id x >/dev/null 2>&1; eq "start without type exits 2" "$?" "2"
"$LEDGER" live >/dev/null 2>&1; eq "live without worktree exits 2" "$?" "2"
"$LEDGER" bogus >/dev/null 2>&1; eq "unknown subcommand exits 2" "$?" "2"
"$LEDGER" live --nope x >/dev/null 2>&1; eq "unknown argument exits 2" "$?" "2"
"$LEDGER" finish --agent-id x --state weird >/dev/null 2>&1; eq "finish with invalid state exits 2" "$?" "2"

echo "== helper: finish idempotence"
"$LEDGER" finish --agent-id never-seen >/dev/null 2>&1; eq "finish on unknown id exits 0" "$?" "0"
"$LEDGER" finish --agent-id ag1 --worktree "$WT" >/dev/null 2>&1; eq "finish on already-closed id exits 0" "$?" "0"
eq "no second finish event appended" "$(jq -s '[.[]|select(.event=="finish")]|length' "$WT/.task-log/subagents.jsonl")" "1"

echo "== helper: fresh vs stale"
WT="$(new_wt ttl)"
"$LEDGER" start --worktree "$WT" --agent-id old1 --type implementer >/dev/null 2>&1
age_entry "$WT" 43201
out="$("$LEDGER" live --worktree "$WT" 2>&1)"; rc=$?
eq "entry older than default ttl exits 3 (still open)" "$rc" "3"
eq "entry older than default ttl is stale" "$(printf '%s' "$out" | cut -f5)" "stale"
age_entry "$WT" 43000
eq "entry younger than default ttl is fresh" "$("$LEDGER" live --worktree "$WT" | cut -f5)" "fresh"
printf '{"ownerTtlSeconds": 100}\n' > "$WT/.atelier.json"
age_entry "$WT" 500
eq "ownerTtlSeconds from .atelier.json applies (stale)" "$("$LEDGER" live --worktree "$WT" | cut -f5)" "stale"
age_entry "$WT" 50
eq "ownerTtlSeconds from .atelier.json applies (fresh)" "$("$LEDGER" live --worktree "$WT" | cut -f5)" "fresh"
printf '{"ownerTtlSeconds": "abc"}\n' > "$WT/.atelier.json"
age_entry "$WT" 500
eq "non-numeric ttl falls back to default" "$("$LEDGER" live --worktree "$WT" | cut -f5)" "fresh"

echo "== helper: index pruning"
WT="$(new_wt gone)"
"$LEDGER" start --worktree "$WT" --agent-id ghost --type t >/dev/null 2>&1
rm -r -f "$WT"
WT2="$(new_wt keep)"
"$LEDGER" start --worktree "$WT2" --agent-id keeper --type t >/dev/null 2>&1
"$LEDGER" finish --agent-id keeper >/dev/null 2>&1
if [ ! -e "$ATELIER_CONFIG_DIR/state/subagent-ledger/ghost" ]; then ok "index entry of a removed worktree is pruned"; else bad "ghost index entry survived"; fi
"$LEDGER" finish --agent-id ghost >/dev/null 2>&1; eq "finish on an id whose worktree is gone exits 0" "$?" "0"

echo "== hook: SubagentStop closes the entry"
WT="$(new_wt stop)"
"$LEDGER" start --worktree "$WT" --agent-id stp1 --type implementer >/dev/null 2>&1
printf '%s' '{"hook_event_name":"SubagentStop","agent_id":"stp1","agent_type":"implementer"}' | bash "$HOOK" >/dev/null 2>&1
eq "SubagentStop hook exits 0" "$?" "0"
"$LEDGER" live --worktree "$WT" >/dev/null 2>&1; eq "entry closed after SubagentStop" "$?" "0"
eq "closed with state done" "$(jq -rs '[.[]|select(.event=="finish")][0].state' "$WT/.task-log/subagents.jsonl")" "done"
printf '%s' '{"hook_event_name":"SubagentStop","agent_id":"unknown-zz"}' | bash "$HOOK" >/dev/null 2>&1; eq "SubagentStop for unknown id exits 0" "$?" "0"
printf '%s' '{"hook_event_name":"SubagentStop"}' | bash "$HOOK" >/dev/null 2>&1; eq "SubagentStop without agent_id exits 0" "$?" "0"

echo "== hook: handback guard"
WT="$(new_wt guard)"
"$LEDGER" start --worktree "$WT" --agent-id kid1 --type implementer --step 2 >/dev/null 2>&1
"$LEDGER" start --worktree "$WT" --agent-id kid2 --type tester --step 4 >/dev/null 2>&1
MSG="Task: x
Worktree: $WT
Status: done"
run_hook "$(hb_payload task-orchestrator "$MSG")"
eq "undisclosed fresh children are denied (exit 2)" "$RC" "2"
has "reason names the first id" "$OUT" "kid1"
has "reason names the second id" "$OUT" "kid2"
has "reason lists way 1 (wait)" "$OUT" "1. End your turn WITHOUT handing back"
has "reason lists way 2 (TaskStop)" "$OUT" "2. If the child's work is moot, TaskStop it"
has "reason lists way 3 (disclose)" "$OUT" "3. Disclose it"
run_hook "$(hb_payload atelier:task-orchestrator "$MSG")"
eq "plugin-prefixed agent type is also guarded" "$RC" "2"
run_hook "$(hb_payload task-orchestrator "$MSG
Live sub-agents: kid1 (implementer, 2) - still running: build")"
eq "partial disclosure (one id missing) is still denied" "$RC" "2"
has "reason still names the undisclosed id" "$OUT" "Reason:   the dispatch ledger shows sub-agent(s) still running that this report does not name: kid2"
run_hook "$(hb_payload task-orchestrator "$MSG
Live sub-agents: kid1 (implementer, 2) - still running: a
kid2 (tester, 4) - still running: b")"
eq "all ids named under Live sub-agents: allows" "$RC" "0"
run_hook "$(hb_payload task-orchestrator "$MSG
Live sub-agents: none")"
eq "'Live sub-agents: none' does not satisfy the guard" "$RC" "2"

echo "== hook: guard allows"
"$LEDGER" finish --agent-id kid1 --state "done" >/dev/null 2>&1
"$LEDGER" finish --agent-id kid2 --state stopped >/dev/null 2>&1
run_hook "$(hb_payload task-orchestrator "$MSG")"
eq "closed children allow" "$RC" "0"

WT3="$(new_wt stale)"
"$LEDGER" start --worktree "$WT3" --agent-id stale1 --type t >/dev/null 2>&1
age_entry "$WT3" 90000
run_hook "$(hb_payload task-orchestrator "Worktree: $WT3")"
eq "only stale live entries allow" "$RC" "0"

echo "== hook: fail-open"
"$LEDGER" start --worktree "$WT" --agent-id kid3 --type t >/dev/null 2>&1
run_hook "$(hb_payload task-orchestrator "$MSG")"; eq "sanity: kid3 undisclosed is denied" "$RC" "2"
run_hook "$(hb_payload implementer "$MSG")"; eq "other agent type allows" "$RC" "0"
run_hook "$(hb_payload not-task-orchestrator "$MSG")"; eq "suffix-lookalike agent type allows" "$RC" "0"
run_hook "$(hb_payload task-orchestrator "no worktree line here")"; eq "no Worktree: line allows" "$RC" "0"
run_hook "$(hb_payload task-orchestrator "Worktree: $TMP/does-not-exist")"; eq "nonexistent Worktree: path allows" "$RC" "0"
run_hook "$(jq -cn --arg m "$MSG" '{hook_event_name:"PreToolUse", tool_name:"Bash", agent_type:"task-orchestrator", tool_input:{message:$m}}')"
eq "other tool allows" "$RC" "0"
run_hook '{"hook_event_name":"SomethingElse"}'; eq "unrelated event allows" "$RC" "0"
run_hook 'not json'; eq "garbage stdin allows" "$RC" "0"
EMPTY_BIN="$TMP/emptybin"; mkdir -p "$EMPTY_BIN"
PATH="$EMPTY_BIN" "$(command -v bash)" "$HOOK" <<<"$(hb_payload task-orchestrator "$MSG")" >/dev/null 2>&1
eq "jq missing allows" "$?" "0"

echo "== hook: decisions logged"
LOG="$WT/.task-log/hook-decisions.jsonl"
rm -f "$LOG"
run_hook "$(hb_payload task-orchestrator "$MSG")"
eq "block decision logged" "$(tail -n1 "$LOG" | jq -r '.hook+"|"+.action+"|"+.pattern')" "subagent-ledger|block|undisclosed-live-child"
has "block message names the id" "$(tail -n1 "$LOG" | jq -r .message)" "kid3"
run_hook "$(hb_payload task-orchestrator "$MSG
Live sub-agents: kid3")"
eq "allow (disclosed) decision logged" "$(tail -n1 "$LOG" | jq -r '.action+"|"+.message')" "allow|live sub-agents disclosed"
"$LEDGER" finish --agent-id kid3 >/dev/null 2>&1
run_hook "$(hb_payload task-orchestrator "$MSG")"
eq "allow (none live) decision logged" "$(tail -n1 "$LOG" | jq -r '.action+"|"+.message')" "allow|no live sub-agents (ledger rc=0)"

echo "== helper: --ignore-live path (superseded-by-resume)"
WT="$(new_wt resume)"
"$LEDGER" start --worktree "$WT" --agent-id r1 --type pr-author >/dev/null 2>&1
"$LEDGER" start --worktree "$WT" --agent-id r2 --type reviewer >/dev/null 2>&1
for id in $("$LEDGER" live --worktree "$WT" | cut -f1); do
  "$LEDGER" finish --agent-id "$id" --state superseded-by-resume --reason "operator passed --ignore-live to /atelier:resume-task 9" >/dev/null 2>&1
done
"$LEDGER" live --worktree "$WT" >/dev/null 2>&1; eq "live reports none after supersede" "$?" "0"
eq "both closed as superseded-by-resume" "$(jq -rs '[.[]|select(.event=="finish" and .state=="superseded-by-resume")]|length' "$WT/.task-log/subagents.jsonl")" "2"
has "reason is kept in the ledger" "$(jq -rs '[.[]|select(.event=="finish")][0].reason' "$WT/.task-log/subagents.jsonl")" "--ignore-live"

echo
echo "subagent-ledger: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
