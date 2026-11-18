#!/usr/bin/env bash
#
# Test for atelier-project-cache: a read cache over a `github-project` board.
# Hermetic — synthetic .roadmap.json + a fixture item-list payload injected via
# $ATELIER_PROJECT_CACHE_FIXTURE, so no `gh` call and no network.
#
# Run:  hooks/tests/project-cache.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PC="$REPO_ROOT/scripts/atelier-project-cache"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not available\n'; exit 0; }

mkproj() {  # $1 = dir, $2 = backend
  local d="$1" b="${2:-github-project}"
  mkdir -p "$d"
  cat > "$d/.roadmap.json" <<JSON
{ "backend": "$b",
  "offlineMirror": false,
  "githubProject": { "owner": "AcmeOrg", "projectNumber": 7 } }
JSON
}

# A board that reproduces the shapes that matter:
#   #10  id in the Atelier ID field, with a body
#   #40  id ONLY in the title prefix (field empty) — the max, and the trap
#   #10  a second item colliding on #10
mkfixture() {  # $1 = file
  cat > "$1" <<'JSON'
{ "items": [
  { "id": "PVTI_a", "atelier ID": "#10", "title": "#10 First task", "status": "Todo",
    "ready": "ready", "kind": "feat", "priority": "P1", "estimate": "~2h",
    "target Repo": "acme-api",
    "content": { "id": "DI_a", "type": "DraftIssue", "title": "#10 First task",
                 "body": "Body of ten.\nSecond line." } },
  { "id": "PVTI_b", "atelier ID": "", "title": "#40 Untagged but numbered", "status": "Done",
    "content": { "id": "DI_b", "type": "DraftIssue", "title": "#40 Untagged but numbered",
                 "body": "Body of forty." } },
  { "id": "PVTI_c", "atelier ID": "#10", "title": "#10 Colliding duplicate", "status": "Todo",
    "content": { "id": "DI_c", "type": "DraftIssue", "title": "#10 Colliding duplicate", "body": "" } },
  { "id": "PVTI_d", "atelier ID": "", "title": "feat trailing id convention #55 ~2h", "status": "Todo",
    "content": { "id": "DI_d", "type": "DraftIssue", "title": "feat trailing id convention #55 ~2h", "body": "d" } },
  { "id": "PVTI_e", "atelier ID": "", "title": "bug roadmap-tools: Items sin Status #12 ~S audit#900", "status": "Todo",
    "content": { "id": "DI_e", "type": "DraftIssue", "title": "bug roadmap-tools: Items sin Status #12 ~S audit#900", "body": "e" } },
  { "id": "PVTI_f", "atelier ID": 17, "title": "chore number-typed field id", "status": "Todo",
    "content": { "id": "DI_f", "type": "DraftIssue", "title": "chore number-typed field id", "body": "f" } },
  { "id": "PVTI_g", "atelier ID": "", "title": "fix Guardrail #3 rejects SKIPPED conclusion", "status": "Todo",
    "content": { "id": "DI_g", "type": "DraftIssue", "title": "fix Guardrail #3 rejects SKIPPED conclusion", "body": "g" } },
  { "id": "PVTI_h", "atelier ID": "", "title": "bug #44a Generalize the orchestrator, reframe pr-opener ~2h", "status": "Todo",
    "content": { "id": "DI_h", "type": "DraftIssue", "title": "bug #44a Generalize the orchestrator, reframe pr-opener ~2h", "body": "h" } }
] }
JSON
}

T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
export ATELIER_CONFIG_DIR="$T/config"
FIX="$T/fixture.json"; mkfixture "$FIX"
export ATELIER_PROJECT_CACHE_FIXTURE="$FIX"
P="$T/proj"; mkproj "$P"

# --- refresh builds a cache ---
out="$(bash "$PC" refresh "$P" 2>&1)"
printf '%s' "$out" | grep -q '8 items' && pass "refresh reports the item count" || fail "refresh output: $out"
[ -f "$ATELIER_CONFIG_DIR/cache/project-AcmeOrg-7/index.json" ] && pass "index.json written to the config cache dir" || fail "index.json missing"

# --- the index is body-free (that is the whole point of the split) ---
idx="$ATELIER_CONFIG_DIR/cache/project-AcmeOrg-7/index.json"
jq -e '[.items[] | has("body")] | any | not' "$idx" >/dev/null 2>&1 && pass "index carries no bodies" || fail "index leaked a body field"
jq -e '.items[0].bodyBytes == 25' "$idx" >/dev/null 2>&1 && pass "index records bodyBytes instead" || fail "bodyBytes wrong (expected 25): $(jq -c '.items[0].bodyBytes' "$idx")"

# --- id resolution: field, and title fallback ---
jq -e '.items[0].id == "#10"' "$idx" >/dev/null 2>&1 && pass "id read from the Atelier ID field" || fail "field id wrong"
jq -e '.items[1].id == "#40"' "$idx" >/dev/null 2>&1 && pass "id falls back to the #NNN title prefix" || fail "title-prefix id wrong: $(jq -c '.items[1].id' "$idx")"

# --- ids at the END of the title (the convention atelier's own board uses) ---
jq -e '.items[3].id == "#55"' "$idx" >/dev/null 2>&1 && pass "id read from a trailing #NNN token" || fail "trailing id wrong: $(jq -c '.items[3].id' "$idx")"

# --- a #NNN inside a back-reference is NOT this item's id ---
# "…Items sin Status #12 ~S audit#900" is item #12; without a left boundary the
# scan matches inside "audit#900" and (taking the last token) adopts #900.
jq -e '.items[4].id == "#12"' "$idx" >/dev/null 2>&1 && pass "back-reference audit#900 is not mistaken for the id" || fail "back-ref id wrong: $(jq -c '.items[4].id' "$idx")"
jq -e '[ .items[].id ] | index("#900") == null' "$idx" >/dev/null 2>&1 && pass "no item anywhere adopts the back-referenced #900" || fail "#900 leaked as an id"
bash "$PC" get 12 "$P" --no-refresh 2>/dev/null | jq -e '.itemId == "PVTI_e"' >/dev/null 2>&1 && pass "get resolves the back-referencing item by its real id" || fail "get 12 failed"

# --- a bare mention of another item is not an id at all ---
# "fix Guardrail #3 rejects SKIPPED conclusion" has no estimate anchor and no
# leading token, so it must resolve to "" rather than claiming #3. This is the
# shape that produced 130 phantom duplicate groups on a real board.
jq -e '.items[6].id == ""' "$idx" >/dev/null 2>&1 && pass "a mid-title mention resolves to no id" || fail "mention wrongly adopted: $(jq -c '.items[6].id' "$idx")"
jq -e '[ .items[] | select(.id == "#3") ] | length == 0' "$idx" >/dev/null 2>&1 && pass "the mentioned #3 is claimed by nobody" || fail "#3 was adopted"

