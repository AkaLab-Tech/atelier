#!/usr/bin/env bash
#
# Tests for #407a — scripts/atelier-review-verdict (read-only verdict resolver)
# and the #407a surfaces that consume it (auto-merge skill, babysit-prs,
# install.sh registration).
#
# Hermetic: `gh` is a PATH shim serving fixtures from $FIX (login for
# `gh api user`, pr.json for `gh pr view`, a `fail` flag to simulate errors).
#
# Run:  hooks/tests/review-verdict-helper.test.sh
# Exit: 0 = all passed, 1 = at least one failed.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/atelier-review-verdict"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; mkdir -p "$TMP/bin" "$FIX"

PASS=0; FAILN=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "  FAIL: $1"; }
chk_prose() { grep -qF -- "$2" "$1" 2>/dev/null && pass "$3" || fail "$3 — '$2' not in $1"; }
chk_absent() { grep -qF -- "$2" "$1" 2>/dev/null && fail "$3 — '$2' still in $1" || pass "$3"; }

cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
[ -f "$FIX/fail" ] && { echo "gh: boom" >&2; exit 1; }
case "$1 $2" in
  "api user") [ -f "$FIX/loginfail" ] && exit 1; case "${GH_CONFIG_DIR:-}" in */gh/reviewer) cat "$FIX/login" ;; *) exit 1 ;; esac ;;
  "pr view") cat "$FIX/pr.json" ;;
  *) echo "gh-stub: unexpected: $*" >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"
export FIX PATH="$TMP/bin:$PATH" ATELIER_CONFIG_DIR="$TMP/cfg"

H="1111111111111111111111111111111111111111"
OLD="2222222222222222222222222222222222222222"
MARK='<!-- atelier-reviewer-verdict/v1 -->'

