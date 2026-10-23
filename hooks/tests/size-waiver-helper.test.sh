#!/usr/bin/env bash
#
# Tests for #542 (538a) — scripts/atelier-size-waiver (read-only operator size-waiver resolver).
#
# Hermetic: `gh` is a PATH shim serving fixtures from $FIX:
#   - `gh api user` returns the login in $FIX/login.author or $FIX/login.reviewer, chosen by
#     GH_CONFIG_DIR (…/gh/author vs …/gh/reviewer); $FIX/loginfail makes it fail.
#   - `gh pr view` returns $FIX/pr.json.
#   - `gh api repos/<r>/collaborators/<login>/permission` returns $FIX/perm.<login> (JSON);
#     $FIX/perm404.<login> -> "HTTP 404" on stderr + exit 1; no file -> generic failure (HTTP 500).
#   - $FIX/fail makes every gh call fail.
#
# Run:  hooks/tests/size-waiver-helper.test.sh
# Exit: 0 = all passed, 1 = at least one failed.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/atelier-size-waiver"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; mkdir -p "$TMP/bin" "$FIX" "$TMP/cfg/gh/author" "$TMP/cfg/gh/reviewer"

PASS=0; FAILN=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "  FAIL: $1"; }

cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
[ -f "$FIX/fail" ] && { echo "gh: boom" >&2; exit 1; }
case "$1 $2" in
  "api user")
    [ -f "$FIX/loginfail" ] && exit 1
    case "${GH_CONFIG_DIR:-}" in
      */gh/author) cat "$FIX/login.author" ;;
      */gh/reviewer) cat "$FIX/login.reviewer" ;;
      *) exit 1 ;;
    esac ;;
  "pr view") cat "$FIX/pr.json" ;;
  api\ repos/*/collaborators/*/permission)
    login="${2#repos/*/collaborators/}"; login="${login%/permission}"
    if [ -f "$FIX/perm404.$login" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    if [ -f "$FIX/perm.$login" ]; then cat "$FIX/perm.$login"; exit 0; fi
    echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
  *) echo "gh-stub: unexpected: $*" >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"
export FIX PATH="$TMP/bin:$PATH" ATELIER_CONFIG_DIR="$TMP/cfg"

H="1111111111111111111111111111111111111111"
OLD="2222222222222222222222222222222222222222"
URL="https://github.com/o/r/pull/7#pullrequestreview-1"

