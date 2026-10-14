#!/usr/bin/env bash
#
# Tests for #436 (unit #407b) — scripts/atelier-review-verdict across the
# request-changes -> fix (new head) -> approve sequence in `verdict` mode.
# The reviewer's rejection is a COMMENTED review carrying the v1 marker with
# `Decision: request-changes` (never a GitHub --request-changes review), so
# reviewDecision stays null / REVIEW_REQUIRED throughout.
#
# Hermetic: `gh` is a PATH shim serving fixtures from $FIX. No network.
#
# Run:  hooks/tests/review-verdict-sequence.test.sh
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

cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api user") case "${GH_CONFIG_DIR:-}" in */gh/reviewer) cat "$FIX/login" ;; *) exit 1 ;; esac ;;
  "pr view") cat "$FIX/pr.json" ;;
  *) echo "gh-stub: unexpected: $*" >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"
export FIX PATH="$TMP/bin:$PATH" ATELIER_CONFIG_DIR="$TMP/cfg"
printf 'reviewer-bot\n' > "$FIX/login"

OLD="1111111111111111111111111111111111111111"
NEW="3333333333333333333333333333333333333333"
MARK='<!-- atelier-reviewer-verdict/v1 -->'

# review <login> <commit> <submittedAt> <decision> <head>  (always COMMENTED)
review() {
  local body="$MARK
\`\`\`
Decision: $4
Head: $5
Auto-merge: no — blockers
\`\`\`"
  jq -n --arg l "$1" --arg c "$2" --arg t "$3" --arg b "$body" \
    '{author:{login:$l},state:"COMMENTED",commit:{oid:$c},submittedAt:$t,body:$b}'
}
# setup <headRefOid> <reviewDecision|""> <reviews-json-array>
setup() {
  jq -n --arg h "$1" --arg d "$2" --argjson r "$3" \
    '{author:{login:"author"},headRefOid:$h,reviewDecision:(if $d=="" then null else $d end),reviews:$r}' > "$FIX/pr.json"
}
expect() { # label want-out want-rc
  local out rc
  out="$(bash "$HELPER" o/r 7 2>/dev/null)"; rc=$?
  if [ "$out" = "$2" ] && [ "$rc" = "$3" ]; then pass "$1"; else fail "$1 — got '$out' rc=$rc, want '$2' rc=$3"; fi
}

RC_OLD="$(review reviewer-bot $OLD 2026-10-14T10:00:00Z request-changes $OLD)"
APPROVE_NEW="$(review reviewer-bot $NEW 2026-10-14T12:00:00Z approve $NEW)"

echo "== request-changes -> fix -> approve (verdict mode) =="

# (1) old head, rejection as COMMENTED review, reviewDecision null
setup $OLD "" "[$RC_OLD]"
expect "1. old head, COMMENTED request-changes, reviewDecision null -> request-changes (exit 1)" \
  "verdict=request-changes" 1

setup $OLD "REVIEW_REQUIRED" "[$RC_OLD]"
expect "1b. same with reviewDecision REVIEW_REQUIRED -> request-changes (exit 1)" \
  "verdict=request-changes" 1

# (2) fix pushed: head moved, latest verdict still the old request-changes
setup $NEW "" "[$RC_OLD]"
expect "2. after push (head moved) -> stale at the old sha (exit 1)" \
  "verdict=stale sha=$OLD" 1

setup $NEW "REVIEW_REQUIRED" "[$RC_OLD]"
expect "2b. after push, reviewDecision REVIEW_REQUIRED -> stale (exit 1)" \
  "verdict=stale sha=$OLD" 1

# (3) re-review at new head: approve supersedes the older request-changes
setup $NEW "" "[$RC_OLD,$APPROVE_NEW]"
expect "3. new-head approve with older request-changes still listed -> approve (exit 0)" \
  "verdict=approve sha=$NEW" 0

setup $NEW "REVIEW_REQUIRED" "[$APPROVE_NEW,$RC_OLD]"
expect "3b. same, reviews listed newest-first, REVIEW_REQUIRED -> approve (exit 0)" \
  "verdict=approve sha=$NEW" 0

# Guard: a second rejection at the new head supersedes the old one, not approve
RC_NEW="$(review reviewer-bot $NEW 2026-10-14T12:00:00Z request-changes $NEW)"
setup $NEW "" "[$RC_OLD,$RC_NEW]"
expect "4. second request-changes at new head -> request-changes (exit 1)" \
  "verdict=request-changes" 1

echo
echo "passed=$PASS failed=$FAILN"
[ "$FAILN" -eq 0 ]
