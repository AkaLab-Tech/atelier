#!/usr/bin/env bash
# shellcheck disable=SC2016
#
# Tests for #748 (#744 part 3) — scripts/atelier-baseline-override (read-only question builder
# and verifier for the operator's baseline-override confirmation).
#
# Hermetic: ATELIER_CONFIG_DIR, CLAUDE_PROJECT_DIR and the worktree are temp dirs; the worktree
# is a real git repo with a github.com origin. The #746 capture hook is driven directly to turn
# the helper's question into a signed record. Requires jq, openssl and git.
#
# Run:  hooks/tests/baseline-override-helper.test.sh
# Exit: 0 = all passed, 1 = at least one failed.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/atelier-baseline-override"
HOOK="$ROOT/hooks/baseline-override-capture.sh"

for t in jq openssl git; do
  command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t required"; exit 0; }
done

TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0; FAILN=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "  FAIL: $1"; }
check() { local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }

unset CLAUDE_CODE_BRIDGE_SESSION_ID ATELIER_PLUGIN_ROOT
export CLAUDE_PLUGIN_ROOT="$ROOT"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

REPO="AkaLab-Tech/atelier"
BR="task/748-baseline-override-helper"
SHA="0123456789abcdef0123456789abcdef01234567"
SHA2="fedcba9876543210fedcba9876543210fedcba98"
YES_EN="Yes, waive these tests for this branch"
YES_ES="Sí, dispenso estos tests para esta rama"
ID1='Checkout › renders “Pay now” button'
ID2='Cart › adds item'
ID3='Zeta ü ‘quoted’ case'

fresh() {
  local d; d="$(mktemp -d "$TMP/env.XXXXXX")"
  export ATELIER_CONFIG_DIR="$d/cfg" CLAUDE_PROJECT_DIR="$d/wt"
  WT="$d/wt"; mkdir -p "$ATELIER_CONFIG_DIR" "$WT/.task-log"
  git -C "$WT" init -q
  git -C "$WT" symbolic-ref HEAD "refs/heads/$BR"
  git -C "$WT" remote add origin "https://github.com/$REPO.git"
  LOG="$WT/.task-log/decisions.jsonl"
  CONSENT="$ATELIER_CONFIG_DIR/state/consent"
}
# line <mode> <choice> <sha> <waived ids...>
line() {
  local mode="$1" choice="$2" sha="$3"; shift 3
  jq -cn --arg m "$mode" --arg c "$choice" --arg s "$sha" '{category:"baseline-conflict",choice:$c,mode:$m,
    evidence:{base_sha:$s,waived:$ARGS.positional}}' --args "$@" >> "$LOG"
}
run() { OUT="$(bash "$HELPER" "$@" 2>"$TMP/err")"; RC=$?; }
expect() { # label want-rc want-out args...
  local label="$1" wrc="$2" wout="$3"; shift 3
  run "$@"
  if [ "$RC" = "$wrc" ] && [ "$OUT" = "$wout" ]; then pass "$label"; else fail "$label — got rc=$RC out='$OUT', want rc=$wrc out='$wout'"; fi
}
qtext() { printf '%s' "$OUT" | jq -r '.[0].question'; }
capture() { # question answer
  jq -cn --arg q "$1" --arg a "$2" '{session_id:"00000000-0000-0000-0000-000000000000",hook_event_name:"PostToolUse",
    tool_name:"AskUserQuestion",tool_input:{questions:[{question:$q,options:[]}],answers:{($q):$a}},
    tool_response:{answers:{($q):$a}}}' | bash "$HOOK" >/dev/null 2>&1
}
NONE="question=none (no override decision with a waived set)"

echo "== --help =="
OUT="$(bash "$HELPER" --help)"; RC=$?
check "--help exit 0" test "$RC" = 0
check "--help prints the header" bash -c '[[ "$1" == *"atelier-baseline-override"*"Usage:"*"override=valid"* ]]' _ "$OUT"