# review <login> <state> <commit> <submittedAt> <decision> <head> [nomarker]
review() {
  local body
  if [ "${7:-}" = nomarker ]; then body="LGTM"
  else body="$MARK
\`\`\`
Decision: $5
Head: $6
Auto-merge: yes
\`\`\`"; fi
  jq -n --arg l "$1" --arg s "$2" --arg c "$3" --arg t "$4" --arg b "$body" \
    '{author:{login:$l},state:$s,commit:{oid:$c},submittedAt:$t,body:$b}'
}
# setup <author> <reviewDecision|""> <reviews-json-array>
setup() {
  rm -f "$FIX/fail"; printf 'reviewer-bot\n' > "$FIX/login"
  jq -n --arg a "$1" --arg d "$2" --arg h "$H" --argjson r "$3" \
    '{author:{login:$a},headRefOid:$h,reviewDecision:$d,reviews:$r}' > "$FIX/pr.json"
}
run() { OUT="$(bash "$HELPER" o/r 7 2>/dev/null)"; RC=$?; }
expect() { # label out rc
  run
  if [ "$OUT" = "$2" ] && [ "$RC" = "$3" ]; then pass "$1"; else fail "$1 — got '$OUT' rc=$RC, want '$2' rc=$3"; fi
}

echo "== helper =="
setup author "" "[$(review reviewer-bot COMMENTED $H 2026-10-14T10:00:00Z approve $H)]"
expect "matching v1 verdict -> approve + sha" "verdict=approve sha=$H" 0

setup author "" "[$(review reviewer-bot COMMENTED $OLD 2026-10-14T10:00:00Z approve $OLD)]"
expect "verdict for older head -> stale" "verdict=stale sha=$OLD" 1

setup author "" "[$(review mallory COMMENTED $H 2026-10-14T10:00:00Z approve $H)]"
expect "verdict by non-reviewer login (forgery) -> none" "verdict=none" 1

setup reviewer-bot "" "[$(review reviewer-bot COMMENTED $H 2026-10-14T10:00:00Z approve $H)]"
expect "reviewer login == PR author -> none" "verdict=none" 1

setup author "" "[$(review reviewer-bot COMMENTED $H 2026-10-14T10:00:00Z approve $OLD)]"
expect "body Head != commit.oid -> none" "verdict=none" 1

setup author "" "[$(review reviewer-bot CHANGES_REQUESTED $H 2026-10-14T10:00:00Z request-changes $H)]"
expect "request-changes verdict -> request-changes" "verdict=request-changes" 1

setup author "APPROVED" "[$(review reviewer-bot APPROVED $H 2026-10-14T10:00:00Z x $H nomarker)]"
expect "legacy APPROVED without marker -> approved" "verdict=approved sha=$H" 0

setup author "CHANGES_REQUESTED" "[$(review reviewer-bot COMMENTED $H 2026-10-14T09:00:00Z approve $H)]"
expect "CHANGES_REQUESTED beats older approve verdict" "verdict=request-changes" 1

setup author "" "[$(review reviewer-bot COMMENTED $H 2026-10-14T09:00:00Z approve $H),$(review reviewer-bot COMMENTED $H 2026-10-14T11:00:00Z request-changes $H)]"
expect "newer request-changes supersedes older approve" "verdict=request-changes" 1

setup author "" "[$(review reviewer-bot COMMENTED $H 2026-10-14T11:00:00Z approve $H),$(review reviewer-bot COMMENTED $OLD 2026-10-14T09:00:00Z request-changes $OLD)]"
expect "newer approve supersedes older stale request-changes" "verdict=approve sha=$H" 0

setup author "" "[$(review reviewer-bot COMMENTED $H 2026-10-14T10:00:00Z x $H nomarker)]"
expect "advisory comment without marker -> none" "verdict=none" 1

setup author "" "[]"
touch "$FIX/fail"
run
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "gh failure -> exit 2, no pass"; else fail "gh failure — got '$OUT' rc=$RC"; fi

bash "$HELPER" >/dev/null 2>&1; [ $? = 2 ] && pass "usage error -> exit 2" || fail "usage error exit code"

bash "$HELPER" o/r abc >/dev/null 2>&1; [ $? = 2 ] && pass "non-numeric PR number -> exit 2" || fail "non-numeric PR exit code"

bash "$HELPER" --help >/dev/null 2>&1; [ $? = 0 ] && pass "--help -> exit 0" || fail "--help exit code"

# reviewer-login lookup failure: gh api user exits non-zero -> exit 2, nothing on stdout
setup author "" "[$(review reviewer-bot COMMENTED $H 2026-10-14T10:00:00Z approve $H)]"
touch "$FIX/loginfail"
run
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "reviewer login lookup failure -> exit 2, empty stdout"; else fail "login failure — got '$OUT' rc=$RC"; fi
rm -f "$FIX/loginfail"

# empty reviewer login -> exit 2
setup author "" "[$(review reviewer-bot COMMENTED $H 2026-10-14T10:00:00Z approve $H)]"
: > "$FIX/login"
run
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "empty reviewer login -> exit 2, empty stdout"; else fail "empty login — got '$OUT' rc=$RC"; fi

# unparseable PR JSON -> exit 2
setup author "" "[]"
printf 'not json' > "$FIX/pr.json"
run
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "malformed PR JSON -> exit 2, empty stdout"; else fail "malformed JSON — got '$OUT' rc=$RC"; fi

# malformed verdict bodies (marker present) -> none
mkbody() { # <decision-line> <head-line> -> review JSON with custom body
  jq -n --arg h "$H" --arg b "$MARK
\`\`\`
$1
$2
Auto-merge: yes
\`\`\`" '{author:{login:"reviewer-bot"},state:"COMMENTED",commit:{oid:$h},submittedAt:"2026-10-14T10:00:00Z",body:$b}'
}
setup author "" "[$(mkbody 'Verdict: approve' "Head: $H")]"
expect "missing Decision line -> none" "verdict=none" 1

setup author "" "[$(mkbody 'Decision: maybe' "Head: $H")]"
expect "unknown Decision value -> none" "verdict=none" 1

setup author "" "[$(mkbody 'Decision: approved' "Head: $H")]"
expect "Decision 'approved' (not exact token) -> none" "verdict=none" 1

setup author "" "[$(mkbody 'Decision: approve' 'Head: abc123')]"
expect "short non-40-hex Head -> none" "verdict=none" 1

setup author "" "[$(mkbody 'Decision: approve' 'Head: ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ')]"
expect "non-hex 40-char Head -> none" "verdict=none" 1

setup author "" "[$(mkbody 'Decision: approve' 'Auto-merge-note: none')]"
expect "missing Head line -> none" "verdict=none" 1

# newer malformed verdict supersedes an older valid approve -> none (never a stale pass)
setup author "" "[$(review reviewer-bot COMMENTED $H 2026-10-14T09:00:00Z approve $H),$(mkbody 'Decision: maybe' "Head: $H" | jq '.submittedAt="2026-10-14T12:00:00Z"')]"
expect "newer malformed verdict supersedes older valid approve -> none" "verdict=none" 1

# null reviewDecision (no JSON key value) with old request-changes then newer approve
setup author "" "[$(review reviewer-bot COMMENTED $OLD 2026-10-14T08:00:00Z request-changes $OLD),$(review reviewer-bot COMMENTED $H 2026-10-14T12:00:00Z approve $H)]"
jq '.reviewDecision=null' "$FIX/pr.json" > "$FIX/pr2.json" && mv "$FIX/pr2.json" "$FIX/pr.json"
expect "reviewDecision null: newer approve supersedes older request-changes" "verdict=approve sha=$H" 0

# missing reviews key entirely -> none
printf '{"author":{"login":"author"},"headRefOid":"%s","reviewDecision":null}' "$H" > "$FIX/pr.json"
expect "no reviews key -> none" "verdict=none" 1

echo "== #407a surfaces =="
chk_prose "$ROOT/skills/auto-merge/SKILL.md" "atelier-review-verdict" "auto-merge names the helper"
chk_prose "$ROOT/skills/auto-merge/SKILL.md" "--match-head-commit" "auto-merge pins the merge to the reviewed sha"
chk_prose "$ROOT/commands/babysit-prs.md" "atelier-review-verdict" "babysit-prs names the helper"
chk_absent "$ROOT/commands/babysit-prs.md" "unprotected-repo hold" "babysit-prs: no unprotected-repo terminal hold"
chk_prose "$ROOT/install.sh" "_phase_c_1_symlink_helper atelier-review-verdict" "install.sh registers the helper"

echo "passed=$PASS failed=$FAILN"
[ "$FAILN" = 0 ]
