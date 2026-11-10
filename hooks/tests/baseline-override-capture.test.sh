#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329
#
# Regression test for #746 (#744 part 1) — hooks/baseline-override-capture.sh
# (PostToolUse / AskUserQuestion) and hooks/lib/baseline-override-record.sh: capture of an
# affirmative main-session baseline-override answer into an HMAC-signed record.
#
# Hermetic: ATELIER_CONFIG_DIR and CLAUDE_PROJECT_DIR point at a temp dir;
# CLAUDE_CODE_BRIDGE_SESSION_ID is cleared. Requires jq and openssl.
#
# Run:  hooks/tests/baseline-override-capture.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/baseline-override-capture.sh"
TAMPER="$REPO_ROOT/hooks/block-consent-tamper.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl required"; exit 0; }

TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

unset CLAUDE_CODE_BRIDGE_SESSION_ID
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

fresh_env() {
  local d; d="$(mktemp -d "$TMP/env.XXXXXX")"
  export ATELIER_CONFIG_DIR="$d/cfg" CLAUDE_PROJECT_DIR="$d/wt"
  mkdir -p "$ATELIER_CONFIG_DIR" "$CLAUDE_PROJECT_DIR"
  ROOT="$ATELIER_CONFIG_DIR/state/consent"
  LEDGER="$ROOT/ledger.jsonl"
  KEY="$ROOT/baseline-override.key"
}

lib() {
  bash -c 'source "$1/hooks/lib/log-decision.sh"; source "$1/hooks/lib/baseline-override-record.sh"; shift; eval "$1"' _ "$REPO_ROOT" "$1"
}

SHA="0123456789abcdef0123456789abcdef01234567"
REPO="AkaLab-Tech/atelier"
BR="task/746-baseline-override-record"
YES_EN="Yes, waive these tests for this branch"
YES_ES="Sí, dispenso estos tests para esta rama"
# Non-ASCII identifiers: U+203A and curly quotes must survive byte-exact.
ID1='Checkout › renders “Pay now” button'
ID2='Cart › adds item'
ID3='Zeta ü ‘quoted’ case'

