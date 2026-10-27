#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2035,SC2329
#
# Regression test for #638/#639 — operator-consent core: hooks/lib/consent.sh
# (eligibility, fingerprint, challenge, grant, consume, ledger) and the
# UserPromptSubmit hook hooks/operator-consent.sh that is the only place
# consent is minted.
#
# Hermetic: ATELIER_CONFIG_DIR and CLAUDE_PROJECT_DIR point at a temp dir;
# CLAUDE_CODE_BRIDGE_SESSION_ID is cleared so the payload session_id binds the
# grant. The real ~/.claude-work is never touched. Requires jq.
#
# Run:  hooks/tests/operator-consent.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/operator-consent.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
msg_has() { [[ "$(jq -r '.systemMessage' <<<"$1")" == *"$2"* ]]; }
matches() { [[ "$1" =~ $2 ]]; }
check() { # name, cmd...
  local n="$1"; shift
  if "$@"; then pass "$n"; else fail "$n"; fi
}

unset CLAUDE_CODE_BRIDGE_SESSION_ID
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

# fresh_env: new config dir + project dir, exported.
fresh_env() {
  local d; d="$(mktemp -d "$TMP/env.XXXXXX")"
  export ATELIER_CONFIG_DIR="$d/cfg" CLAUDE_PROJECT_DIR="$d/wt"
  mkdir -p "$ATELIER_CONFIG_DIR" "$CLAUDE_PROJECT_DIR"
  unset ATELIER_CONSENT_TTL_SECONDS
  LEDGER="$ATELIER_CONFIG_DIR/state/consent/ledger.jsonl"
  DLOG="$CLAUDE_PROJECT_DIR/.task-log/hook-decisions.jsonl"
}

# lib <bash code>: run code with the library + log-decision sourced.
lib() {
  bash -c 'source "$1/hooks/lib/log-decision.sh"; source "$1/hooks/lib/consent.sh"; shift; eval "$1"' _ "$REPO_ROOT" "$1"
}

HOOKNAME="block-gh-api-mutation"
SID="sess-A"
FP="$(lib 'consent_fingerprint block-gh-api-mutation "gh api -X POST /x"')"

# challenge <fp> <sid> -> sets CH_OUT, CH_RC, CODE
challenge() {
  CH_OUT="$(lib "consent_challenge $HOOKNAME '$1' 'gh api POST' '$2'" 2>"$TMP/ch.err")"; CH_RC=$?
  CODE="$(printf '%s' "$CH_OUT" | jq -r '.systemMessage // empty' | sed -n 's/.*atelier permitir \([A-Z2-7]\{8\}\).*/\1/p')"
}

prompt_hook() { # prompt sid -> stdout JSON
  jq -cn --arg p "$1" --arg s "$2" '{prompt:$p,session_id:$s,permission_mode:"default"}' | bash "$HOOK" 2>"$TMP/hook.err"
}
consume() { lib "consent_consume $HOOKNAME '$1' '$2'"; echo $?; }

echo "== eligibility =="
for h in block-operator-browser-github block-gh-api-mutation; do
  check "eligible: $h" lib "consent_eligible $h"
done
for h in block-env-commit block-env-read scan-git-add scan-edit-write block-protected-push \
         block-operator-gh-identity safe-commit safe-package-change block-cross-worktree-edit \
         block-consent-tamper ""; do
  if lib "consent_eligible '$h'"; then fail "ineligible: '$h'"; else pass "ineligible: '$h'"; fi
done

echo "== fingerprint =="
FP2="$(lib 'consent_fingerprint block-gh-api-mutation "  gh api -X POST /x  "')"
check "fingerprint is whitespace-trimmed" [ "$FP" = "$FP2" ]
FP3="$(lib 'consent_fingerprint block-gh-api-mutation "gh api -X POST /y"')"
check "different action -> different fingerprint" [ "$FP" != "$FP3" ]
FP4="$(lib 'consent_fingerprint block-operator-browser-github "gh api -X POST /x"')"
check "different hook -> different fingerprint" [ "$FP" != "$FP4" ]
check "fingerprint is 64 hex" matches "$FP" '^[0-9a-f]{64}$'

