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
  "waiver=valid kind=size source=review sha=$H by=alice at=$T1 review=$URL reason=generated migration, safe" 0

setup author "[$(review alice APPROVED $H $T1 'waive size - vendored lockfile bump')]"
perm alice maintain maintain
expect "APPROVED waiver by maintainer -> valid" \
  "waiver=valid kind=size source=review sha=$H by=alice at=$T1 review=$URL reason=vendored lockfile bump" 0

setup author "[$(review alice COMMENTED $H $T1 'Exención de tamaño: refactor mecánico')]"
perm alice admin admin
expect "Spanish phrase -> valid" \
  "waiver=valid kind=size source=review sha=$H by=alice at=$T1 review=$URL reason=refactor mecánico" 0

setup author "[$(review alice COMMENTED $H $T1 'SIZE WAIVER: loud')]"
perm alice admin admin
expect "phrase is case-insensitive" \
  "waiver=valid kind=size source=review sha=$H by=alice at=$T1 review=$URL reason=loud" 0

echo "== stale =="
setup author "[$(review alice COMMENTED $OLD $T1 'size waiver: ok')]"
perm alice admin admin
expect "waiver on older head -> stale" "waiver=stale sha=$OLD source=review" 1

echo "== untrusted =="
setup author "[$(review author-bot COMMENTED $H $T1 'size waiver: self')]"
perm author-bot admin admin
expect "author agent login -> untrusted" "waiver=untrusted by=author-bot (atelier author agent) source=review" 1

setup author "[$(review reviewer-bot COMMENTED $H $T1 'size waiver: reviewer')]"
perm reviewer-bot admin admin
expect "reviewer agent login -> untrusted" "waiver=untrusted by=reviewer-bot (atelier reviewer agent) source=review" 1

setup carol "[$(review carol COMMENTED $H $T1 'size waiver: mine')]"
perm carol admin admin
expect "PR author -> untrusted" "waiver=untrusted by=carol (PR author) source=review" 1

setup author "[$(review 'dependabot[bot]' COMMENTED $H $T1 'size waiver: bot')]"
expect "[bot] account -> untrusted" "waiver=untrusted by=dependabot[bot] (bot account) source=review" 1

setup author "[$(review bob COMMENTED $H $T1 'size waiver: please')]"
perm bob write write
expect "write-only user -> untrusted" "waiver=untrusted by=bob (lacks admin/maintain permission) source=review" 1

setup author "[$(review dave COMMENTED $H $T1 'size waiver: please')]"
touch "$FIX/perm404.dave"
expect "non-collaborator (HTTP 404) -> untrusted" "waiver=untrusted by=dave (not a collaborator) source=review" 1

setup author "[$(review erin COMMENTED $H $T1 'size waiver: please')]"
run o/r 7
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "permission API failure (HTTP 500) -> exit 2"; else fail "permission failure — got '$OUT' rc=$RC"; fi

echo "== not a waiver =="
setup author "[$(review alice COMMENTED $H $T1 'size waiver:   ')]"
perm alice admin admin
expect "empty reason -> none" "waiver=none source=review" 1

setup author "[$(review alice DISMISSED $H $T1 'size waiver: ok')]"
perm alice admin admin
expect "dismissed review -> none" "waiver=none source=review" 1

setup author "[$(review alice CHANGES_REQUESTED $H $T1 'size waiver: ok')]"
perm alice admin admin
expect "changes-requested review -> none" "waiver=none source=review" 1

setup author "[$(review alice COMMENTED $H $T1 'looks fine to me')]"
perm alice admin admin
expect "review without phrase -> none" "waiver=none source=review" 1

# Issue comments (a top-level `comments` array) never count, even with the phrase.
setup author "[]"
jq '. + {comments:[{author:{login:"alice"},body:"size waiver: ok"}]}' "$FIX/pr.json" > "$FIX/pr2.json" && mv "$FIX/pr2.json" "$FIX/pr.json"
perm alice admin admin
expect "issue comment with phrase, no review -> none" "waiver=none source=review" 1

echo "== ordering =="
setup author "[$(review alice COMMENTED $H $T1 'size waiver: first reason'),$(review frank APPROVED $H $T2 'size waiver: second reason')]"
perm alice admin admin; perm frank maintain maintain
expect "newest qualifying review wins" \
  "waiver=valid kind=size source=review sha=$H by=frank at=$T2 review=$URL reason=second reason" 0