# --- a kind-prefixed sub-task id: `bug #44a <title> ~2h` ---
# The estimate anchor does not fire here (the id is not adjacent to the ~), and
# neither does the leading anchor (the title starts with the kind word). Without
# a dedicated anchor these resolve to "" and become invisible to get/next-id.
jq -e '.items[7].id == "#44a"' "$idx" >/dev/null 2>&1 && pass "kind-prefixed sub-task id resolves (#44a)" || fail "kind-prefixed id wrong: $(jq -c '.items[7].id' "$idx")"
bash "$PC" get 44a "$P" --no-refresh 2>/dev/null | jq -e '.itemId == "PVTI_h"' >/dev/null 2>&1 && pass "get resolves a letter-suffixed id" || fail "get 44a failed"

# --- a NUMBER-typed, unprefixed Atelier ID must normalise, not crash ---
jq -e '.items[5].id == "#17"' "$idx" >/dev/null 2>&1 && pass "number-typed Atelier ID normalises to #17" || fail "number id wrong: $(jq -c '.items[5].id' "$idx")"

# --- next-id must span prefix (#40) and suffix (#55), and ignore audit#900 ---
n="$(bash "$PC" next-id "$P" --no-refresh 2>&1)"
[ "$n" = "#56" ] && pass "next-id spans prefix and suffix ids, ignoring back-refs (#56)" || fail "next-id returned '$n', expected #56"

# --- a populated board with no §5 ids must refuse to invent one ---
FIX2="$T/fixture-noids.json"
cat > "$FIX2" <<'JSON'
{ "items": [
  { "id": "PVTI_x", "title": "feat something untagged", "status": "Todo",
    "content": { "id": "DI_x", "type": "DraftIssue", "title": "feat something untagged", "body": "b" } }
] }
JSON
P4="$T/proj4"; mkproj "$P4"
sed -i.bak 's/"projectNumber": 7/"projectNumber": 8/' "$P4/.roadmap.json"
ATELIER_PROJECT_CACHE_FIXTURE="$FIX2" bash "$PC" refresh "$P4" >/dev/null 2>&1
ni_out="$(ATELIER_PROJECT_CACHE_FIXTURE="$FIX2" bash "$PC" next-id "$P4" --no-refresh 2>&1)"
ni_rc=$?
[ "$ni_rc" -ne 0 ] && pass "next-id refuses a populated board with no ids" || fail "next-id returned '$ni_out' instead of failing"
printf '%s' "$ni_out" | grep -q 'does not use numeric task ids' && pass "next-id explains why it refused" || fail "next-id message: $ni_out"

# --- duplicates ---
bash "$PC" duplicates "$P" --no-refresh >/dev/null 2>&1
[ "$?" -eq 3 ] && pass "duplicates exits 3 when ids collide" || fail "duplicates should exit 3"
dup_out="$(bash "$PC" duplicates "$P" --no-refresh 2>&1)"
printf '%s' "$dup_out" | grep -q '#10' && pass "duplicates names the colliding id" || fail "duplicates did not name #10"
printf '%s' "$dup_out" | grep -q 'Colliding duplicate' && pass "duplicates lists both colliding titles" || fail "duplicates did not list the second title"

# --- get / body ---
get_out="$(bash "$PC" get 10 "$P" --no-refresh 2>/dev/null)"
printf '%s' "$get_out" | jq -e '.draftId == "DI_a"' >/dev/null 2>&1 \
  && pass "get resolves a bare id and returns the draft id" || fail "get returned: $get_out"
get_err="$(bash "$PC" get 10 "$P" --no-refresh 2>&1 >/dev/null)"
printf '%s' "$get_err" | grep -q 'matches 2 items' \
  && pass "get warns on stderr when the id is ambiguous" || fail "get did not warn: $get_err"
bash "$PC" get 40 "$P" --no-refresh 2>/dev/null | jq -e '.id == "#40"' >/dev/null 2>&1 \
  && pass "get works on a title-derived id" || fail "get #40 failed"
b="$(bash "$PC" body '#40' "$P" --no-refresh 2>&1)"
[ "$b" = "Body of forty." ] && pass "body returns the item body verbatim" || fail "body returned '$b'"
bash "$PC" body 10 "$P" --no-refresh 2>/dev/null | head -1 | grep -q 'Body of ten' && pass "body preserves multi-line content" || fail "multi-line body wrong"

# --- an item with an empty body has no body file ---
bash "$PC" body 999 "$P" --no-refresh >/dev/null 2>&1
[ "$?" -ne 0 ] && pass "body fails for an unknown id" || fail "body should fail for unknown id"

# --- invalidate forces the next read to refetch ---
bash "$PC" invalidate "$P" >/dev/null 2>&1
[ -f "$ATELIER_CONFIG_DIR/cache/project-AcmeOrg-7/.stale" ] && pass "invalidate drops a stale marker" || fail "no stale marker"
# with the marker set and refresh allowed, the fixture is re-read and the marker cleared
bash "$PC" next-id "$P" >/dev/null 2>&1
[ ! -f "$ATELIER_CONFIG_DIR/cache/project-AcmeOrg-7/.stale" ] && pass "a refresh clears the stale marker" || fail "stale marker survived a refresh"

# --- a fresh cache is served without re-reading the source ---
# If is_fresh() were broken (the classic GNU-vs-BSD `stat` ordering bug), this
# read would try to refresh and die on the unreadable fixture instead.
fresh_out="$(ATELIER_PROJECT_CACHE_FIXTURE="$T/does-not-exist.json" bash "$PC" next-id "$P" 2>&1)"
[ "$fresh_out" = "#56" ] && pass "a fresh cache is served without refreshing" || fail "is_fresh broken: got '$fresh_out'"
# and once past the TTL it does refresh (here: fails, proving it tried)
ATELIER_PROJECT_CACHE_TTL=0 ATELIER_PROJECT_CACHE_FIXTURE="$T/does-not-exist.json" bash "$PC" next-id "$P" >/dev/null 2>&1
[ "$?" -ne 0 ] && pass "past the TTL it does attempt a refresh" || fail "TTL=0 did not trigger a refresh"

# --- refresh --no-refresh is contradictory and must be refused ---
bash "$PC" refresh "$P" --no-refresh >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "refresh --no-refresh is refused" || fail "refresh --no-refresh should fail"

# --- an unsafe owner must never reach the rm -rf path ---
P5="$T/proj5"; mkproj "$P5"
cat > "$P5/.roadmap.json" <<'JSON'
{ "backend": "github-project", "githubProject": { "owner": "../../escape", "projectNumber": 1 } }
JSON
esc_out="$(bash "$PC" index "$P5" 2>&1)"
printf '%s' "$esc_out" | grep -q 'unsafe githubProject.owner' && pass "a path-traversing owner is refused" || fail "unsafe owner accepted: $esc_out"