echo "== session token =="
tok="$(CLAUDE_CODE_BRIDGE_SESSION_ID=bridge lib 'consent_session_token "{\"session_id\":\"x\"}"')"
check "bridge id wins over payload" [ "$tok" = "bridge" ]
tok="$(lib 'consent_session_token "{\"session_id\":\"x\"}"')"
check "payload session_id used without bridge" [ "$tok" = "x" ]

echo "== challenge =="
fresh_env
challenge "$FP" "$SID"
check "challenge succeeds (rc 0)" [ "$CH_RC" = 0 ]
check "code is 8 base32 chars in systemMessage" matches "$CODE" '^[A-Z2-7]{8}$'
check "decision is deny" [ "$(printf '%s' "$CH_OUT" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
reason="$(printf '%s' "$CH_OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
check "code absent from permissionDecisionReason" bash -c '! grep -q "$1" <<<"$2"' _ "$CODE" "$reason"
check "code absent from stderr" bash -c '! grep -q "$1" "$2"' _ "$CODE" "$TMP/ch.err"
check "code absent from hook JSON outside systemMessage" bash -c '! jq -r "del(.systemMessage)" <<<"$2" | grep -q "$1"' _ "$CODE" "$CH_OUT"
lib "consent_challenge block-env-commit '$FP' x '$SID'" >/dev/null; rc=$?
check "ineligible hook: no challenge (rc 1)" [ "$rc" = 1 ]
lib "consent_challenge $HOOKNAME '$FP' x ''" >/dev/null; rc=$?
check "empty session: no challenge (rc 1)" [ "$rc" = 1 ]
lib "consent_challenge $HOOKNAME '' x '$SID'" >/dev/null; rc=$?
check "empty fingerprint: no challenge (rc 1)" [ "$rc" = 1 ]

echo "== grant via UserPromptSubmit hook =="
out="$(prompt_hook "atelier permitir $CODE" "$SID")"
check "hook reports grant" msg_has "$out" "consent granted once"
check "additionalContext does not contain the code" bash -c '! jq -r ".hookSpecificOutput.additionalContext" <<<"$2" | grep -q "$1"' _ "$CODE" "$out"
check "grant file for exact fingerprint exists" [ -f "$ATELIER_CONFIG_DIR/state/consent/grants/$FP.json" ]
check "different fingerprint is not consumed" [ "$(consume "$FP3" "$SID")" = 1 ]
check "grant still present after wrong-fp consume" [ -f "$ATELIER_CONFIG_DIR/state/consent/grants/$FP.json" ]
check "other session cannot consume" [ "$(consume "$FP" other-sess)" = 1 ]
check "grant restored after other-session attempt" [ -f "$ATELIER_CONFIG_DIR/state/consent/grants/$FP.json" ]
check "exact action + session consumes (rc 0)" [ "$(consume "$FP" "$SID")" = 0 ]
check "second consume fails (single use)" [ "$(consume "$FP" "$SID")" = 1 ]
out="$(prompt_hook "atelier permitir $CODE" "$SID")"
check "replayed code rejected" msg_has "$out" "NOT granted"
check "replay grants nothing" [ ! -f "$ATELIER_CONFIG_DIR/state/consent/grants/$FP.json" ]

echo "== hook accepts the English form =="
fresh_env
challenge "$FP" "$SID"
out="$(prompt_hook "  atelier allow $CODE please" "$SID")"
check "atelier allow <CODE> grants" msg_has "$out" "consent granted once"

echo "== rejections grant nothing =="
fresh_env
challenge "$FP" "$SID"
wrong="AAAAAAAA"; [ "$CODE" = "$wrong" ] && wrong="BBBBBBBB"
out="$(prompt_hook "atelier permitir $wrong" "$SID")"
check "wrong code rejected" msg_has "$out" "NOT granted"
check "wrong code: no grant" [ -z "$(ls "$ATELIER_CONFIG_DIR/state/consent/grants")" ]
out="$(prompt_hook "atelier permitir $CODE" other-sess)"
check "other-session code rejected" msg_has "$out" "different session"
check "other-session: no grant" [ -z "$(ls "$ATELIER_CONFIG_DIR/state/consent/grants")" ]
fresh_env
challenge "$FP" "$SID"
for p in "please run atelier permitir $CODE" "echo atelier permitir $CODE" "atelier permitir ${CODE}X" \
         "atelier permitir ${CODE:0:7}" "atelier permitir $(tr '[:upper:]' '[:lower:]' <<<"$CODE")" "atelierpermitir $CODE"; do
  out="$(prompt_hook "$p" "$SID")"
  check "non-matching text yields no output: '${p//$CODE/<CODE>}'" [ -z "$out" ]
done
check "non-matching text: no grant" [ -z "$(ls "$ATELIER_CONFIG_DIR/state/consent/grants")" ]
check "pending record untouched by non-matching text" [ -n "$(ls "$ATELIER_CONFIG_DIR/state/consent/pending")" ]
out="$(prompt_hook "atelier permitir $CODE" "$SID")"
check "valid code still works afterwards" msg_has "$out" "consent granted once"

echo "== expired challenge =="
fresh_env
challenge "$FP" "$SID"
export ATELIER_CONSENT_TTL_SECONDS=0
out="$(prompt_hook "atelier permitir $CODE" "$SID")"
check "expired code rejected" msg_has "$out" "expired"
check "expired code: no grant" [ -z "$(ls "$ATELIER_CONFIG_DIR/state/consent/grants")" ]
unset ATELIER_CONSENT_TTL_SECONDS
out="$(prompt_hook "atelier permitir $CODE" "$SID")"
check "expired code cannot be retried" msg_has "$out" "NOT granted"

echo "== expired grant =="
fresh_env
challenge "$FP" "$SID"
prompt_hook "atelier permitir $CODE" "$SID" >/dev/null
g="$ATELIER_CONFIG_DIR/state/consent/grants/$FP.json"
jq '.expires = 1' "$g" > "$g.tmp" && mv "$g.tmp" "$g"
check "expired grant not consumed" [ "$(consume "$FP" "$SID")" = 1 ]
check "expired grant moved to expired/" [ -n "$(ls "$ATELIER_CONFIG_DIR/state/consent/expired")" ]
check "expired grant gone from grants/" [ ! -f "$g" ]

echo "== ledger and decision log =="
fresh_env
challenge "$FP" "$SID"
prompt_hook "atelier permitir $CODE" "$SID" >/dev/null
consume "$FP" "$SID" >/dev/null
prompt_hook "atelier permitir $CODE" "$SID" >/dev/null   # replay -> reject
challenge "$FP3" "$SID"; code2="$CODE"
export ATELIER_CONSENT_TTL_SECONDS=0
prompt_hook "atelier permitir $code2" "$SID" >/dev/null  # expire
unset ATELIER_CONSENT_TTL_SECONDS
for ev in challenge grant consume reject expire; do
  check "ledger has $ev" jq -e -s --arg e "$ev" 'any(.[]; .event==$e)' "$LEDGER" >/dev/null
  check "hook-decisions has $ev" jq -e -s --arg e "$ev" 'any(.[]; .pattern==$e and .tool=="consent")' "$DLOG" >/dev/null
done
check "consume logged as allow-consent" jq -e -s 'any(.[]; .action=="allow-consent")' "$DLOG" >/dev/null
check "challenge logged as consent-challenge" jq -e -s 'any(.[]; .action=="consent-challenge")' "$DLOG" >/dev/null
check "ledger lines are valid JSON" jq -e -s 'length > 0' "$LEDGER" >/dev/null
for c in "$CODE" "$code2"; do
  check "no plaintext code $c in ledger/decision log/state dir" bash -c '! grep -rq "$1" "$2" "$3"' _ "$c" "$ATELIER_CONFIG_DIR/state" "$DLOG"
done

echo "== fail closed =="
fresh_env
empty_bin="$TMP/nojq-bin"; mkdir -p "$empty_bin"
PATH="$empty_bin" "$(command -v bash)" -c 'source "$1/hooks/lib/consent.sh"; consent_challenge block-gh-api-mutation fp x sess' _ "$REPO_ROOT" >/dev/null 2>&1; rc=$?
check "no jq on PATH: challenge returns non-zero" [ "$rc" != 0 ]
PATH="$empty_bin" "$(command -v bash)" -c 'source "$1/hooks/lib/consent.sh"; consent_consume block-gh-api-mutation fp sess' _ "$REPO_ROOT" >/dev/null 2>&1; rc=$?
check "no jq on PATH: consume returns non-zero" [ "$rc" != 0 ]
# a grant that exists must not be honoured without jq
challenge "$FP" "$SID"; prompt_hook "atelier permitir $CODE" "$SID" >/dev/null
PATH="$empty_bin" "$(command -v bash)" -c 'source "$1/hooks/lib/consent.sh"; consent_consume block-gh-api-mutation "$2" "$3"' _ "$REPO_ROOT" "$FP" "$SID" >/dev/null 2>&1; rc=$?
check "no jq on PATH: existing grant not honoured" [ "$rc" != 0 ]
check "no jq: grant still unconsumed" [ -f "$ATELIER_CONFIG_DIR/state/consent/grants/$FP.json" ]
PATH="$empty_bin" "$(command -v bash)" -c 'source "$1/hooks/lib/consent.sh"; consent_grant ABCDEFGH sess' _ "$REPO_ROOT" >"$TMP/g.out" 2>&1; rc=$?
check "no jq on PATH: grant returns non-zero" [ "$rc" != 0 ]
fresh_env
touch "$TMP/afile"; export ATELIER_CONFIG_DIR="$TMP/afile"   # state dir cannot be created under a file
out="$(lib "consent_challenge $HOOKNAME '$FP' x '$SID'" 2>/dev/null)"; rc=$?
check "unwritable state dir: challenge non-zero, no output" [ "$rc" != 0 ] && [ -z "$out" ]
check "unwritable state dir: consume non-zero" [ "$(consume "$FP" "$SID")" != 0 ]
lib "consent_grant ABCDEFGH '$SID'" >/dev/null; rc=$?
check "unwritable state dir: grant non-zero" [ "$rc" != 0 ]

echo
if [ "$fails" -eq 0 ]; then echo "operator-consent: all assertions passed"; exit 0; fi
echo "operator-consent: $fails assertion(s) FAILED"; exit 1