setup author "[$(review alice COMMENTED $H $T1 'size waiver: ok'),$(review bob COMMENTED $H $T2 'size waiver: ok')]"
perm alice admin admin; perm bob write write
expect "newest untrusted is not rescued by older valid one" \
  "waiver=untrusted by=bob (lacks admin/maintain permission) source=review" 1

echo "== protected-paths kind =="
PP() { run --kind protected-paths o/r 7; }
ppexpect() { # label out rc
  PP
  if [ "$OUT" = "$2" ] && [ "$RC" = "$3" ]; then pass "$1"; else fail "$1 — got '$OUT' rc=$RC, want '$2' rc=$3"; fi
}
setup author "[$(review alice COMMENTED $H $T1 'Approve protected paths: release bump reviewed')]"
perm alice admin admin
ppexpect "protected-paths COMMENTED approval by admin -> valid" \
  "waiver=valid kind=protected-paths source=review sha=$H by=alice at=$T1 review=$URL reason=release bump reviewed" 0

setup author "[$(review alice APPROVED $H $T1 'apruebo archivos protegidos: cambio de CI revisado')]"
perm alice maintain maintain
ppexpect "protected-paths APPROVED Spanish phrase by maintainer -> valid" \
  "waiver=valid kind=protected-paths source=review sha=$H by=alice at=$T1 review=$URL reason=cambio de CI revisado" 0

setup author "[$(review alice COMMENTED $H $T1 'size waiver: big refactor')]"
perm alice admin admin
ppexpect "size phrase under --kind protected-paths -> none" "waiver=none source=review" 1

setup author "[$(review alice COMMENTED $H $T1 'approve protected paths: workflow edit')]"
perm alice admin admin
expect "protected-paths phrase under --kind size -> none" "waiver=none source=review" 1 --kind size o/r 7
expect "protected-paths phrase under default kind -> none" "waiver=none source=review" 1

setup author "[$(review alice COMMENTED $OLD $T1 'approve protected paths: ok')]"
perm alice admin admin
ppexpect "protected-paths on older head -> stale" "waiver=stale sha=$OLD source=review" 1

setup author "[$(review author-bot COMMENTED $H $T1 'approve protected paths: self')]"
perm author-bot admin admin
ppexpect "protected-paths: author agent login -> untrusted" "waiver=untrusted by=author-bot (atelier author agent) source=review" 1

setup author "[$(review reviewer-bot COMMENTED $H $T1 'approve protected paths: self')]"
perm reviewer-bot admin admin
ppexpect "protected-paths: reviewer agent login -> untrusted" "waiver=untrusted by=reviewer-bot (atelier reviewer agent) source=review" 1

setup carol "[$(review carol COMMENTED $H $T1 'approve protected paths: mine')]"
perm carol admin admin
ppexpect "protected-paths: PR author -> untrusted" "waiver=untrusted by=carol (PR author) source=review" 1

setup author "[$(review 'dependabot[bot]' COMMENTED $H $T1 'approve protected paths: bot')]"
ppexpect "protected-paths: [bot] account -> untrusted" "waiver=untrusted by=dependabot[bot] (bot account) source=review" 1

setup author "[$(review bob COMMENTED $H $T1 'approve protected paths: please')]"
perm bob write write
ppexpect "protected-paths: write-only user -> untrusted" "waiver=untrusted by=bob (lacks admin/maintain permission) source=review" 1

setup author "[$(review alice COMMENTED $H $T1 'approve protected paths:   ')]"
perm alice admin admin
ppexpect "protected-paths: empty reason -> none" "waiver=none source=review" 1

setup author "[$(review alice COMMENTED $H $T1 'approve protected paths: ok. size waiver: also big')]"
perm alice admin admin
ppexpect "review with both phrases -> ambiguous (protected-paths)" "waiver=ambiguous source=review" 1
expect "review with both phrases -> ambiguous (size)" "waiver=ambiguous source=review" 1 --kind size o/r 7

setup author "[$(review alice COMMENTED $H $T1 'size waiver: ok'),$(review alice COMMENTED $H $T2 'approve protected paths: ok')]"
perm alice admin admin
ppexpect "kinds are independent: newer protected-paths review valid" \
  "waiver=valid kind=protected-paths source=review sha=$H by=alice at=$T2 review=$URL reason=ok" 0
