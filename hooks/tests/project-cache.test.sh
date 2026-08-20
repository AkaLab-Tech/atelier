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
    "content": { "id": "DI_d", "type": "DraftIssue", "title": "feat trailing id convention #55 ~2h", "body": "d" } }
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
printf '%s' "$out" | grep -q '4 items' && pass "refresh reports the item count" || fail "refresh output: $out"
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

# --- next-id must see BOTH the title-prefix #40 and the trailing #55 ---
n="$(bash "$PC" next-id "$P" --no-refresh 2>&1)"
[ "$n" = "#56" ] && pass "next-id spans prefix and suffix ids (#56)" || fail "next-id returned '$n', expected #56"

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