# --- concurrent refreshes must never leave bodies/ missing ---
CDIR="$ATELIER_CONFIG_DIR/cache/project-AcmeOrg-7"
for _ in 1 2 3 4 5 6; do ( bash "$PC" refresh "$P" >/dev/null 2>&1 ) & done
wait
[ -d "$CDIR/bodies" ] && pass "6 concurrent refreshes leave bodies/ present" || fail "bodies/ destroyed by concurrent refresh"
[ -f "$CDIR/bodies/PVTI_a.md" ] && pass "concurrent refreshes leave the body files intact" || fail "body files lost"
ls -d "$CDIR"/.bodies.* >/dev/null 2>&1 && fail "scratch body dirs leaked" || pass "no scratch body dirs left behind"
[ -d "$CDIR/.lock" ] && fail "refresh lock leaked" || pass "the refresh lock is released"

# --- a SIGKILLed holder must not freeze the cache forever ---
# No trap runs on SIGKILL, so .lock survives. A waiter that silently serves the
# cache would make `refresh` report success while fetching nothing, and next-id
# would keep answering from pre-write state.
mkdir -p "$CDIR/.lock"; echo 999999 > "$CDIR/.lock/pid"     # a pid that cannot be alive
kill_out="$(ATELIER_PROJECT_CACHE_FIXTURE="$FIX" bash "$PC" refresh "$P" 2>&1)"
kill_rc=$?
[ "$kill_rc" -eq 0 ] && pass "a lock held by a dead pid is broken, not waited on" || fail "refresh wedged on a dead holder: $kill_out"
printf '%s' "$kill_out" | grep -q 'breaking a stale lock' && pass "breaking a stale lock is announced on stderr" || fail "stale-lock break was silent"
[ -d "$CDIR/.lock" ] && fail "lock survived the refresh" || pass "the broken lock is released again"

# --- an age-expired lock is also stale, even with no pid recorded ---
mkdir -p "$CDIR/.lock"
age_out="$(ATELIER_PROJECT_CACHE_LOCK_MAX_AGE=0 ATELIER_PROJECT_CACHE_FIXTURE="$FIX" bash "$PC" refresh "$P" 2>&1)"
[ "$?" -eq 0 ] && pass "an age-expired lock is broken" || fail "age-expired lock wedged: $age_out"
rm -rf "$CDIR/.lock"

# --- an explicit refresh must never report success without fetching ---
# A live holder that is NOT stale: refresh must fail loudly rather than return 0.
mkdir -p "$CDIR/.lock"; echo $$ > "$CDIR/.lock/pid"          # this test process is alive
live_out="$(ATELIER_PROJECT_CACHE_LOCK_MAX_AGE=9999 ATELIER_PROJECT_CACHE_FIXTURE="$FIX" bash "$PC" refresh "$P" 2>&1)"
live_rc=$?
[ "$live_rc" -ne 0 ] && pass "an explicit refresh fails rather than silently not fetching" || fail "refresh returned 0 without fetching: $live_out"
printf '%s' "$live_out" | grep -q 'not stale' && pass "the refusal names the live lock" || fail "unclear refusal: $live_out"
rm -rf "$CDIR/.lock"

# --- --no-refresh must distinguish a damaged cache from a body-less item ---
ATELIER_PROJECT_CACHE_FIXTURE="$FIX" bash "$PC" refresh "$P" >/dev/null 2>&1
mv "$CDIR/bodies" "$CDIR/bodies.hidden"
dmg_out="$(bash "$PC" body 10 "$P" --no-refresh 2>&1)"
printf '%s' "$dmg_out" | grep -q 'damaged' && pass "--no-refresh reports a damaged cache distinctly" || fail "damaged cache masqueraded as no-body: $dmg_out"
mv "$CDIR/bodies.hidden" "$CDIR/bodies"

# --- a cache whose bodies/ went missing must NOT look fresh ---
rm -rf "$CDIR/bodies"
ATELIER_PROJECT_CACHE_FIXTURE="$FIX" bash "$PC" body 10 "$P" >/dev/null 2>&1
[ "$?" -eq 0 ] && pass "a missing bodies/ self-heals on the next read" || fail "missing bodies/ did not trigger a refresh"

# --- a failed refresh must leave the previous cache intact ---
before_id="$(bash "$PC" next-id "$P" --no-refresh 2>&1)"
ATELIER_PROJECT_CACHE_FIXTURE="$T/does-not-exist.json" bash "$PC" refresh "$P" --force >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "refresh fails loudly when the source is unreadable" || fail "refresh should have failed"
[ -f "$idx" ] && pass "a failed --force refresh does not delete the index" || fail "index destroyed by a failed refresh"
after_id="$(bash "$PC" next-id "$P" --no-refresh 2>&1)"
[ "$after_id" = "$before_id" ] && pass "the surviving cache still answers ($after_id)" || fail "cache changed: $before_id -> $after_id"

# --- --no-refresh with no cache at all must fail rather than hit the network ---
P2="$T/proj2"; mkproj "$P2"
cat > "$P2/.roadmap.json" <<'JSON'
{ "backend": "github-project", "githubProject": { "owner": "Empty", "projectNumber": 1 } }
JSON
bash "$PC" index "$P2" --no-refresh >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "--no-refresh with no cache fails instead of fetching" || fail "--no-refresh should fail"

# --- wrong backend is refused ---
P3="$T/proj3"; mkproj "$P3" files
bash "$PC" index "$P3" >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "refuses a non github-project backend" || fail "should refuse backend=files"

# --- missing .roadmap.json is refused ---
mkdir -p "$T/bare"
bash "$PC" index "$T/bare" >/dev/null 2>&1
[ "$?" -eq 1 ] && pass "refuses a project with no .roadmap.json" || fail "should refuse a bare dir"

# ===========================================================================
# Network path (#528): a `gh` shim on PATH stands in for GitHub. Hermetic: the
# shim answers from files under $SHIM_DIR, logs every call's argv, and never
# touches the network. The fixture env var must be unset so the real
# (paginated) code path runs.
# ===========================================================================
unset ATELIER_PROJECT_CACHE_FIXTURE
SHIM_DIR="$T/shim"; SHIM_BIN="$T/shimbin"; mkdir -p "$SHIM_DIR" "$SHIM_BIN"
cat > "$SHIM_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
# argv -> one line in calls.log, fields joined by '|'.
printf '%s|' "$@" >> "$SHIM_DIR/calls.log"; printf '\n' >> "$SHIM_DIR/calls.log"
if [ "${1:-}" = api ] && [ "${2:-}" = rate_limit ]; then
  cat "$SHIM_DIR/rate_limit.txt" 2>/dev/null; exit 0
fi
if [ -f "$SHIM_DIR/override.http" ]; then
  cat "$SHIM_DIR/override.http"
  [ -f "$SHIM_DIR/override.err" ] && cat "$SHIM_DIR/override.err" >&2
  exit "$(cat "$SHIM_DIR/override.rc" 2>/dev/null || echo 0)"
fi
cursor=first; item=""
for a in "$@"; do
  case "$a" in
    endCursor=*) cursor="${a#endCursor=}" ;;
    itemId=*) item="${a#itemId=}" ;;
  esac