expect "kinds are independent: older size waiver still valid for size" \
  "waiver=valid kind=size source=review sha=$H by=alice at=$T1 review=$URL reason=ok" 0 --kind size o/r 7

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
if [ "$RC" = 1 ] && [ "$OUT" = "waiver=none source=review" ]; then pass "explicit --kind size accepted"; else fail "--kind size — got '$OUT' rc=$RC"; fi

bash "$HELPER" >/dev/null 2>&1; [ $? = 2 ] && pass "no args -> exit 2" || fail "no args exit code"
bash "$HELPER" o/r abc >/dev/null 2>&1; [ $? = 2 ] && pass "non-numeric PR number -> exit 2" || fail "non-numeric PR exit code"
bash "$HELPER" norepo 7 >/dev/null 2>&1; [ $? = 2 ] && pass "repo without slash -> exit 2" || fail "bad repo exit code"
bash "$HELPER" --help >/dev/null 2>&1; [ $? = 0 ] && pass "--help -> exit 0" || fail "--help exit code"

echo "== selector record (#736) =="
# atelier-pr-size-check shim: $FIX/size.rc (exit code), $FIX/size.out (stdout).
cat > "$TMP/bin/atelier-pr-size-check" << 'SHIMEOF'
#!/usr/bin/env bash
cat "$FIX/size.out" 2>/dev/null
exit "$(cat "$FIX/size.rc" 2>/dev/null || echo 2)"
SHIMEOF
chmod +x "$TMP/bin/atelier-pr-size-check"
# size <rc> <lines> <files>
size() { printf '%s\n' "$1" > "$FIX/size.rc"; printf 'Counted:     %s line(s) across %s file(s)\n' "$2" "$3" > "$FIX/size.out"; }