# payload <question> <answer> [extra jq filter]
payload() {
  jq -cn --arg q "$1" --arg a "$2" '
    {session_id:"00000000-0000-0000-0000-000000000000", hook_event_name:"PostToolUse", tool_name:"AskUserQuestion",
     tool_input:{questions:[{question:$q,options:[]}], answers:{($q):$a}},
     tool_response:{answers:{($q):$a}}} | '"${3:-.}"
}
# build a question text from the lib for the three ids
gen_q() { # lang -> question text
  bash -c 'source "$1/hooks/lib/baseline-override-record.sh"; lang="$2"; shift 2; bor_question "$REPO" "$BR" "$SHA" "$lang" "$@" | jq -r ".[0].question"' \
    _ "$REPO_ROOT" "$1" "$ID1" "$ID2" "$ID3"
}
export REPO BR SHA ID1 ID2 ID3
run() { printf '%s' "$1" | bash "$HOOK" >"$TMP/out" 2>"$TMP/err"; RC=$?; }
rec() { printf '%s/baseline-overrides/%s__%s.json' "$ROOT" "${REPO/\//__}" "${BR//\//__}"; }
nledger() { if [ -f "$LEDGER" ]; then grep -c "\"event\":\"$1\"" "$LEDGER"; else echo 0; fi; }
nrecords() { find "$ROOT/baseline-overrides" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

QEN="$(gen_q en)"
QES="$(gen_q es)"

echo "== question shape =="
check "marker present with n=3" bash -c '[[ "$1" == *"[atelier baseline-override $2 $3 @$4 n=3 h="* ]]' _ "$QEN" "$REPO" "$BR" "$SHA"
check "ids sorted by LC_ALL=C between delimiters" test "$(printf '%s\n' "$QEN" | awk '/^--- end ---$/{f=0} f{print} /^--- waived ---$/{f=1}')" = "$(printf '%s\n' "$ID1" "$ID2" "$ID3" | LC_ALL=C sort -u)"
check "unicode ids appear verbatim" bash -c '[[ "$1" == *"$2"* ]]' _ "$QEN" "$ID1"

echo "== capture: affirmative main-session answer =="
fresh_env
run "$(payload "$QEN" "$YES_EN")"
R="$(rec)"
check "exit 0" test "$RC" = 0
check "record at canonical path" test -f "$R"
check "record mode 0600" test "$(mode_of "$R")" = 600
check "key mode 0600" test "$(mode_of "$KEY")" = 600
check "key is 64 hex" bash -c '[[ "$(cat "$1")" =~ ^[0-9a-f]{64}$ ]]' _ "$KEY"
check "record fields" jq -e --arg sha "$SHA" --arg q "$QEN" --arg a "$YES_EN" --arg repo "$REPO" --arg br "$BR" '
  .v==1 and .repo==$repo and .branch==$br and .base_sha==$sha and .question==$q and .answer==$a
  and .session_id=="00000000-0000-0000-0000-000000000000" and .source=="askuserquestion-posttooluse"
  and (.captured_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and (.hmac|test("^[0-9a-f]{64}$"))' "$R" >/dev/null
check "waived array holds the 3 ids sorted, byte-exact" test "$(jq -r '.waived[]' "$R")" = "$(printf '%s\n' "$ID1" "$ID2" "$ID3" | LC_ALL=C sort -u)"
check "waived is a JSON array of 3" jq -e '(.waived|type=="array") and (.waived|length==3) and (.waived|index("Checkout › renders “Pay now” button") != null)' "$R" >/dev/null
check "bor_verify passes" lib "bor_verify '$R'"
check "bor_lookup returns the path" test "$(lib "bor_lookup $REPO $BR")" = "$R"
check "ledger baseline-override-capture logged" test "$(nledger baseline-override-capture)" = 1
check "systemMessage text" test "$(jq -r .systemMessage "$TMP/out")" = "atelier recorded baseline override for $REPO $BR (3 tests). "

echo "== capture: Spanish label =="
fresh_env
run "$(payload "$QES" "$YES_ES")"
check "es question + es label records" test -f "$(rec)"
fresh_env
run "$(payload "$QEN" "  $YES_EN  ")"
check "whitespace-trimmed label records" test -f "$(rec)"
fresh_env
run "$(payload "$QEN" "$YES_ES")"
check "es label on en question records (closed label set)" test -f "$(rec)"

echo "== key reuse and record replace =="
fresh_env
run "$(payload "$QEN" "$YES_EN")"; k1="$(cat "$KEY")"
run "$(payload "$QEN" "$YES_EN")"
check "key reused" test "$k1" = "$(cat "$KEY")"
check "one record after repeat" test "$(nrecords)" = 1
check "no leftover temp files" test -z "$(find "$ROOT/baseline-overrides" -name '.tmp.*' 2>/dev/null)"
check "replaced record verifies" lib "bor_verify '$(rec)'"

echo "== no record cases =="
no_record() { # name payload [ledger-event]
  fresh_env
  run "$2"
  if [ "$RC" = 0 ] && [ "$(nrecords)" = 0 ]; then pass "no record: $1"; else fail "no record: $1 (rc=$RC, records=$(nrecords))"; fi
  [ -z "${3:-}" ] || check "ledger $3 logged: $1" test "$(nledger "$3")" = 1
}
# count mismatch: marker says n=3 but one id removed from the list
Q_COUNT="$(printf '%s' "$QEN" | grep -vF -- "$ID2")"
# digest mismatch: same count, one id swapped
Q_DIGEST="${QEN//"$ID2"/Cart › adds items}"
# digest mismatch via a look-alike character (ASCII quotes instead of curly)
Q_ASCII="${QEN//“Pay now”/\"Pay now\"}"
no_record "subagent selector (agent_id set)" "$(payload "$QEN" "$YES_EN" '.agent_id="agent-123"')" baseline-override-reject
no_record "answer No" "$(payload "$QEN" "No")" baseline-override-decline
no_record "free-text Other answer" "$(payload "$QEN" "sure, waive them")" baseline-override-decline
no_record "near-miss label" "$(payload "$QEN" "Yes, waive these tests for this branch.")" baseline-override-decline
no_record "unmarked question" "$(payload "Waive these tests?" "$YES_EN")"
no_record "count mismatch" "$(payload "$Q_COUNT" "$YES_EN")" baseline-override-reject
no_record "digest mismatch (swapped id)" "$(payload "$Q_DIGEST" "$YES_EN")" baseline-override-reject
no_record "digest mismatch (ASCII quotes for curly)" "$(payload "$Q_ASCII" "$YES_EN")" baseline-override-reject
no_record "empty id list" "$(payload "${QEN%%--- waived ---*}" "$YES_EN")"
no_record "non-AskUserQuestion tool" "$(payload "$QEN" "$YES_EN" '.tool_name="Bash"')"
no_record "answer keyed by another question" "$(payload "$QEN" "$YES_EN" '.tool_response.answers = {"other": "'"$YES_EN"'"}')"
no_record "tool_response says No though tool_input says yes" "$(payload "$QEN" "$YES_EN" '.tool_response.answers[$q] = "No"')" baseline-override-decline
no_record "short sha in marker" "$(payload "${QEN/@$SHA/@0123abcd}" "$YES_EN")"
fresh_env
run "$(payload "$QEN" "$YES_EN" '.agent_id="a1"')"
check "subagent: no key created either" test ! -e "$KEY"

echo "== multiple questions in one call =="
fresh_env
run "$(jq -cn --arg q "$QEN" --arg y "$YES_EN" --arg q2 "Other? [atelier baseline-override $REPO other @$SHA n=1 h=0000000000000000]
--- waived ---
x
--- end ---" '
  {tool_name:"AskUserQuestion",session_id:"s",tool_input:{questions:[{question:$q},{question:$q2}]},tool_response:{answers:{($q):$y,($q2):"No"}}}')"
check "affirmed recorded, other not" test "$(nrecords)" = 1 -a -f "$(rec)"

echo "== bor_verify: signed-field edits, other key, missing key =="
fresh_env
run "$(payload "$QEN" "$YES_EN")"
R="$(rec)"
ver_fails() { bash -c '! { source "$1/hooks/lib/log-decision.sh"; source "$1/hooks/lib/baseline-override-record.sh"; bor_verify "$2"; }' _ "$REPO_ROOT" "$1"; }
for f in \
  '.repo="Other/repo"' '.branch="task/other"' '.base_sha="fedcba9876543210fedcba9876543210fedcba98"' \
  '.waived+=["extra test"]' '.waived|=map(select(.!="Cart › adds item"))' '.waived[0]="Checkout > renders \"Pay now\" button"' \
  '.question+=" "' '.answer="Sí, dispenso estos tests para esta rama"' '.session_id="other"' '.captured_at="2020-01-01T00:00:00Z"'; do
  jq "$f" "$R" >"$TMP/edit.json"
  check "edit rejected: $f" ver_fails "$TMP/edit.json"
done
cp "$KEY" "$TMP/key.orig"
printf '%s' "$(printf 'a%.0s' $(seq 1 64))" >"$KEY"
check "different key rejected" ver_fails "$R"
cp "$TMP/key.orig" "$KEY"
check "original key accepts again" lib "bor_verify '$R'"
rm -f "$KEY"
check "bor_verify with key missing: fails (key not silently recreated to match)" ver_fails "$R"

echo "== bor_lookup refusals =="
fresh_env
lib "bor_write $REPO $BR $SHA \"\$(printf 'a\nb')\" 'Q' '$YES_EN' sid 2026-01-01T00:00:00Z"
R="$(rec)"
check "bor_write via lib: lookup ok" test "$(lib "bor_lookup $REPO $BR")" = "$R"
check "write via lib: waived array [a,b]" test "$(jq -c .waived "$R")" = '["a","b"]'
check "lookup refuses other branch" bash -c '! { source "$1/hooks/lib/log-decision.sh"; source "$1/hooks/lib/baseline-override-record.sh"; bor_lookup "$2" task/other; }' _ "$REPO_ROOT" "$REPO"
check "lookup refuses other repo" bash -c '! { source "$1/hooks/lib/log-decision.sh"; source "$1/hooks/lib/baseline-override-record.sh"; bor_lookup Other/repo "$2"; }' _ "$REPO_ROOT" "$BR"
# record copied under another branch's canonical path: content mismatch
cp "$R" "$ROOT/baseline-overrides/${REPO/\//__}__task__other.json"
check "lookup refuses record whose content names another branch" bash -c '! { source "$1/hooks/lib/log-decision.sh"; source "$1/hooks/lib/baseline-override-record.sh"; bor_lookup "$2" task/other; }' _ "$REPO_ROOT" "$REPO"
mv "$R" "$TMP/real.json"; ln -s "$TMP/real.json" "$R"
check "lookup refuses a symlink" bash -c '! { source "$1/hooks/lib/log-decision.sh"; source "$1/hooks/lib/baseline-override-record.sh"; bor_lookup "$2" "$3"; }' _ "$REPO_ROOT" "$REPO" "$BR"
rm -f "$R"
check "lookup refuses a missing record" bash -c '! { source "$1/hooks/lib/log-decision.sh"; source "$1/hooks/lib/baseline-override-record.sh"; bor_lookup "$2" "$3"; }' _ "$REPO_ROOT" "$REPO" "$BR"

echo "== tamper guard =="
fresh_env
run "$(payload "$QEN" "$YES_EN")"
tamper() { # tool field value -> rc
  jq -cn --arg t "$1" --arg f "$2" --arg v "$3" '{tool_name:$t, tool_input:{($f):$v, content:"x"}}' | bash "$TAMPER" >/dev/null 2>&1
  echo "$?"
}
check "Read of record blocked" test "$(tamper Read file_path "$(rec)")" = 2
check "Edit of record blocked" test "$(tamper Edit file_path "$(rec)")" = 2
check "Write of record blocked" test "$(tamper Write file_path "$(rec)")" = 2
check "Edit of key blocked" test "$(tamper Edit file_path "$KEY")" = 2
check "Write of key blocked" test "$(tamper Write file_path "$KEY")" = 2
check "Bash cat of record blocked" test "$(tamper Bash command "cat $(rec)")" = 2
check "Bash cat of key blocked" test "$(tamper Bash command "cat $KEY")" = 2

echo "== robustness: exit 0 everywhere =="
fresh_env
printf 'not json {{{' | bash "$HOOK" >/dev/null 2>&1; check "garbage stdin exits 0" test "$?" = 0
printf '' | bash "$HOOK" >/dev/null 2>&1; check "empty stdin exits 0" test "$?" = 0
check "garbage writes nothing" test "$(nrecords)" = 0

BIN="$TMP/bin-nojq"; mkdir -p "$BIN"
for t in bash cat date mkdir mktemp mv rm ln head od tr awk base64 dirname printf sed grep stat find wc cut sort openssl shasum sha256sum; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$BIN/$t"
done
payload "$QEN" "$YES_EN" | PATH="$BIN" "$BIN/bash" "$HOOK" >/dev/null 2>&1; rc=$?
check "jq missing: exit 0" test "$rc" = 0
check "jq missing: no record" test "$(nrecords)" = 0

BIN2="$TMP/bin-noopenssl"; mkdir -p "$BIN2"
for t in bash jq cat date mkdir mktemp mv rm ln head od tr awk base64 dirname printf sed grep stat find wc cut sort shasum sha256sum; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$BIN2/$t"
done
payload "$QEN" "$YES_EN" | PATH="$BIN2" "$BIN2/bash" "$HOOK" >/dev/null 2>&1; rc=$?
check "openssl missing: exit 0" test "$rc" = 0
check "openssl missing: no record" test "$(nrecords)" = 0

fresh_env
mkdir -p "$KEY"
run "$(payload "$QEN" "$YES_EN")"
check "uncreatable key: exit 0" test "$RC" = 0
check "uncreatable key: no record" test "$(nrecords)" = 0

echo "== hooks.json registration =="
check "PostToolUse/AskUserQuestion registered" jq -e '
  .hooks.PostToolUse[] | select(.matcher=="AskUserQuestion") | .hooks[]
  | select(.type=="command" and (.command|test("hooks/baseline-override-capture.sh")))' "$REPO_ROOT/hooks/hooks.json" >/dev/null

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