echo "== --question: source line selection =="
fresh
line ask override "$SHA" "$ID1" "$ID2" "$ID3"
run --question --worktree "$WT" --lang en
check "ask line: exit 0" test "$RC" = 0
Q="$(qtext)"
check "marker carries repo, branch, sha, n=3" bash -c '[[ "$1" == *"[atelier baseline-override $2 $3 @$4 n=3 h="* ]]' _ "$Q" "$REPO" "$BR" "$SHA"
check "ids listed verbatim" bash -c '[[ "$1" == *"$2"* && "$1" == *"$3"* && "$1" == *"$4"* ]]' _ "$Q" "$ID1" "$ID2" "$ID3"
check "output is a JSON array with one question" test "$(printf '%s' "$OUT" | jq 'length')" = 1

fresh
line auto override "$SHA" "$ID1" "$ID2"
run --question --worktree "$WT"
check "auto line: exit 0, n=2" bash -c '[[ $2 = 0 && "$1" == *" n=2 h="* ]]' _ "$(qtext)" "$RC"
fresh
line rule:host-only override "$SHA" "$ID1"
run --question --worktree "$WT"
check "rule:host-only line: exit 0, n=1" bash -c '[[ $2 = 0 && "$1" == *" n=1 h="* ]]' _ "$(qtext)" "$RC"

fresh
line ask override "$SHA2" "$ID3"
line ask override "$SHA" "$ID1" "$ID2"
run --question --worktree "$WT"
check "newest line wins (sha, n=2)" bash -c '[[ "$1" == *"@$2 n=2 h="* ]]' _ "$(qtext)" "$SHA"
check "older line's id ignored" bash -c '[[ "$1" != *"$2"* ]]' _ "$(qtext)" "$ID3"

fresh
line ask override "$SHA" "$ID1"
line ask abort "$SHA2" "$ID2" "$ID3"
line ask override "$SHA2"
jq -cn '{category:"other",choice:"override",evidence:{base_sha:"x",waived:["z"]}}' >> "$LOG"
run --question --worktree "$WT"
check "newer non-matching lines (other choice/category, empty waived) ignored" bash -c '[[ "$1" == *"@$2 n=1 h="* && "$1" == *"$3"* ]]' _ "$(qtext)" "$SHA" "$ID1"

echo "== --question: none =="
fresh; rm -r "$WT/.task-log"
expect "missing decisions.jsonl" 1 "$NONE" --question --worktree "$WT"
fresh; : > "$LOG"
expect "empty decisions.jsonl" 1 "$NONE" --question --worktree "$WT"
fresh; line ask abort "$SHA" "$ID1"; jq -cn '{category:"size",choice:"override",evidence:{waived:["a"]}}' >> "$LOG"
expect "only non-matching lines" 1 "$NONE" --question --worktree "$WT"
fresh; line ask override "$SHA"
expect "empty waived set" 1 "$NONE" --question --worktree "$WT"

echo "== --lang =="
fresh; line ask override "$SHA" "$ID1" "$ID2"
run --question --worktree "$WT" --lang en; EN="$(qtext)"; RCEN=$RC
run --question --worktree "$WT" --lang es; ES="$(qtext)"; RCES=$RC; ESOUT="$OUT"
check "en and es both exit 0" test "$RCEN$RCES" = 00
check "en and es texts differ" test "$EN" != "$ES"
check "es answer label is Spanish" bash -c 'printf "%s" "$1" | jq -e --arg l "$2" "[.[0].options[].label] | index(\$l) != null" >/dev/null' _ "$ESOUT" "$YES_ES"
run --question --worktree "$WT"
check "default lang is en" test "$(qtext)" = "$EN"
for bad in fr EN ""; do
  run --question --worktree "$WT" --lang "$bad"
  check "--lang '$bad' exits 2" test "$RC" = 2
done

echo "== round trip through the #746 capture hook =="
fresh; line ask override "$SHA" "$ID1" "$ID2" "$ID3"
expect "no record yet: override=none" 1 "override=none" --worktree "$WT"
run --question --worktree "$WT"; capture "$(qtext)" "$YES_EN"
run --worktree "$WT"
check "verify: valid line, exit 0" bash -c '[[ $2 = 0 && "$1" =~ ^override=valid\ repo=AkaLab-Tech/atelier\ branch=task/748-baseline-override-helper\ n=3\ base=0123456789ab\ at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]' _ "$OUT" "$RC"
fresh; line ask override "$SHA" "$ID1" "$ID2" "$ID3"
run --question --worktree "$WT" --lang es; capture "$(qtext)" "$YES_ES"
run --worktree "$WT"
check "es question round-trips to valid n=3" bash -c '[[ $2 = 0 && "$1" == "override=valid "*" n=3 base=0123456789ab at="* ]]' _ "$OUT" "$RC"