# Record writer + MAC come from the library itself; the key lives under the test config dir.
# shellcheck source=/dev/null
source "$ROOT/hooks/lib/size-waiver-record.sh"
CONSENT="$TMP/cfg/state/consent"
KEY="$CONSENT/size-waiver.key"
REC="$(swr_record_path o/r 7)"
P="$TMP/proj"; mkdir -p "$P"
SID=sess-1; TS=2026-10-20T09:00:00Z
clear_recs() { rm -f "$CONSENT"/size-waivers/* "$CONSENT"/size-waivers/.tmp.* 2>/dev/null; rmdir "$CONSENT/size-waivers" 2>/dev/null; return 0; }
# rec <sha> <lines> <files> : write a signed record for o/r#7 at the canonical path
rec() { clear_recs; swr_write o/r 7 "$1" "$2" "$3" "Q?" "Yes, waive the size limit" "$SID" "$TS"; }
# foreign <repo> <pr> : signed record for another PR/repo, copied onto o/r#7's canonical path
foreign() {
  clear_recs; swr_write "$1" "$2" "$H" 300 12 "Q?" "Yes, waive the size limit" "$SID" "$TS"
  cp "$(swr_record_path "$1" "$2")" "$TMP/foreign.json"; clear_recs
  mkdir -p "${REC%/*}"; mv "$TMP/foreign.json" "$REC"
}
SELOK="waiver=valid kind=size source=selector sha=$H by=$SID at=$TS review=selector reason=Yes, waive the size limit"
selexpect() { # label out rc [args...]
  local label="$1" want="$2" rc="$3"; shift 3
  run "$@"
  if [ "$OUT" = "$want" ] && [ "$RC" = "$rc" ]; then pass "$label"; else fail "$label — got '$OUT' rc=$RC, want '$want' rc=$rc"; fi
}
SEL=(o/r 7 --project "$P")

setup author "[]"; size 1 300 12
rec "$H" 300 12
[ -s "$KEY" ] && pass "test key created by the library writer" || fail "test key missing"
selexpect "selector: matching head and size -> valid" "$SELOK" 0 "${SEL[@]}"
selexpect "selector: --project in any position" "$SELOK" 0 --project "$P" o/r 7
size 1 100 5
selexpect "selector: smaller counted size -> valid" "$SELOK" 0 "${SEL[@]}"
size 1 300 12
selexpect "selector: exactly equal counted size -> valid" "$SELOK" 0 "${SEL[@]}"

selexpect "selector: no --project -> record ignored (none)" "waiver=none source=review" 1 o/r 7

rec "$OLD" 300 12
selexpect "selector: record on a different head -> stale" "waiver=stale sha=$OLD source=selector" 1 "${SEL[@]}"

rec "$H" 300 12
size 1 301 12
selexpect "selector: counted lines larger -> stale (size grew)" \
  "waiver=stale sha=$H source=selector (size grew: counted 301L/12F > recorded 300L/12F)" 1 "${SEL[@]}"
size 1 300 13
selexpect "selector: counted files larger -> stale (size grew)" \
  "waiver=stale sha=$H source=selector (size grew: counted 300L/13F > recorded 300L/12F)" 1 "${SEL[@]}"
size 1 300 12

jq '.hmac="0000000000000000000000000000000000000000000000000000000000000000"' "$REC" > "$REC.t" && mv "$REC.t" "$REC"
selexpect "selector: bad MAC -> untrusted" "waiver=untrusted by=selector (MAC does not verify) source=selector" 1 "${SEL[@]}"

rec "$H" 300 12
jq 'del(.hmac)' "$REC" > "$REC.t" && mv "$REC.t" "$REC"
selexpect "selector: missing MAC -> untrusted" "waiver=untrusted by=selector (record has no MAC) source=selector" 1 "${SEL[@]}"

rec "$H" 300 12
jq '.lines=9999' "$REC" > "$REC.t" && mv "$REC.t" "$REC"
selexpect "selector: tampered field (MAC no longer matches) -> untrusted" \
  "waiver=untrusted by=selector (MAC does not verify) source=selector" 1 "${SEL[@]}"

rec "$H" 300 12
mv "$KEY" "$KEY.bak"
selexpect "selector: missing key -> untrusted" "waiver=untrusted by=selector (signing key missing) source=selector" 1 "${SEL[@]}"
[ ! -e "$KEY" ] && pass "selector: helper never creates the key" || fail "helper created the signing key"
mv "$KEY.bak" "$KEY"

rec "$H" 300 12
printf 'not json' > "$REC"
selexpect "selector: malformed JSON -> untrusted" "waiver=untrusted by=selector (malformed record) source=selector" 1 "${SEL[@]}"

foreign o/r 8
selexpect "selector: record for another PR at this path -> untrusted" \
  "waiver=untrusted by=selector (record repo/PR mismatch) source=selector" 1 "${SEL[@]}"
foreign other/r 7
selexpect "selector: record for another repo at this path -> untrusted" \
  "waiver=untrusted by=selector (record repo/PR mismatch) source=selector" 1 "${SEL[@]}"

# Non-canonical location: a valid record elsewhere is never read.
rec "$H" 300 12
mkdir -p "$TMP/elsewhere"; mv "$REC" "$TMP/elsewhere/o__r__7.json"
cp "$TMP/elsewhere/o__r__7.json" "$P/o__r__7.json"
selexpect "selector: valid record at a non-canonical path -> none" "waiver=none source=review" 1 "${SEL[@]}"

# Symlink at the canonical path, pointing at a valid record.
mkdir -p "${REC%/*}"; ln -s "$TMP/elsewhere/o__r__7.json" "$REC"
selexpect "selector: symlink at canonical path -> untrusted" \
  "waiver=untrusted by=selector (record is not a regular file) source=selector" 1 "${SEL[@]}"

# A waiver-shaped decisions.jsonl entry alone grants nothing.
clear_recs
printf '%s\n' '{"repo":"o/r","pr":7,"head_sha":"'"$H"'","answer":"Yes, waive the size limit","kind":"size-waiver"}' > "$CONSENT/decisions.jsonl"
selexpect "selector: waiver-shaped decisions.jsonl entry only -> none" "waiver=none source=review" 1 "${SEL[@]}"
rm -f "$CONSENT/decisions.jsonl"

# size-check failure is never waivable.
rec "$H" 300 12
size 2 300 12
run "${SEL[@]}"
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "selector: size-check exit 2 -> helper exit 2"; else fail "size-check exit 2 — got '$OUT' rc=$RC"; fi
printf 'garbage\n' > "$FIX/size.out"; printf '1\n' > "$FIX/size.rc"
run "${SEL[@]}"
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "selector: unparsable size-check output -> helper exit 2"; else fail "unparsable size — got '$OUT' rc=$RC"; fi
size 1 300 12

# protected-paths never reads selector records, even with --project.
run --kind protected-paths o/r 7 --project "$P"
if [ "$OUT" = "waiver=none source=review" ] && [ "$RC" = 1 ]; then pass "protected-paths: valid size record + --project -> none"; else fail "protected-paths with record — got '$OUT' rc=$RC"; fi

# A valid review waiver wins, with source=review (size-check is not even needed).
setup author "[$(review alice COMMENTED $H $T1 'size waiver: ok')]"
perm alice admin admin
size 2 1 1
selexpect "review waiver wins over a valid record -> source=review" \
  "waiver=valid kind=size source=review sha=$H by=alice at=$T1 review=$URL reason=ok" 0 "${SEL[@]}"

# A rejected review (untrusted) falls through to the selector record.
setup author "[$(review bob COMMENTED $H $T1 'size waiver: please')]"
perm bob write write
size 1 300 12
selexpect "untrusted review + valid record -> valid via selector" "$SELOK" 0 "${SEL[@]}"
clear_recs
selexpect "untrusted review + no record -> review result is reported" \
  "waiver=untrusted by=bob (lacks admin/maintain permission) source=review" 1 "${SEL[@]}"

echo "== --question (#736) =="
setup author "[]"
size 1 450 15
run --question o/r 7 --project "$P"
MARK="[atelier size-waiver o/r#7 @$H 450L/15F]"
if [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | jq -r --arg m "$MARK" '.[0].question | contains($m)' 2>/dev/null)" = true ]; then
  pass "--question oversize -> exit 0, payload carries marker $MARK"
else fail "--question oversize — got '$OUT' rc=$RC"; fi
[ "$(printf '%s' "$OUT" | jq -r '.[0].options[0].label' 2>/dev/null)" = "Yes, waive the size limit" ] \
  && pass "--question payload: first option is the affirmative label" || fail "--question options: $OUT"
[ "$OUT" = "$(swr_question o/r 7 "$H" 450 15 en)" ] && pass "--question payload equals the library's canonical JSON" || fail "--question payload differs from swr_question"

size 0 50 3
run --question o/r 7 --project "$P"
if [ "$RC" = 1 ] && [ "$OUT" = "question=none (within size budget)" ]; then pass "--question within budget -> question=none, exit 1"; else fail "--question within budget — got '$OUT' rc=$RC"; fi
size 2 50 3
run --question o/r 7 --project "$P"
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "--question size-check exit 2 -> exit 2"; else fail "--question size-check error — got '$OUT' rc=$RC"; fi
run --question o/r 7
[ "$RC" = 2 ] && pass "--question without --project -> exit 2" || fail "--question without --project rc=$RC"

echo "== missing library (#736) =="
mkdir -p "$TMP/iso/scripts"; cp "$HELPER" "$TMP/iso/scripts/atelier-size-waiver"
setup author "[]"; size 1 300 12; rec "$H" 300 12
OUT="$(ATELIER_PLUGIN_ROOT="$TMP/nowhere" bash "$TMP/iso/scripts/atelier-size-waiver" o/r 7 --project "$P" 2>"$TMP/err")"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q 'library not found' "$TMP/err"; then pass "missing library -> selector path exit 2 with stderr reason"; else fail "missing library — got '$OUT' rc=$RC"; fi
OUT="$(ATELIER_PLUGIN_ROOT="$TMP/nowhere" bash "$TMP/iso/scripts/atelier-size-waiver" --question o/r 7 --project "$P" 2>/dev/null)"; RC=$?
if [ "$RC" = 2 ] && [ -z "$OUT" ]; then pass "missing library -> --question exit 2"; else fail "missing library --question rc=$RC out='$OUT'"; fi
OUT="$(ATELIER_PLUGIN_ROOT="$TMP/nowhere" bash "$TMP/iso/scripts/atelier-size-waiver" o/r 7 2>/dev/null)"; RC=$?
if [ "$RC" = 1 ] && [ "$OUT" = "waiver=none source=review" ]; then pass "missing library without --project: review path unaffected"; else fail "missing library, no project — got '$OUT' rc=$RC"; fi


echo
echo "Results: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
