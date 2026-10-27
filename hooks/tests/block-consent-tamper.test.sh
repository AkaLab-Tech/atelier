#!/usr/bin/env bash
#
# Regression test for #638/#639 — hooks/block-consent-tamper.sh must block any
# Bash/Edit/Write/MultiEdit/NotebookEdit/Read call whose input references the
# consent state (literal `state/consent` or the resolved
# $ATELIER_CONFIG_DIR/state/consent), allow unrelated inputs and other tools,
# and log every block to hook-decisions.jsonl.
#
# Hermetic: temp ATELIER_CONFIG_DIR / CLAUDE_PROJECT_DIR. Requires jq.
#
# Run:  hooks/tests/block-consent-tamper.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-consent-tamper.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export ATELIER_CONFIG_DIR="$TMP/custom-cfg" CLAUDE_PROJECT_DIR="$TMP/wt"
mkdir -p "$ATELIER_CONFIG_DIR" "$CLAUDE_PROJECT_DIR"
DLOG="$CLAUDE_PROJECT_DIR/.task-log/hook-decisions.jsonl"
RESOLVED="$ATELIER_CONFIG_DIR/state/consent"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

run_hook() { # tool input_json -> rc
  jq -cn --arg t "$1" --argjson i "$2" '{tool_name:$t, tool_input:$i}' \
    | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$HOOK" >/dev/null 2>"$TMP/stderr"
  echo "$?"
}
nlines() { if [ -f "$DLOG" ]; then wc -l < "$DLOG"; else echo 0; fi; }
blocks() { # name tool input_json
  local before after rc
  before="$(nlines)"
  rc="$(run_hook "$2" "$3")"
  after="$(nlines)"
  if [ "$rc" = 2 ] && grep -q 'atelier:block-consent-tamper BLOCKED' "$TMP/stderr" && [ "$after" -gt "$before" ] \
     && tail -1 "$DLOG" | jq -e --arg t "$2" '.hook=="block-consent-tamper" and .action=="block" and .tool==$t' >/dev/null; then
    pass "block+log: $1"
  else
    fail "block+log: $1 (exit=$rc, log lines $before->$after)"
  fi
}
allows() {
  local rc; rc="$(run_hook "$2" "$3")"
  if [ "$rc" = 0 ]; then pass "allow: $1"; else fail "allow: $1 (exit=$rc)"; fi
}

echo "== blocked: literal state/consent =="
blocks "Bash cat literal" Bash '{"command":"cat ~/.claude-work/state/consent/pending/x.json"}'
blocks "Bash ls literal" Bash '{"command":"ls state/consent"}'
blocks "Bash uppercase" Bash '{"command":"ls STATE/Consent"}'
blocks "Edit literal" Edit '{"file_path":"/x/state/consent/ledger.jsonl","old_string":"a","new_string":"b"}'
blocks "Write literal" Write '{"file_path":"/x/state/consent/grants/f.json","content":"{}"}'
blocks "MultiEdit literal" MultiEdit '{"file_path":"/x/state/consent/ledger.jsonl","edits":[{"old_string":"a","new_string":"b"}]}'
blocks "NotebookEdit literal" NotebookEdit '{"notebook_path":"/x/state/consent/n.ipynb","new_source":"x"}'
blocks "Read literal" Read '{"file_path":"/x/state/consent/ledger.jsonl"}'
blocks "nested string (edits array)" MultiEdit '{"file_path":"/ok.txt","edits":[{"old_string":"a","new_string":"cp x state/consent/grants/y"}]}'

echo "== blocked: resolved absolute path =="
blocks "Bash resolved" Bash "$(jq -cn --arg c "cat $RESOLVED/ledger.jsonl" '{command:$c}')"
blocks "Write resolved" Write "$(jq -cn --arg p "$RESOLVED/grants/f.json" '{file_path:$p,content:"{}"}')"
blocks "Read resolved" Read "$(jq -cn --arg p "$RESOLVED/ledger.jsonl" '{file_path:$p}')"
blocks "Edit resolved" Edit "$(jq -cn --arg p "$RESOLVED/ledger.jsonl" '{file_path:$p,old_string:"a",new_string:"b"}')"

echo "== allowed =="
allows "Bash unrelated" Bash '{"command":"ls -la && git status"}'
allows "Bash mentions consent without state path" Bash '{"command":"echo consent state"}'
allows "Edit unrelated" Edit '{"file_path":"/x/src/a.ts","old_string":"a","new_string":"b"}'
allows "Write unrelated" Write '{"file_path":"/x/notes.md","content":"hello"}'
allows "Read unrelated" Read '{"file_path":"/x/README.md"}'
allows "empty tool_input" Bash '{}'
allows "non-covered tool referencing the path (Grep)" Grep '{"pattern":"state/consent"}'
allows "non-covered tool (WebFetch)" WebFetch '{"url":"https://example.com/state/consent"}'

echo
if [ "$fails" -eq 0 ]; then echo "block-consent-tamper: all assertions passed"; exit 0; fi
echo "block-consent-tamper: $fails assertion(s) FAILED"; exit 1
