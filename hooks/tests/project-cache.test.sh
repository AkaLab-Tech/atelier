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
    "content": { "id": "DI_g", "type": "DraftIssue", "title": "fix Guardrail #3 rejects SKIPPED conclusion", "body": "g" } }
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
printf '%s' "$out" | grep -q '7 items' && pass "refresh reports the item count" || fail "refresh output: $out"
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

rm -rf "$T"
if [ "$fails" -eq 0 ]; then printf 'project-cache: all pass\n'; exit 0; fi
printf 'project-cache: %d failure(s)\n' "$fails"; exit 1
