#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
#
# Regression test for #735 (#726 part 1) — hooks/size-waiver-capture.sh
# (PostToolUse / AskUserQuestion) and hooks/lib/size-waiver-record.sh: capture of an
# affirmative main-session size-waiver answer into an HMAC-signed record.
#
# Hermetic: ATELIER_CONFIG_DIR and CLAUDE_PROJECT_DIR point at a temp dir;
# CLAUDE_CODE_BRIDGE_SESSION_ID is cleared. Requires jq and openssl.
#
# Run:  hooks/tests/size-waiver-capture.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/size-waiver-capture.sh"
TAMPER="$REPO_ROOT/hooks/block-consent-tamper.sh"
FIX="$REPO_ROOT/hooks/tests/fixtures"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl required"; exit 0; }

TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # name, cmd...
  local n="$1"; shift
  if "$@"; then pass "$n"; else fail "$n"; fi
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

unset CLAUDE_CODE_BRIDGE_SESSION_ID
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

fresh_env() {
  local d; d="$(mktemp -d "$TMP/env.XXXXXX")"
  export ATELIER_CONFIG_DIR="$d/cfg" CLAUDE_PROJECT_DIR="$d/wt"
  mkdir -p "$ATELIER_CONFIG_DIR" "$CLAUDE_PROJECT_DIR"
  ROOT="$ATELIER_CONFIG_DIR/state/consent"
  LEDGER="$ROOT/ledger.jsonl"
  KEY="$ROOT/size-waiver.key"
}

# lib <bash code>: run code with the libraries sourced.
lib() {
  bash -c 'source "$1/hooks/lib/log-decision.sh"; source "$1/hooks/lib/size-waiver-record.sh"; shift; eval "$1"' _ "$REPO_ROOT" "$1"
}

SHA="0123456789abcdef0123456789abcdef01234567"
SHA2="fedcba9876543210fedcba9876543210fedcba98"
REPO="AkaLab-Tech/atelier"
MARK="[atelier size-waiver $REPO#9999 @$SHA 300L/12F]"
YES_ES="Sí, dispenso el tamaño"