echo "== verify: invalid / none =="
fresh; line ask override "$SHA" "$ID1" "$ID2"
run --question --worktree "$WT"; capture "$(qtext)" "$YES_EN"
REC="$(find "$CONSENT/baseline-overrides" -name '*.json' | head -1)"
cp "$REC" "$TMP/rec.good"
jq '.waived += ["Injected › extra"]' "$TMP/rec.good" > "$REC"
expect "tampered waived set: override=invalid" 1 "override=invalid" --worktree "$WT"
jq '.hmac = ("0" * 64)' "$TMP/rec.good" > "$REC"
expect "bad hmac: override=invalid" 1 "override=invalid" --worktree "$WT"
printf 'not json' > "$REC"
expect "garbage record: override=invalid" 1 "override=invalid" --worktree "$WT"
cp "$TMP/rec.good" "$REC"
run --worktree "$WT"; check "restored record is valid again" bash -c '[[ $2 = 0 && "$1" == override=valid* ]]' _ "$OUT" "$RC"
git -C "$WT" symbolic-ref HEAD refs/heads/task/999-other
expect "other branch: override=none" 1 "override=none" --worktree "$WT"
git -C "$WT" symbolic-ref HEAD "refs/heads/$BR"
jq '.repo = "evil/other"' "$TMP/rec.good" > "$REC"
expect "record naming another repo: override=invalid" 1 "override=invalid" --worktree "$WT"
cp "$TMP/rec.good" "$REC"
git -C "$WT" remote set-url origin https://github.com/other/repo.git
expect "other repo: override=none" 1 "override=none" --worktree "$WT"

echo "== usage / fail closed =="
fresh
for args in "" "--question" "--worktree" "--worktree $WT --bogus" "--worktree $TMP/nope"; do
  # shellcheck disable=SC2086
  run $args
  check "usage error exits 2: '${args//$WT/<wt>}'" test "$RC" = 2
done
mkdir -p "$TMP/norepo/wt" "$TMP/orphan/scripts"
git -C "$TMP/norepo/wt" init -q
run --worktree "$TMP/norepo/wt"
check "worktree without origin exits 2" test "$RC" = 2
cp "$HELPER" "$TMP/orphan/scripts/atelier-baseline-override"
OUT="$(bash "$TMP/orphan/scripts/atelier-baseline-override" --worktree "$WT" 2>"$TMP/err")"; RC=$?
check "library missing: exit 2, nothing on stdout" bash -c '[ "$1" = 2 ] && [ -z "$2" ]' _ "$RC" "$OUT"
check "library missing: stderr names the library" grep -q "record library not found" "$TMP/err"
OUT="$(bash "$TMP/orphan/scripts/atelier-baseline-override" --question --worktree "$WT" 2>/dev/null)"; RC=$?
check "library missing, --question: exit 2" test "$RC" = 2

echo "== read-only =="
fresh; line ask override "$SHA" "$ID1" "$ID2"
run --question --worktree "$WT"; capture "$(qtext)" "$YES_EN"
before="$(cat "$LOG")"
snap="$(cd "$CONSENT" && find . -type f | LC_ALL=C sort | xargs shasum | shasum)"
run --question --worktree "$WT"
run --worktree "$WT"
check "verify after capture still valid" bash -c '[[ $2 = 0 && "$1" == override=valid* ]]' _ "$OUT" "$RC"
check "decisions.jsonl unchanged" test "$(cat "$LOG")" = "$before"
check "state/consent unchanged (no writes)" test "$(cd "$CONSENT" && find . -type f | LC_ALL=C sort | xargs shasum | shasum)" = "$snap"
fresh; line ask override "$SHA" "$ID1"
run --question --worktree "$WT"; run --worktree "$WT"
check "no state/consent created when nothing was captured" test ! -e "$CONSENT"

echo
echo "baseline-override-helper: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