# review <login> <state> <commit> <submittedAt> <body>
review() {
  jq -n --arg l "$1" --arg s "$2" --arg c "$3" --arg t "$4" --arg b "$5" --arg u "$URL" \
    '{author:{login:$l},state:$s,commit:{oid:$c},submittedAt:$t,body:$b,url:$u}'
}
# perm <login> <role_name> <permission>
perm() { jq -n --arg r "$2" --arg p "$3" '{role_name:$r,permission:$p}' > "$FIX/perm.$1"; }
# setup <pr-author> <reviews-json-array>
setup() {
  rm -f "$FIX"/fail "$FIX"/loginfail "$FIX"/perm.* "$FIX"/perm404.*
  printf 'author-bot\n' > "$FIX/login.author"
  printf 'reviewer-bot\n' > "$FIX/login.reviewer"
  jq -n --arg a "$1" --arg h "$H" --arg u "https://github.com/o/r/pull/7" --argjson r "$2" \
    '{author:{login:$a},headRefOid:$h,url:$u,reviews:$r}' > "$FIX/pr.json"
}
run() { OUT="$(bash "$HELPER" "$@" 2>/dev/null)"; RC=$?; }
expect() { # label out rc [args...]
  local label="$1" want="$2" rc="$3"; shift 3
  [ $# -eq 0 ] && set -- o/r 7
  run "$@"
  if [ "$OUT" = "$want" ] && [ "$RC" = "$rc" ]; then pass "$label"; else fail "$label — got '$OUT' rc=$RC, want '$want' rc=$rc"; fi
}

T1=2026-10-14T10:00:00Z
T2=2026-10-14T11:00:00Z

echo "== valid =="
setup author "[$(review alice COMMENTED $H $T1 'Size waiver: generated migration, safe')]"
perm alice admin admin
expect "COMMENTED waiver by admin -> valid" \
  "waiver=valid sha=$H by=alice at=$T1 review=$URL reason=generated migration, safe" 0

setup author "[$(review alice APPROVED $H $T1 'waive size - vendored lockfile bump')]"
perm alice maintain maintain
expect "APPROVED waiver by maintainer -> valid" \
  "waiver=valid sha=$H by=alice at=$T1 review=$URL reason=vendored lockfile bump" 0

setup author "[$(review alice COMMENTED $H $T1 'Exención de tamaño: refactor mecánico')]"
perm alice admin admin
expect "Spanish phrase -> valid" \
  "waiver=valid sha=$H by=alice at=$T1 review=$URL reason=refactor mecánico" 0

setup author "[$(review alice COMMENTED $H $T1 'SIZE WAIVER: loud')]"
perm alice admin admin
expect "phrase is case-insensitive" \
  "waiver=valid sha=$H by=alice at=$T1 review=$URL reason=loud" 0

echo "== stale =="
setup author "[$(review alice COMMENTED $OLD $T1 'size waiver: ok')]"
perm alice admin admin
expect "waiver on older head -> stale" "waiver=stale sha=$OLD" 1

echo "== untrusted =="
setup author "[$(review author-bot COMMENTED $H $T1 'size waiver: self')]"
perm author-bot admin admin
expect "author agent login -> untrusted" "waiver=untrusted by=author-bot (atelier author agent)" 1

setup author "[$(review reviewer-bot COMMENTED $H $T1 'size waiver: reviewer')]"
perm reviewer-bot admin admin
expect "reviewer agent login -> untrusted" "waiver=untrusted by=reviewer-bot (atelier reviewer agent)" 1

setup carol "[$(review carol COMMENTED $H $T1 'size waiver: mine')]"
perm carol admin admin
expect "PR author -> untrusted" "waiver=untrusted by=carol (PR author)" 1

setup author "[$(review 'dependabot[bot]' COMMENTED $H $T1 'size waiver: bot')]"
expect "[bot] account -> untrusted" "waiver=untrusted by=dependabot[bot] (bot account)" 1

setup author "[$(review bob COMMENTED $H $T1 'size waiver: please')]"
perm bob write write
expect "write-only user -> untrusted" "waiver=untrusted by=bob (lacks admin/maintain permission)" 1

setup author "[$(review dave COMMENTED $H $T1 'size waiver: please')]"
touch "$FIX/perm404.dave"
expect "non-collaborator (HTTP 404) -> untrusted" "waiver=untrusted by=dave (not a collaborator)" 1

setup author "[$(review erin COMMENTED $H $T1 'size waiver: please')]"
run o/r 7
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "permission API failure (HTTP 500) -> exit 2"; else fail "permission failure — got '$OUT' rc=$RC"; fi

echo "== not a waiver =="
setup author "[$(review alice COMMENTED $H $T1 'size waiver:   ')]"
perm alice admin admin
expect "empty reason -> none" "waiver=none" 1

setup author "[$(review alice DISMISSED $H $T1 'size waiver: ok')]"
perm alice admin admin
expect "dismissed review -> none" "waiver=none" 1

setup author "[$(review alice CHANGES_REQUESTED $H $T1 'size waiver: ok')]"
perm alice admin admin
expect "changes-requested review -> none" "waiver=none" 1

setup author "[$(review alice COMMENTED $H $T1 'looks fine to me')]"
perm alice admin admin
expect "review without phrase -> none" "waiver=none" 1

# Issue comments (a top-level `comments` array) never count, even with the phrase.
setup author "[]"
jq '. + {comments:[{author:{login:"alice"},body:"size waiver: ok"}]}' "$FIX/pr.json" > "$FIX/pr2.json" && mv "$FIX/pr2.json" "$FIX/pr.json"
perm alice admin admin
expect "issue comment with phrase, no review -> none" "waiver=none" 1

echo "== ordering =="
setup author "[$(review alice COMMENTED $H $T1 'size waiver: first reason'),$(review frank APPROVED $H $T2 'size waiver: second reason')]"
perm alice admin admin; perm frank maintain maintain
expect "newest qualifying review wins" \
  "waiver=valid sha=$H by=frank at=$T2 review=$URL reason=second reason" 0

setup author "[$(review alice COMMENTED $H $T1 'size waiver: ok'),$(review bob COMMENTED $H $T2 'size waiver: ok')]"
perm alice admin admin; perm bob write write
expect "newest untrusted is not rescued by older valid one" \
  "waiver=untrusted by=bob (lacks admin/maintain permission)" 1

echo "== errors =="
setup author "[]"
touch "$FIX/fail"
run o/r 7
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "gh failure -> exit 2, no pass"; else fail "gh failure — got '$OUT' rc=$RC"; fi

setup author "[$(review alice COMMENTED $H $T1 'size waiver: ok')]"
touch "$FIX/loginfail"
run o/r 7
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "agent login lookup failure -> exit 2"; else fail "login failure — got '$OUT' rc=$RC"; fi

setup author "[$(review alice COMMENTED $H $T1 'size waiver: ok')]"
printf '\n' > "$FIX/login.author"
run o/r 7
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "empty agent login -> exit 2"; else fail "empty login — got '$OUT' rc=$RC"; fi

setup author "[]"
run --kind bogus o/r 7
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "unknown --kind -> exit 2"; else fail "unknown kind — got '$OUT' rc=$RC"; fi

run --kind size o/r 7
if [ "$RC" = 1 ] && [ "$OUT" = "waiver=none" ]; then pass "explicit --kind size accepted"; else fail "--kind size — got '$OUT' rc=$RC"; fi

bash "$HELPER" >/dev/null 2>&1; [ $? = 2 ] && pass "no args -> exit 2" || fail "no args exit code"
bash "$HELPER" o/r abc >/dev/null 2>&1; [ $? = 2 ] && pass "non-numeric PR number -> exit 2" || fail "non-numeric PR exit code"
bash "$HELPER" norepo 7 >/dev/null 2>&1; [ $? = 2 ] && pass "repo without slash -> exit 2" || fail "bad repo exit code"
bash "$HELPER" --help >/dev/null 2>&1; [ $? = 0 ] && pass "--help -> exit 0" || fail "--help exit code"

echo
echo "Results: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