done
if [ -n "$item" ]; then f="$SHIM_DIR/body-$item.http"; else f="$SHIM_DIR/page-$cursor.http"; fi
[ -f "$f" ] || { echo "shim: no canned response for $f" >&2; exit 1; }
cat "$f"
SHIM
chmod +x "$SHIM_BIN/gh"
export SHIM_DIR
export PATH="$SHIM_BIN:$PATH"
export ATELIER_CONFIG_DIR="$T/config-net"

# canned HTTP response: $1 = file, $2 = json body, rest = extra header lines
http200() { local f="$1" j="$2"; shift 2; { printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n'; for h in "$@"; do printf '%s\r\n' "$h"; done; printf '\r\n%s' "$j"; } > "$f"; }
ncalls() { [ -f "$SHIM_DIR/calls.log" ] && wc -l < "$SHIM_DIR/calls.log" | tr -d ' ' || printf 0; }
callsmatching() { local n; n="$(grep -cF -- "$1" "$SHIM_DIR/calls.log" 2>/dev/null)"; printf '%s' "${n:-0}"; }
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

http200 "$SHIM_DIR/page-first.http" '{"data":{"rateLimit":{"cost":1},"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[{"id":"I1","content":{"__typename":"DraftIssue","id":"D1","title":"#101 Alpha"},"st":{"name":"Todo"},"rd":{"name":"ready"},"pr":{"name":"P1"},"es":{"text":"~2h"},"kd":{"name":"feat"},"aid":{"text":"101"},"tr":{"text":"acme-api"}}]}}}}'
http200 "$SHIM_DIR/page-c1.http" '{"data":{"rateLimit":{"cost":1},"node":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"c2"},"nodes":[{"id":"I2","content":{"__typename":"Issue","number":7,"title":"Beta"},"st":{"name":"Done"},"aid":{"text":"#102"}}]}}}}'
http200 "$SHIM_DIR/page-c2.http" '{"data":{"rateLimit":{"cost":1},"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":"c3"},"nodes":[{"id":"I3","content":{"__typename":"DraftIssue","id":"D3","title":"feat gamma #103 ~S"},"st":{"name":"Todo"},"aid":null}]}}}}'
http200 "$SHIM_DIR/body-I1.http" '{"data":{"rateLimit":{"cost":1},"node":{"content":{"body":"Hello body"}}}}'

PN="$T/netproj"; mkdir -p "$PN"
cat > "$PN/.roadmap.json" <<'JSON'
{ "backend": "github-project",
  "githubProject": { "owner": "AcmeOrg", "projectNumber": 9, "projectId": "PVT_xyz" } }
JSON
NDIR="$ATELIER_CONFIG_DIR/cache/project-AcmeOrg-9"
NIDX="$NDIR/index.json"

# --- a 3-page board: exactly 3 paginated calls, cursor chained, no body, no item-list ---
: > "$SHIM_DIR/calls.log"
net_out="$(bash "$PC" refresh "$PN" 2>&1)"; net_rc=$?
[ "$net_rc" -eq 0 ] && pass "paginated refresh succeeds" || fail "paginated refresh rc=$net_rc: $net_out"
[ "$(callsmatching 'api|graphql|')" = 3 ] && [ "$(ncalls)" = 3 ] && pass "a 3-page board costs exactly 3 gh api graphql calls" || fail "expected 3 graphql calls, got $(ncalls): $(cat "$SHIM_DIR/calls.log")"
[ "$(callsmatching 'item-list')" = 0 ] && pass "no item-list call is made" || fail "item-list was called"
[ "$(callsmatching 'first: 100')" = 3 ] && pass "every page asks for first: 100" || fail "first: 100 missing from some page"
[ "$(callsmatching 'projectId=PVT_xyz')" = 3 ] && pass "the project is addressed by the roadmap projectId" || fail "projectId not passed on every page"
[ "$(callsmatching 'itemId=')" = 0 ] && pass "no per-item body is requested during the sweep" || fail "a body was requested in the sweep"
[ "$(callsmatching 'body')" = 0 ] && pass "the sweep query does not select body at all" || fail "sweep query selects body"
l1="$(sed -n 1p "$SHIM_DIR/calls.log")"; l2="$(sed -n 2p "$SHIM_DIR/calls.log")"; l3="$(sed -n 3p "$SHIM_DIR/calls.log")"
has "$l1" 'endCursor=' && fail "page 1 sent a cursor" || pass "page 1 carries no endCursor"
has "$l2" 'endCursor=c1|' && pass "page 2 carries the cursor from page 1 (c1)" || fail "page 2 cursor wrong: $l2"
has "$l3" 'endCursor=c2|' && pass "page 3 carries the cursor from page 2 (c2)" || fail "page 3 cursor wrong: $l3"
jq -e '[.items[].id] == ["#101","#102","#103"]' "$NIDX" >/dev/null 2>&1 && pass "paginated index resolves ids from field, field-with-hash and title" || fail "ids wrong: $(jq -c '[.items[].id]' "$NIDX")"
jq -e '.items[0] | .itemId=="I1" and .draftId=="D1" and .type=="DraftIssue" and .status=="Todo" and .ready=="ready" and .priority=="P1" and .estimate=="~2h" and .kind=="feat" and .repo=="acme-api" and .bodyBytes==null' "$NIDX" >/dev/null 2>&1 && pass "page-1 row carries every aliased field" || fail "row 0 wrong: $(jq -c '.items[0]' "$NIDX")"
jq -e '.items[1] | .type=="Issue" and .status=="Done" and .draftId==null' "$NIDX" >/dev/null 2>&1 && pass "an Issue-backed row has no draft id" || fail "row 1 wrong: $(jq -c '.items[1]' "$NIDX")"
jq -e '[.items[] | has("body")] | any | not' "$NIDX" >/dev/null 2>&1 && pass "paginated index carries no bodies" || fail "body leaked into the paginated index"
jq -e '.schemaVersion==2 and .complete==true and .graphqlPoints==3 and .items==3' "$NDIR/meta.json" >/dev/null 2>&1 && pass "meta records schema 2, complete, 3 graphql points, 3 items" || fail "meta wrong: $(cat "$NDIR/meta.json")"
has "$net_out" '3 items' && has "$net_out" '3 graphql points' && pass "refresh output reports items and points" || fail "refresh output: $net_out"
[ "$(bash "$PC" next-id "$PN" --no-refresh 2>&1)" = "#104" ] && pass "next-id over the paginated index is #104" || fail "next-id wrong"
[ "$(ncalls)" = 3 ] && pass "reads off a fresh cache make no further gh calls" || fail "a fresh read called gh"

# --- by-number addressing when .roadmap.json has no projectId ---
PNN="$T/netproj2"; mkproj "$PNN"
: > "$SHIM_DIR/calls.log"
cp "$SHIM_DIR/page-first.http" "$SHIM_DIR/page-first.keep"
http200 "$SHIM_DIR/page-first.http" '{"data":{"rateLimit":{"cost":2},"repositoryOwner":{"projectV2":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"N1","content":{"__typename":"DraftIssue","id":"DN1","title":"#5 By number"},"st":{"name":"Todo"},"aid":{"text":"5"}}]}}}}}'
bash "$PC" refresh "$PNN" >/dev/null 2>&1
nl1="$(sed -n 1p "$SHIM_DIR/calls.log")"
has "$nl1" 'owner=AcmeOrg|' && has "$nl1" 'number=7|' && ! has "$nl1" 'projectId=' && pass "without a projectId the board is addressed by owner and number" || fail "by-number argv wrong: $nl1"
jq -e '.items[0].id=="#5" and .items[0].itemId=="N1"' "$ATELIER_CONFIG_DIR/cache/project-AcmeOrg-7/index.json" >/dev/null 2>&1 && pass "repositoryOwner.projectV2 payloads index the same way" || fail "by-number index wrong"
has "$nl1" 'repositoryOwner(' && ! has "$nl1" 'organization(' && pass "the by-number query uses repositoryOwner( and not organization(" || fail "by-number query shape wrong: $nl1"

# user-owned board: same repositoryOwner shape, addressed by the user login
PUSR="$T/userproj"; mkdir -p "$PUSR"
cat > "$PUSR/.roadmap.json" <<'JSON'
{ "backend": "github-project", "offlineMirror": false,
  "githubProject": { "owner": "some-user", "projectNumber": 3 } }
JSON
: > "$SHIM_DIR/calls.log"
bash "$PC" refresh "$PUSR" >/dev/null 2>&1; usr_rc=$?
ul1="$(sed -n 1p "$SHIM_DIR/calls.log")"
[ "$usr_rc" -eq 0 ] && has "$ul1" 'owner=some-user|' && has "$ul1" 'number=3|' && pass "a user-owned board refreshes by owner login and number" || fail "user-owned refresh rc=$usr_rc argv: $ul1"
jq -e '.items[0].id=="#5" and .items[0].itemId=="N1"' "$ATELIER_CONFIG_DIR/cache/project-some-user-3/index.json" >/dev/null 2>&1 && pass "a user-owned repositoryOwner.projectV2 payload indexes the same way" || fail "user-owned index wrong"

# repositoryOwner: null -> exit 2, "not found", nothing written for a fresh project
http200 "$SHIM_DIR/page-first.http" '{"data":{"rateLimit":{"cost":1},"repositoryOwner":null}}'
PNUL="$T/nullowner"; mkdir -p "$PNUL"
cat > "$PNUL/.roadmap.json" <<'JSON'
{ "backend": "github-project", "offlineMirror": false,
  "githubProject": { "owner": "ghost-owner", "projectNumber": 4 } }
JSON
nul_out="$(bash "$PC" refresh "$PNUL" 2>&1)"; nul_rc=$?
[ "$nul_rc" -eq 2 ] && has "$nul_out" 'not found' && pass "a null repositoryOwner exits 2 with a not-found message" || fail "null owner rc=$nul_rc: $nul_out"
[ ! -e "$ATELIER_CONFIG_DIR/cache/project-ghost-owner-4/index.json" ] && pass "a null repositoryOwner writes no index for a fresh project" || fail "index written for a null owner"
# same failure against an existing cache leaves it intact
UIDX="$ATELIER_CONFIG_DIR/cache/project-some-user-3/index.json"
ubefore="$(cksum < "$UIDX")"
touch -t 200001010000 "$UIDX"
nul2_out="$(bash "$PC" refresh "$PUSR" 2>&1)"; nul2_rc=$?
[ "$nul2_rc" -eq 2 ] && has "$nul2_out" 'not found' && [ "$(cksum < "$UIDX")" = "$ubefore" ] && jq -e '.items[0].id=="#5"' "$UIDX" >/dev/null 2>&1 && pass "a null repositoryOwner leaves the previous cache intact" || fail "previous cache damaged or wrong rc=$nul2_rc: $nul2_out"
cp "$SHIM_DIR/page-first.keep" "$SHIM_DIR/page-first.http"

# --- body: 1 call on first read, 0 on the second ---
before="$(ncalls)"
b1="$(bash "$PC" body 101 "$PN" 2>&1)"
[ "$b1" = "Hello body" ] && pass "body fetches and returns the item body" || fail "body returned '$b1'"
[ "$(( $(ncalls) - before ))" = 1 ] && pass "first body read makes exactly 1 call" || fail "first body read made $(( $(ncalls) - before )) calls"
bl="$(tail -n1 "$SHIM_DIR/calls.log")"
has "$bl" 'itemId=I1|' && pass "the body call is keyed by the item node id" || fail "body argv: $bl"
[ -f "$NDIR/bodies/I1.md" ] && pass "the body is cached in bodies/<itemId>.md" || fail "body not cached"
before="$(ncalls)"
b2="$(bash "$PC" body 101 "$PN" 2>&1)"
[ "$b2" = "Hello body" ] && [ "$(ncalls)" = "$before" ] && pass "second body read makes 0 calls" || fail "second body read: '$b2', calls $(( $(ncalls) - before ))"
bash "$PC" body 101 "$PN" --no-refresh >/dev/null 2>&1 && pass "a cached body is served under --no-refresh" || fail "--no-refresh refused a cached body"
[ "$(ncalls)" = "$before" ] && pass "a cached body under --no-refresh makes 0 gh calls" || fail "cached --no-refresh read called gh"
# uncached body under --no-refresh: exactly 1 itemId call, no sweep, served and cached
http200 "$SHIM_DIR/body-I2.http" '{"data":{"rateLimit":{"cost":1},"node":{"content":{"body":"Beta body"}}}}'
touch -t 200001010000 "$NIDX"   # index far past its TTL: --no-refresh must still not sweep
before="$(ncalls)"
nb1="$(bash "$PC" body 102 "$PN" --no-refresh 2>&1)"; nb_rc=$?
[ "$nb_rc" -eq 0 ] && [ "$nb1" = "Beta body" ] && pass "--no-refresh serves an uncached body" || fail "--no-refresh uncached body rc=$nb_rc out='$nb1'"
[ "$(( $(ncalls) - before ))" = 1 ] && pass "--no-refresh uncached body makes exactly 1 gh call" || fail "--no-refresh uncached body made $(( $(ncalls) - before )) calls"
nbl="$(tail -n1 "$SHIM_DIR/calls.log")"
has "$nbl" 'api|graphql|' && has "$nbl" 'itemId=I2|' && pass "the --no-refresh body call is a graphql call keyed by itemId" || fail "--no-refresh body argv: $nbl"
[ "$(sed -n "$(( before + 1 )),\$p" "$SHIM_DIR/calls.log" | grep -cF -e 'projectId=' -e 'endCursor=' -e 'first: 100')" = 0 ] && pass "--no-refresh body makes 0 page-sweep calls (stale index)" || fail "--no-refresh swept pages"
[ -f "$NDIR/bodies/I2.md" ] && pass "--no-refresh body is cached in bodies/<itemId>.md" || fail "--no-refresh body not cached"
before="$(ncalls)"
nb2="$(bash "$PC" body 102 "$PN" --no-refresh 2>&1)"
[ "$nb2" = "Beta body" ] && [ "$(ncalls)" = "$before" ] && pass "second --no-refresh body read makes 0 calls" || fail "second --no-refresh read: '$nb2', calls $(( $(ncalls) - before ))"
# missing index under --no-refresh: dies, no sweep, no call
PNM="$T/netproj3"; mkproj "$PNM"; sed -i.bak 's/"projectNumber": 7/"projectNumber": 31/' "$PNM/.roadmap.json"; rm -f "$PNM/.roadmap.json.bak"   # board 31 has no cache
before="$(ncalls)"
bash "$PC" body 5 "$PNM" --no-refresh >/dev/null 2>&1
nm_rc=$?
[ "$nm_rc" -ne 0 ] && [ "$(ncalls)" = "$before" ] && pass "--no-refresh body with no index fails with 0 gh calls" || fail "no-index --no-refresh rc=$nm_rc calls $(( $(ncalls) - before ))"
touch "$NIDX"   # restore a fresh mtime for the tests below

# --- patch: in place, no network ---
before="$(ncalls)"; m0="$(mtime_of "$NIDX")"
pt_out="$(bash "$PC" patch 101 --status "In Progress" --ready notready "$PN" 2>&1)"; pt_rc=$?
[ "$pt_rc" -eq 0 ] && pass "patch succeeds" || fail "patch rc=$pt_rc: $pt_out"
[ "$(ncalls)" = "$before" ] && pass "patch makes no gh call" || fail "patch called gh"
jq -e '.items[0].status=="In Progress" and .items[0].ready=="notready" and .items[0].title=="#101 Alpha"' "$NIDX" >/dev/null 2>&1 && pass "patch updates status and ready on that row only" || fail "patch row wrong: $(jq -c '.items[0]' "$NIDX")"
jq -e '.items[1].status=="Done" and .items[2].status=="Todo"' "$NIDX" >/dev/null 2>&1 && pass "patch leaves the other rows alone" || fail "patch touched other rows"
[ "$(mtime_of "$NIDX")" = "$m0" ] && pass "patch keeps the index mtime (TTL not extended)" || fail "patch moved the index mtime"
bash "$PC" patch 101 --status Done "$PN" >/dev/null 2>&1
jq -e '.items[0].status=="Done" and .items[0].ready=="notready"' "$NIDX" >/dev/null 2>&1 && pass "patch with only --status leaves ready untouched" || fail "partial patch wrong"
bash "$PC" patch 101 "$PN" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass "patch with no field is refused" || fail "patch with no field accepted"
bash "$PC" patch 999 --status Done "$PN" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass "patch of an unknown id is refused" || fail "patch of unknown id accepted"

# --- invalidate <id>: per item ---
before="$(ncalls)"
iv_out="$(bash "$PC" invalidate 101 "$PN" 2>&1)"; iv_rc=$?
[ "$iv_rc" -eq 0 ] && pass "invalidate <id> succeeds" || fail "invalidate <id> rc=$iv_rc: $iv_out"
[ ! -f "$NDIR/bodies/I1.md" ] && pass "invalidate <id> drops that item's cached body" || fail "body survived invalidate <id>"
jq -e '.items[0].stale==true and (.items[1].stale // false)==false and (.items[2].stale // false)==false' "$NIDX" >/dev/null 2>&1 && pass "invalidate <id> flags only that row stale" || fail "stale flags wrong: $(jq -c '[.items[].stale]' "$NIDX")"
[ ! -f "$NDIR/.stale" ] && pass "invalidate <id> does not set the whole-cache marker" || fail "whole-cache marker set by per-item invalidate"
[ "$(ncalls)" = "$before" ] && pass "invalidate <id> makes no gh call" || fail "invalidate <id> called gh"
bash "$PC" patch 101 --status Todo "$PN" >/dev/null 2>&1
jq -e '.items[0] | has("stale") | not' "$NIDX" >/dev/null 2>&1 && pass "patch clears the row's stale flag" || fail "stale flag survived patch"
bash "$PC" invalidate 999 "$PN" >/dev/null 2>&1; [ "$?" -ne 0 ] && pass "invalidate of an unknown id is refused" || fail "invalidate of unknown id accepted"
bash "$PC" invalidate "$PN" >/dev/null 2>&1
[ -f "$NDIR/.stale" ] && pass "bare invalidate still drops the whole-cache marker" || fail "bare invalidate changed"
rm -f "$NDIR/.stale"

# --- a stale row makes the next read refresh (and a refresh clears it) ---
bash "$PC" invalidate 101 "$PN" >/dev/null 2>&1
before="$(ncalls)"
bash "$PC" index "$PN" >/dev/null 2>&1
[ "$(( $(ncalls) - before ))" = 3 ] && pass "a read after invalidate <id> re-sweeps the board (3 pages)" || fail "re-sweep made $(( $(ncalls) - before )) calls"
jq -e '[.items[] | has("stale")] | any | not' "$NIDX" >/dev/null 2>&1 && pass "the re-sweep clears the stale flags" || fail "stale flags survived the re-sweep"

# --- rate limits: stop, exit 4, ONE attempt, no REST work fallback, old cache intact ---
rl_case() {  # $1 label  $2 kind  $3 expect-substring  (override files already written)
  local label="$1" kind="$2" expect="$3" sum_before sum_after before rc err
  sum_before="$(cksum < "$NIDX")"; before="$(ncalls)"
  err="$(bash "$PC" refresh "$PN" --force 2>&1 >/dev/null)"; rc=$?
  [ "$rc" -eq 4 ] && pass "$label: exits 4" || fail "$label: exit $rc: $err"
  has "$err" "rate limit hit ($kind)" && pass "$label: names the kind ($kind)" || fail "$label: kind missing: $err"
  has "$err" "$expect" && pass "$label: prints the wait ($expect)" || fail "$label: wait missing: $err"
  has "$err" 'local)' && pass "$label: prints a local reset time" || fail "$label: no local time: $err"
  has "$err" 'nothing was retried' && pass "$label: says nothing was retried" || fail "$label: no stop notice: $err"
  [ "$(( $(ncalls) - before ))" = 1 ] && pass "$label: exactly one gh attempt" || fail "$label: $(( $(ncalls) - before )) gh calls"
  [ "$(( $(callsmatching 'repos/') + $(callsmatching 'issues') + $(callsmatching 'api|rest') ))" = 0 ] && pass "$label: no REST fallback for the work" || fail "$label: REST call seen"
  sum_after="$(cksum < "$NIDX")"
  [ "$sum_before" = "$sum_after" ] && pass "$label: old cache left intact" || fail "$label: index changed"
  [ -d "$NDIR/.lock" ] && fail "$label: lock leaked" || pass "$label: lock released"
}
rm -f "$SHIM_DIR/override.err" "$SHIM_DIR/rate_limit.txt"

# primary, HTTP 403 with retry-after, text on stderr
printf 'HTTP/2.0 403 Forbidden\r\nretry-after: 60\r\n\r\n{"message":"API rate limit already exceeded for user ID 1."}' > "$SHIM_DIR/override.http"
printf 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)\n' > "$SHIM_DIR/override.err"; echo 1 > "$SHIM_DIR/override.rc"
rl_case "primary (text, retry-after)" primary "retry after 60s"

# primary, GraphQL RATE_LIMITED on HTTP 200, reset from x-ratelimit-reset
future=$(( $(date +%s) + 1200 ))
http200 "$SHIM_DIR/override.http" '{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}],"data":null}' "x-ratelimit-reset: $future"
rm -f "$SHIM_DIR/override.err"; echo 0 > "$SHIM_DIR/override.rc"
rl_case "primary (RATE_LIMITED on 200)" primary "retry after 1"

# primary, reset from data.rateLimit.resetAt
fut_iso="$(date -u -d "@$(( $(date +%s) + 1800 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( $(date +%s) + 1800 ))" +%Y-%m-%dT%H:%M:%SZ)"
http200 "$SHIM_DIR/override.http" "{\"errors\":[{\"type\":\"RATE_LIMITED\",\"message\":\"x\"}],\"data\":{\"rateLimit\":{\"cost\":1,\"resetAt\":\"$fut_iso\"}}}"
rl_case "primary (resetAt)" primary "retry after 1"

# secondary, text on stderr
printf 'HTTP/2.0 403 Forbidden\r\nretry-after: 45\r\n\r\n{"message":"You have exceeded a secondary rate limit."}' > "$SHIM_DIR/override.http"
printf 'gh: You have exceeded a secondary rate limit. Please wait a few minutes (HTTP 403)\n' > "$SHIM_DIR/override.err"; echo 1 > "$SHIM_DIR/override.rc"
rl_case "secondary (text)" secondary "retry after 45s"

# secondary, bare 429 + retry-after with no recognisable text
printf 'HTTP/2.0 429 Too Many Requests\r\nretry-after: 30\r\n\r\n{"message":"slow down"}' > "$SHIM_DIR/override.http"
printf 'gh: slow down (HTTP 429)\n' > "$SHIM_DIR/override.err"; echo 1 > "$SHIM_DIR/override.rc"
rl_case "secondary (429 + retry-after)" secondary "retry after 30s"

# primary with no timing at all: the diagnostic rate_limit read supplies the reset
printf 'HTTP/2.0 403 Forbidden\r\n\r\n{"message":"API rate limit exceeded"}' > "$SHIM_DIR/override.http"
printf 'gh: API rate limit exceeded (HTTP 403)\n' > "$SHIM_DIR/override.err"; echo 1 > "$SHIM_DIR/override.rc"
echo "$(( $(date +%s) + 600 ))" > "$SHIM_DIR/rate_limit.txt"
before="$(ncalls)"
err="$(bash "$PC" refresh "$PN" --force 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 4 ] && { has "$err" 'retry after 5' || has "$err" 'retry after 6'; } && pass "no headers: the reset comes from the diagnostic rate_limit read" || fail "diagnostic reset wrong (rc $rc): $err"
[ "$(( $(ncalls) - before ))" = 2 ] && [ "$(callsmatching 'rate_limit')" = 1 ] && pass "the diagnostic is one extra read, not a retry of the work" || fail "unexpected call count $(( $(ncalls) - before ))"
rm -f "$SHIM_DIR/override.http" "$SHIM_DIR/override.err" "$SHIM_DIR/override.rc" "$SHIM_DIR/rate_limit.txt"

# a rate limit on page 2 must not replace the previous cache with a partial one
cp "$SHIM_DIR/page-c1.http" "$SHIM_DIR/page-c1.keep"
printf 'HTTP/2.0 403 Forbidden\r\nretry-after: 10\r\n\r\n{"message":"API rate limit exceeded"}' > "$SHIM_DIR/page-c1.http"
sum_before="$(cksum < "$NIDX")"; metasum="$(cksum < "$NDIR/meta.json")"; before="$(ncalls)"
err="$(bash "$PC" refresh "$PN" --force 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 4 ] && [ "$(( $(ncalls) - before ))" = 2 ] && pass "a limit on page 2 stops after page 2 (2 calls, exit 4)" || fail "page-2 limit: rc $rc, calls $(( $(ncalls) - before ))"
[ "$sum_before" = "$(cksum < "$NIDX")" ] && [ "$metasum" = "$(cksum < "$NDIR/meta.json")" ] && pass "a mid-sweep limit leaves the old index and meta intact" || fail "partial sweep replaced the cache"
cp "$SHIM_DIR/page-c1.keep" "$SHIM_DIR/page-c1.http"

# a plain failure is exit 2, not 4
printf 'HTTP/2.0 500 Internal Server Error\r\n\r\n{"message":"boom"}' > "$SHIM_DIR/override.http"
printf 'gh: boom (HTTP 500)\n' > "$SHIM_DIR/override.err"; echo 1 > "$SHIM_DIR/override.rc"
bash "$PC" refresh "$PN" --force >/dev/null 2>&1
[ "$?" -eq 2 ] && pass "a non-rate-limit failure exits 2" || fail "plain failure did not exit 2"
rm -f "$SHIM_DIR/override.http" "$SHIM_DIR/override.err" "$SHIM_DIR/override.rc"

# --- user text that merely mentions a rate limit is not a rate limit (HTTP 200, gh exit 0) ---
rlbody="$(printf 'We hit a secondary rate limit, then API rate limit already exceeded, tagged RATE_LIMITED.\nSecond line.')"
rlbody_json="$(jq -cn --arg b "$rlbody" '{data:{rateLimit:{cost:1},node:{content:{body:$b}}}}')"
http200 "$SHIM_DIR/body-I3.http" "$rlbody_json"
rm -f "$NDIR/bodies/I3.md"
rb_out="$(bash "$PC" body 103 "$PN" --no-refresh 2>&1)"; rb_rc=$?
[ "$rb_rc" -eq 0 ] && pass "body on HTTP 200 whose text mentions rate limits exits 0 (not 4)" || fail "body with rate-limit text rc=$rb_rc: $rb_out"
[ "$rb_out" = "$rlbody" ] && pass "that body is printed verbatim" || fail "body not verbatim: $rb_out"
[ "$(cat "$NDIR/bodies/I3.md" 2>/dev/null)" = "$rlbody" ] && pass "that body is cached in bodies/I3.md" || fail "rate-limit-text body not cached"

cp "$SHIM_DIR/page-c2.http" "$SHIM_DIR/page-c2.keep"
http200 "$SHIM_DIR/page-c2.http" '{"data":{"rateLimit":{"cost":1},"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":"c3"},"nodes":[{"id":"I3","content":{"__typename":"DraftIssue","id":"D3","title":"feat #103 secondary rate limit docs"},"st":{"name":"Todo"},"aid":null}]}}}}'
rr_out="$(bash "$PC" refresh "$PN" --force 2>&1)"; rr_rc=$?
[ "$rr_rc" -eq 0 ] && pass "refresh with a title mentioning 'secondary rate limit' exits 0 (not 4)" || fail "refresh with rate-limit title rc=$rr_rc: $rr_out"
jq -e '[.items[].title] | index("feat #103 secondary rate limit docs") != null' "$NIDX" >/dev/null 2>&1 && pass "the index contains the rate-limit-worded title" || fail "title missing: $(jq -c '[.items[].title]' "$NIDX")"
cp "$SHIM_DIR/page-c2.keep" "$SHIM_DIR/page-c2.http"

# --- no scratch files remain (#798): stop, failure and success paths all clean up ---
# TMPDIR points at a fresh directory; after each run it must be empty, and the cache
# dir must hold no .bodies.* scratch dir and no index.json.tmp.
# BSD/macOS mktemp ignores $TMPDIR when called with no template, GNU mktemp honours it.
# This wrapper makes both behave the GNU way so a leaked bare `mktemp` file lands in
# the test's TMPDIR on every platform.
REAL_MKTEMP="$(command -v mktemp)"; MK_BIN="$T/mkbin"; mkdir -p "$MK_BIN"
cat > "$MK_BIN/mktemp" <<SHIM
#!/bin/sh
if [ "\$#" -eq 0 ]; then exec "$REAL_MKTEMP" "\${TMPDIR:-/tmp}/tmp.XXXXXXXXXX"; fi
if [ "\$#" -eq 1 ] && [ "\$1" = "-d" ]; then exec "$REAL_MKTEMP" -d "\${TMPDIR:-/tmp}/tmp.XXXXXXXXXX"; fi
exec "$REAL_MKTEMP" "\$@"
SHIM
chmod +x "$MK_BIN/mktemp"
no_scratch() {  # $1 label  $2 expected rc  $3 actual rc  $4 TMPDIR dir
  local label="$1" want="$2" got="$3" td="$4" left cleft
  [ "$got" -eq "$want" ] && pass "$label: exits $want" || fail "$label: exit $got (wanted $want)"
  left="$(find "$td" -mindepth 1 2>/dev/null)"
  [ -z "$(find "$td" -mindepth 1 -print -quit 2>/dev/null)" ] && pass "$label: no scratch files left in TMPDIR" || fail "$label: left in TMPDIR: $left"
  cleft="$(find "$NDIR" -mindepth 1 \( -name '.bodies.*' -o -name 'index.json.tmp' \) 2>/dev/null)"
  [ -z "$(find "$NDIR" -mindepth 1 \( -name '.bodies.*' -o -name 'index.json.tmp' \) -print -quit 2>/dev/null)" ] && pass "$label: no .bodies.* or index.json.tmp left in the cache dir" || fail "$label: left in cache dir: $cleft"
}
rm -f "$SHIM_DIR/override.http" "$SHIM_DIR/override.err" "$SHIM_DIR/override.rc"

# a) rate limit on page 1
TD="$(mktemp -d)"
printf 'HTTP/2.0 403 Forbidden\r\nretry-after: 60\r\n\r\n{"message":"API rate limit already exceeded for user ID 1."}' > "$SHIM_DIR/override.http"
printf 'gh: API rate limit already exceeded for user ID 1. (HTTP 403)\n' > "$SHIM_DIR/override.err"; echo 1 > "$SHIM_DIR/override.rc"
PATH="$MK_BIN:$PATH" TMPDIR="$TD" bash "$PC" refresh "$PN" --force >/dev/null 2>&1; rc=$?
no_scratch "scratch: page-1 rate limit" 4 "$rc" "$TD"
rm -r "$TD"

# b) rate limit on page 2 (multi-page path, RAW scratch already in use)
TD="$(mktemp -d)"
rm -f "$SHIM_DIR/override.http" "$SHIM_DIR/override.err" "$SHIM_DIR/override.rc"
cp "$SHIM_DIR/page-c1.http" "$SHIM_DIR/page-c1.keep"
printf 'HTTP/2.0 403 Forbidden\r\nretry-after: 10\r\n\r\n{"message":"API rate limit exceeded"}' > "$SHIM_DIR/page-c1.http"
PATH="$MK_BIN:$PATH" TMPDIR="$TD" bash "$PC" refresh "$PN" --force >/dev/null 2>&1; rc=$?
no_scratch "scratch: page-2 rate limit" 4 "$rc" "$TD"
cp "$SHIM_DIR/page-c1.keep" "$SHIM_DIR/page-c1.http"
rm -r "$TD"

# c) plain failure (die, exit 2)
TD="$(mktemp -d)"
printf 'HTTP/2.0 500 Internal Server Error\r\n\r\n{"message":"boom"}' > "$SHIM_DIR/override.http"
printf 'gh: boom (HTTP 500)\n' > "$SHIM_DIR/override.err"; echo 1 > "$SHIM_DIR/override.rc"
PATH="$MK_BIN:$PATH" TMPDIR="$TD" bash "$PC" refresh "$PN" --force >/dev/null 2>&1; rc=$?
no_scratch "scratch: plain failure" 2 "$rc" "$TD"
rm -r "$TD"

# d) body fetch rate-limited (uncached body, --no-refresh so only the body call runs)
TD="$(mktemp -d)"
printf 'HTTP/2.0 403 Forbidden\r\nretry-after: 20\r\n\r\n{"message":"API rate limit exceeded"}' > "$SHIM_DIR/override.http"
printf 'gh: API rate limit exceeded (HTTP 403)\n' > "$SHIM_DIR/override.err"; echo 1 > "$SHIM_DIR/override.rc"
rm -f "$NDIR/bodies/I1.md"
PATH="$MK_BIN:$PATH" TMPDIR="$TD" bash "$PC" body 101 "$PN" --no-refresh >/dev/null 2>&1; rc=$?
no_scratch "scratch: rate-limited body fetch" 4 "$rc" "$TD"
rm -r "$TD"
rm -f "$SHIM_DIR/override.http" "$SHIM_DIR/override.err" "$SHIM_DIR/override.rc"

# e) successful refresh
TD="$(mktemp -d)"
PATH="$MK_BIN:$PATH" TMPDIR="$TD" bash "$PC" refresh "$PN" --force >/dev/null 2>&1; rc=$?
no_scratch "scratch: successful refresh" 0 "$rc" "$TD"
rm -r "$TD"

rm -rf "$T"
if [ "$fails" -eq 0 ]; then printf 'project-cache: all pass\n'; exit 0; fi
printf 'project-cache: %d failure(s)\n' "$fails"; exit 1