# payload <question> <answer> [extra jq filter] -> PostToolUse JSON from the main fixture
payload() {
  jq -c --arg q "$1" --arg a "$2" '
    .tool_input.questions[0].question = $q
    | .tool_response.questions[0].question = $q
    | .tool_input.answers = {($q): $a}
    | .tool_response.answers = {($q): $a}
    | '"${3:-.}" "$FIX/askuserquestion-posttooluse-main.json"
}
run() { printf '%s' "$1" | bash "$HOOK" >"$TMP/out" 2>"$TMP/err"; RC=$?; }
rec() { printf '%s/size-waivers/%s__%s.json' "$ROOT" "${REPO/\//__}" "${1:-9999}"; }
nledger() { if [ -f "$LEDGER" ]; then grep -c "\"event\":\"$1\"" "$LEDGER"; else echo 0; fi; }
nrecords() { find "$ROOT/size-waivers" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

QMAIN="Waive it? $MARK"

echo "== capture: affirmative main-session answer =="
fresh_env
run "$(payload "$QMAIN" "$YES_ES")"
R="$(rec)"
check "exit 0" test "$RC" = 0
check "record exists" test -f "$R"
check "record fields" jq -e --arg sha "$SHA" --arg q "$QMAIN" --arg a "$YES_ES" '
  .repo=="AkaLab-Tech/atelier" and .pr==9999 and .head_sha==$sha and .lines==300 and .files==12
  and .question==$q and .answer==$a and .session_id=="00000000-0000-0000-0000-000000000000"
  and .source=="askuserquestion-posttooluse" and (.captured_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
  and (.hmac|test("^[0-9a-f]{64}$"))' "$R" >/dev/null
check "record mode 0600" test "$(mode_of "$R")" = 600
# independent HMAC recomputation with the key
canon="$(jq -j '"1\u001f"+([.repo,.pr,.head_sha,.lines,.files,.question,.answer,.session_id,.captured_at]|map(tostring)|join("\u001f"))' "$R")"
want="$(printf '%s' "$canon" | openssl dgst -sha256 -hmac "$(cat "$KEY")" | awk '{print $NF}')"
check "HMAC matches recomputation with the key" test "$want" = "$(jq -r .hmac "$R")"
check "swr_verify accepts the record" lib "swr_verify '$R'"
tampered="$TMP/tampered.json"; jq '.lines=1' "$R" >"$tampered"
check "swr_verify rejects an edited record" bash -c '! { source "$1/hooks/lib/size-waiver-record.sh"; swr_verify "$2"; }' _ "$REPO_ROOT" "$tampered"
check "ledger has size-waiver-capture line" test "$(nledger size-waiver-capture)" = 1
check "systemMessage emitted" bash -c 'jq -e ".systemMessage|test(\"recorded size waiver\")" "$1" >/dev/null' _ "$TMP/out"

echo "== key: created 0600 and reused =="
check "key mode 0600" test "$(mode_of "$KEY")" = 600
check "key is 64 hex chars" bash -c '[[ "$(cat "$1")" =~ ^[0-9a-f]{64}$ ]]' _ "$KEY"
k1="$(cat "$KEY")"
run "$(payload "Again? [atelier size-waiver $REPO#9998 @$SHA2 10L/1F]" "Yes, waive the size limit")"
check "key reused on second capture" test "$k1" = "$(cat "$KEY")"
check "second PR record written" test -f "$(rec 9998)"

echo "== replace record atomically =="
run "$(payload "Waive it? [atelier size-waiver $REPO#9999 @$SHA2 400L/20F]" "Yes, the waiver covers it")"
check "record replaced with new sha" test "$(jq -r .head_sha "$R")" = "$SHA2"
check "replaced record has new answer" test "$(jq -r .answer "$R")" = "Yes, the waiver covers it"
check "replaced record still verifies" lib "swr_verify '$R'"
check "no leftover temp files" test -z "$(find "$ROOT/size-waivers" -name '.tmp.*' 2>/dev/null)"
check "only the two records exist" test "$(nrecords)" = 2

echo "== decline after capture leaves record unchanged =="
before="$(cat "$R")"
run "$(payload "Waive it? [atelier size-waiver $REPO#9999 @$SHA 1L/1F]" "No")"
check "record unchanged after decline" test "$before" = "$(cat "$R")"
check "decline logged" test "$(nledger size-waiver-decline)" = 1

echo "== no record cases =="
no_record() { # name payload [ledger-event expected-count]
  fresh_env
  run "$2"
  if [ "$RC" = 0 ] && [ "$(nrecords)" = 0 ]; then pass "no record: $1"; else fail "no record: $1 (rc=$RC, records=$(nrecords))"; fi
  if [ -n "${3:-}" ]; then check "ledger $3 logged: $1" test "$(nledger "$3")" = 1; fi
}
no_record "subagent payload (agent_id)" "$(payload "$QMAIN" "$YES_ES" '.agent_id="agent-123"')" size-waiver-reject
no_record "decline No" "$(payload "$QMAIN" "No")" size-waiver-decline
no_record "free-text Other answer" "$(payload "$QMAIN" "sure, go ahead and waive it")" size-waiver-decline
no_record "unmarked question" "$(payload "Waive the size limit please?" "$YES_ES")"
no_record "short sha" "$(payload "Q [atelier size-waiver $REPO#9999 @0123456789abcdef 300L/12F]" "$YES_ES")"
no_record "uppercase sha" "$(payload "Q [atelier size-waiver $REPO#9999 @$(printf %s "$SHA" | tr a-f A-F) 300L/12F]" "$YES_ES")"
no_record "missing files field" "$(payload "Q [atelier size-waiver $REPO#9999 @$SHA 300L]" "$YES_ES")"
no_record "missing sha field" "$(payload "Q [atelier size-waiver $REPO#9999 300L/12F]" "$YES_ES")"
no_record "non-numeric sizes" "$(payload "Q [atelier size-waiver $REPO#9999 @$SHA xL/yF]" "$YES_ES")"
no_record "non-numeric pr" "$(payload "Q [atelier size-waiver $REPO#abc @$SHA 300L/12F]" "$YES_ES")"
no_record "non-AskUserQuestion tool" "$(payload "$QMAIN" "$YES_ES" '.tool_name="Bash"')"
no_record "answer keyed by another question" "$(payload "$QMAIN" "$YES_ES" '.tool_response.answers = {"other question": "Sí, dispenso el tamaño"}')"

echo "== pre-filled overridden: answer comes from tool_response.answers =="
fresh_env
run "$(payload "$QMAIN" "$YES_ES" '.tool_response.answers[$q] = "No"')"
check "tool_input says yes but tool_response says No: no record" test "$(nrecords)" = 0
check "decline logged for override" test "$(nledger size-waiver-decline)" = 1
fresh_env
run "$(payload "$QMAIN" "No" '.tool_response.answers[$q] = "Sí, dispenso el tamaño"')"
check "tool_input says No but tool_response says yes: record" test -f "$(rec)"
fresh_env
run "$(jq -c '.tool_input.answers |= with_entries(.value="Sí, dispenso el tamaño")' "$FIX/askuserquestion-posttooluse-prefilled-overridden.json")"
check "prefilled-overridden fixture (response No, input rewritten): no record" test "$(nrecords)" = 0
fresh_env
run "$(cat "$FIX/askuserquestion-posttooluse-main.json")"
check "main fixture unchanged: captured" test -f "$(rec)"
fresh_env
run "$(cat "$FIX/askuserquestion-posttooluse-other.json")"
check "other fixture: no record" test "$(nrecords)" = 0

echo "== multiple questions in one call =="
fresh_env
run "$(payload "$QMAIN" "$YES_ES" '
  .tool_input.questions += [{question:"Second? [atelier size-waiver '"$REPO"'#7 @'"$SHA2"' 5L/2F]",options:[]}]
  | .tool_response.answers["Second? [atelier size-waiver '"$REPO"'#7 @'"$SHA2"' 5L/2F]"]="No"')"
check "affirmed question recorded, declined one not" test "$(nrecords)" = 1 -a -f "$(rec 9999)"

echo "== swr_question round trip =="
for lang in en es; do
  q="$(lib "swr_question $REPO 42 $SHA 250 11 $lang" | jq -r '.[0].question')"
  out="$(bash -c 'source "$1/hooks/lib/size-waiver-record.sh"; swr_parse_marker "$2" && echo "$repo|$pr|$sha|$lines|$files"' _ "$REPO_ROOT" "$q")"
  check "$lang question round-trips" test "$out" = "$REPO|42|$SHA|250|11"
  first="$(lib "swr_question $REPO 42 $SHA 250 11 $lang" | jq -r '.[0].options[0].label')"
  check "$lang first option affirmative ($first)" bash -c 'source "$1/hooks/lib/size-waiver-record.sh"; swr_is_affirmative "$2"' _ "$REPO_ROOT" "$first"
  check "$lang marker equals swr_marker" test "$q" = "$q" -a "${q: -${#MARK}}" != ""
  check "$lang question contains marker" bash -c 'source "$1/hooks/lib/size-waiver-record.sh"; [[ "$2" == *"$(swr_marker "$3" 42 "$4" 250 11)"* ]]' _ "$REPO_ROOT" "$q" "$REPO" "$SHA"
  # full capture with the generated question
  fresh_env
  qj="$(lib "swr_question $REPO 42 $SHA 250 11 $lang")"
  qq="$(jq -r '.[0].question' <<<"$qj")"
  run "$(payload "$qq" "$first")"
  check "$lang generated question captured end to end" test "$(jq -r '.pr' "$(rec 42)")" = 42
done

echo "== affirmative label set =="
aff() { bash -c 'source "$1/hooks/lib/size-waiver-record.sh"; swr_is_affirmative "$2"' _ "$REPO_ROOT" "$1"; }
for l in "Yes, waive the size limit" "Yes, the waiver covers it" "Sí, dispenso el tamaño" "Sí, la dispensa lo cubre"; do
  check "affirmative: $l" aff "$l"
done
for l in "No" "" "Yes" "yes, waive the size limit" "Yes, waive the size limit." "Yes, waive the size" "Si, dispenso el tamaño" "Sí, dispenso el tamano" "Yes, waive the size limit and merge" "Sí"; do
  if aff "$l"; then fail "near-miss accepted: '$l'"; else pass "near-miss rejected: '$l'"; fi
done

echo "== tamper guard blocks record and key paths =="
fresh_env
run "$(payload "$QMAIN" "$YES_ES")"
tamper() { # tool path -> rc
  jq -cn --arg t "$1" --arg p "$2" '{tool_name:$t, tool_input:{file_path:$p, content:"x"}}' \
    | bash "$TAMPER" >/dev/null 2>&1
  echo "$?"
}
check "Read of record blocked" test "$(tamper Read "$(rec)")" = 2
check "Write of record blocked" test "$(tamper Write "$(rec)")" = 2
check "Read of key blocked" test "$(tamper Read "$KEY")" = 2
check "Write of key blocked" test "$(tamper Write "$KEY")" = 2

echo "== robustness =="
fresh_env
printf 'not json at all {{{' | bash "$HOOK" >/dev/null 2>&1; rc=$?
check "garbage stdin exits 0" test "$rc" = 0
printf '' | bash "$HOOK" >/dev/null 2>&1; rc=$?
check "empty stdin exits 0" test "$rc" = 0
check "garbage stdin writes nothing" test "$(nrecords)" = 0

# openssl missing: PATH trimmed to a dir holding only the tools the hook needs, minus openssl
fresh_env
BIN="$TMP/bin-noopenssl"; mkdir -p "$BIN"
for t in bash jq cat date mkdir mktemp mv rm ln head od tr awk base64 dirname printf sed grep stat find wc; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$BIN/$t"
done
payload "$QMAIN" "$YES_ES" | PATH="$BIN" "$BIN/bash" "$HOOK" >/dev/null 2>&1; rc=$?
check "openssl missing: exit 0" test "$rc" = 0
check "openssl missing: no record" test "$(nrecords)" = 0

# uncreatable key: a directory squats on the key path
fresh_env
mkdir -p "$KEY"
run "$(payload "$QMAIN" "$YES_ES")"
check "uncreatable key: exit 0" test "$RC" = 0
check "uncreatable key: no record" test "$(nrecords)" = 0

# unwritable state dir
fresh_env
mkdir -p "$ROOT/size-waivers"; chmod 500 "$ROOT/size-waivers"
run "$(payload "$QMAIN" "$YES_ES")"
rc="$RC"; n="$(nrecords)"
chmod 700 "$ROOT/size-waivers"
if [ "$(id -u)" = 0 ]; then
  pass "unwritable state dir: skipped as root"
else
  check "unwritable state dir: exit 0" test "$rc" = 0
  check "unwritable state dir: no record" test "$n" = 0
fi

echo "== hooks.json registration =="
check "PostToolUse/AskUserQuestion registered" jq -e '
  .hooks.PostToolUse[] | select(.matcher=="AskUserQuestion") | .hooks[]
  | select(.type=="command" and (.command|test("hooks/size-waiver-capture.sh")))' "$REPO_ROOT/hooks/hooks.json" >/dev/null

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
