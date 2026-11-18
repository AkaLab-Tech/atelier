#!/usr/bin/env bash
#
# Test for atelier-project-item (#529): targeted single-item reads and writes
# against a `github-project` board. Hermetic — a `gh` shim on PATH answers from
# canned files and logs every call, a stub stands in for atelier-project-cache
# (via $ATELIER_PROJECT_CACHE_BIN), and no real GitHub API is ever reached.
#
# Run:  hooks/tests/project-item.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

# shellcheck disable=SC2015,SC2016 # pass/fail chains and literal GraphQL fragments are intentional
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PI="$REPO_ROOT/scripts/atelier-project-item"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not available\n'; exit 0; }

T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
trap 'rm -r -f "$T"' EXIT
SHIM_DIR="$T/shim"; SHIM_BIN="$T/shimbin"; mkdir -p "$SHIM_DIR" "$SHIM_BIN"
export SHIM_DIR
export ATELIER_CONFIG_DIR="$T/config"
export ATELIER_PROJECT_ITEM_REPO="AcmeOrg/acme"
unset ATELIER_PROJECT_ITEM_FIELDS_TTL

# --- gh shim: logs argv, classifies graphql by query text, answers from files ---
cat > "$SHIM_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s|' "$@" >> "$SHIM_DIR/calls.log"; printf '\n' >> "$SHIM_DIR/calls.log"
if [ "${1:-}" = api ] && [ "${2:-}" = rate_limit ]; then exit 1; fi
if [ "${1:-}" = project ] && [ "${2:-}" = item-edit ]; then
  if [ -f "$SHIM_DIR/edit.err" ]; then cat "$SHIM_DIR/edit.err" >&2; exit 1; fi
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = graphql ]; then
  if [ -f "$SHIM_DIR/override.http" ]; then
    cat "$SHIM_DIR/override.http"
    [ -f "$SHIM_DIR/override.err" ] && cat "$SHIM_DIR/override.err" >&2
    exit "$(cat "$SHIM_DIR/override.rc" 2>/dev/null || echo 0)"
  fi
  q=""
  for a in "$@"; do case "$a" in query=*) q="$a" ;; esac; done
  case "$q" in
    *'repository(owner'*) k=issue ;;
    *'node(id: $itemId'*) k=node ;;
    *'node(id: $pid'*) k=projnode ;;
    *) k=fields ;;
  esac
  [ -f "$SHIM_DIR/resp-$k.http" ] || { echo "shim: no canned response for $k" >&2; exit 1; }
  cat "$SHIM_DIR/resp-$k.http"; exit "$(cat "$SHIM_DIR/resp-$k.rc" 2>/dev/null || echo 0)"
fi
echo "shim: unexpected gh call: $*" >&2; exit 1
SHIM
chmod +x "$SHIM_BIN/gh"
export PATH="$SHIM_BIN:$PATH"

# --- cache stub: `get` answers from cache-row, `patch` is logged ---
CACHE_STUB="$T/cache-stub"
cat > "$CACHE_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s|' "$@" >> "$SHIM_DIR/cache.log"; printf '\n' >> "$SHIM_DIR/cache.log"
case "${1:-}" in
  get) [ -f "$SHIM_DIR/cache-row" ] && { cat "$SHIM_DIR/cache-row"; exit 0; }; exit 1 ;;
  patch) exit 0 ;;
esac
exit 1
STUB
chmod +x "$CACHE_STUB"
export ATELIER_PROJECT_CACHE_BIN="$CACHE_STUB"

P="$T/proj"; mkdir -p "$P"
cat > "$P/.roadmap.json" <<'JSON'
{ "backend": "github-project",
  "githubProject": { "owner": "AcmeOrg", "projectNumber": 7,
    "stateMap": { "roadmap": ["Todo"], "inProgress": ["In Progress"], "history": ["Done"] } } }
JSON

http200() { local f="$1" j="$2"; shift 2; { printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n'; for h in "$@"; do printf '%s\r\n' "$h"; done; printf '\r\n%s' "$j"; } > "$f"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
# count log lines containing a fixed string (never pipes into grep -q)
cnt() { local f="$1" n; shift; n="$(grep -cF -- "$1" "$f" 2>/dev/null)"; printf '%s' "${n:-0}"; }
gh_total() { [ -f "$SHIM_DIR/calls.log" ] && wc -l < "$SHIM_DIR/calls.log" | tr -d ' ' || printf 0; }
reset() { rm -f "$SHIM_DIR"/calls.log "$SHIM_DIR"/cache.log "$SHIM_DIR"/override.* "$SHIM_DIR"/resp-*.rc "$SHIM_DIR"/edit.err "$SHIM_DIR"/cache-row; rm -r -f "$ATELIER_CONFIG_DIR"; }
LOG="$SHIM_DIR/calls.log"; CLOG="$SHIM_DIR/cache.log"

# canned responses
http200 "$SHIM_DIR/resp-issue.http" '{"data":{"repository":{"issue":{"body":"Plan body.\nA secondary rate limit is mentioned here.","projectItems":{"nodes":[
 {"project":{"number":99},"id":"PVTI_other","content":{"__typename":"Issue","number":12},"st":{"name":"Done"},"rd":null,"pr":null,"es":null},
 {"project":{"number":7},"id":"PVTI_i12","content":{"__typename":"Issue","number":12},"st":{"name":"Todo"},"rd":{"name":"ready"},"pr":{"name":"P1"},"es":{"text":"~2h"}}]}}}}}'
http200 "$SHIM_DIR/resp-node.http" '{"data":{"node":{"id":"PVTI_d","content":{"__typename":"DraftIssue","body":"Draft plan."},"st":{"name":"In Progress"},"rd":null,"pr":{"name":"P2"},"es":null}}}'
http200 "$SHIM_DIR/resp-fields.http" '{"data":{"node":null,"repositoryOwner":{"projectV2":{"id":"PVT_1","fields":{"nodes":[{},
 {"id":"F_st","name":"Status","options":[{"id":"O_todo","name":"Todo"},{"id":"O_ip","name":"In Progress"},{"id":"O_done","name":"Done"}]},
 {"id":"F_rd","name":"Ready","options":[{"id":"O_ready","name":"ready"}]}]}}}}}'

echo "-- get: issue id --"
reset
out="$(bash "$PI" get 12 "$P" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "get <issue> exits 0" || fail "get <issue> exit $rc: $out"
[ "$(cnt "$LOG" 'api|graphql|')" = 1 ] && pass "get <issue>: exactly 1 api graphql call" || fail "graphql calls: $(cnt "$LOG" 'api|graphql|')"
[ "$(cnt "$LOG" 'item-list')" = 0 ] && pass "get <issue>: 0 project item-list calls" || fail "item-list was called"
[ "$(gh_total)" = 1 ] && pass "get <issue>: 1 gh call in total" || fail "gh calls: $(gh_total)"
exp='{"id":"#12","itemId":"PVTI_i12","contentType":"Issue","issueNumber":12,"status":"Todo","ready":"ready","priority":"P1","estimate":"~2h"}'
[ "$(printf '%s' "$out" | jq -c .)" = "$exp" ] && pass "get <issue>: picks this board's item (project 7, not 99)" || fail "get output: $out"
[ "$(cnt "$LOG" 'owner=AcmeOrg|')" = 1 ] && [ "$(cnt "$LOG" 'name=acme|')" = 1 ] && pass "get <issue>: queries the overridden repo AcmeOrg/acme" || fail "repo args wrong: $(cat "$LOG")"

out="$(bash "$PI" get '#12' "$P" 2>&1)"
[ "$(printf '%s' "$out" | jq -r .id)" = "#12" ] && pass "get accepts a leading #" || fail "get '#12': $out"
out="$(bash "$PI" get zzz "$P" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && has "$out" "not a task id" && pass "get rejects a non-id with exit 1" || fail "bad id: rc=$rc $out"

echo "-- get: draft id --"
reset
printf '%s' '{"id":"#77","itemId":"PVTI_d"}' > "$SHIM_DIR/cache-row"
# the numeric id is probed as an issue first; this repo has no such issue
http200 "$SHIM_DIR/resp-issue.http" '{"data":{"repository":{"issue":null},"rateLimit":{"cost":1}},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to an Issue"}]}'
out="$(bash "$PI" get 77 "$P" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "get <cached draft> exits 0" || fail "get draft exit $rc: $out"
[ "$(cnt "$LOG" 'node(id: $itemId')" = 1 ] && pass "get <cached draft>: exactly 1 node(id:) call" || fail "node calls: $(cnt "$LOG" 'node(id: $itemId')"
[ "$(cnt "$LOG" 'itemId=PVTI_d|')" = 1 ] && pass "get <cached draft>: node read uses the cached itemId" || fail "itemId not passed"
[ "$(cnt "$LOG" 'item-list')" = 0 ] && pass "get <cached draft>: 0 item-list calls" || fail "item-list was called"
[ "$(printf '%s' "$out" | jq -r '[.itemId,.contentType,.status,.priority] | join(",")')" = "PVTI_d,DraftIssue,In Progress,P2" ] && pass "get <cached draft>: normalised row" || fail "draft row: $out"
[ "$(cnt "$CLOG" 'get|#77|')" -ge 1 ] && [ "$(cnt "$CLOG" '--no-refresh')" -ge 1 ] && pass "draft lookup goes through the cache with --no-refresh" || fail "cache log: $(cat "$CLOG" 2>/dev/null)"

reset
http200 "$SHIM_DIR/resp-issue.http" '{"data":{"repository":{"issue":null}},"errors":[{"type":"NOT_FOUND","message":"nf"}]}'
out="$(bash "$PI" get 77 "$P" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "get <uncached draft> fails with exit 1" || fail "uncached draft exit $rc: $out"
has "$out" "atelier-project-cache refresh" && pass "uncached draft: tells the operator to run atelier-project-cache refresh" || fail "no refresh hint: $out"
[ "$(cnt "$LOG" 'item-list')" = 0 ] && [ "$(cnt "$LOG" 'node(id: $itemId')" = 0 ] && pass "uncached draft: no listing and no node read" || fail "unexpected calls: $(cat "$LOG")"

echo "-- stale cached itemId is a cache miss (#799) --"
NF='{"data":{"node":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a node with the global id of '"'PVTI_gone'"'"}]}'
http200 "$SHIM_DIR/resp-issue.http" '{"data":{"repository":{"issue":{"body":"Issue 12 body.","projectItems":{"nodes":[{"project":{"number":7},"id":"PVTI_i12","content":{"__typename":"Issue","number":12},"st":{"name":"Todo"},"rd":{"name":"ready"},"pr":{"name":"P1"},"es":{"text":"~2h"}}]}}}}}'
http200 "$SHIM_DIR/resp-node.http" "$NF"
stale_setup() {  # $1 = cache row
  reset
  printf '%s' "$1" > "$SHIM_DIR/cache-row"
  echo 1 > "$SHIM_DIR/resp-node.rc"
}
stale_setup '{"id":"#12","itemId":"PVTI_gone","type":"Issue"}'
out="$(bash "$PI" get 12 "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r .itemId)" = PVTI_i12 ]; } && pass "stale issue itemId: get falls back to the issue query" || fail "stale issue get rc=$rc: $out"
{ [ "$(cnt "$LOG" 'node(id: $itemId')" = 1 ] && [ "$(cnt "$LOG" 'repository(owner')" = 1 ] && [ "$(cnt "$LOG" 'item-list')" = 0 ] && [ "$(gh_total)" = 2 ]; } && pass "stale issue itemId: 1 node read, 1 issue query, 0 item-list" || fail "stale issue calls: $(cat "$LOG")"

stale_setup '{"id":"#12","itemId":"PVTI_gone","type":"Issue"}'
out="$(bash "$PI" body 12 "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = "Issue 12 body." ]; } && pass "stale issue itemId: body prints the issue body" || fail "stale issue body rc=$rc: $out"

http200 "$SHIM_DIR/resp-issue.http" '{"data":{"repository":{"issue":{"body":"Issue 77 body.","projectItems":{"nodes":[{"project":{"number":7},"id":"PVTI_i77","content":{"__typename":"Issue","number":77},"st":{"name":"Done"},"rd":null,"pr":null,"es":null}]}}}}}'
stale_setup '{"id":"#77","itemId":"PVTI_gone","type":"DraftIssue"}'
out="$(bash "$PI" get 77 "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && has "$out" "atelier-project-cache refresh"; } && pass "stale draft itemId: exits 1 with the refresh hint" || fail "stale draft rc=$rc: $out"
{ [ "$(cnt "$LOG" 'node(id: $itemId')" = 1 ] && [ "$(cnt "$LOG" 'repository(owner')" = 0 ] && [ "$(cnt "$LOG" 'item-list')" = 0 ]; } && pass "stale draft itemId: never resolves to the repo issue (0 issue queries)" || fail "stale draft calls: $(cat "$LOG")"

stale_setup '{"id":"#77a","itemId":"PVTI_gone"}'
out="$(bash "$PI" get 77a "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && has "$out" "atelier-project-cache refresh"; } && pass "stale letter-suffixed id: exits 1 with the refresh hint" || fail "stale suffixed rc=$rc: $out"
{ [ "$(cnt "$LOG" 'repository(owner')" = 0 ] && [ "$(cnt "$LOG" 'item-list')" = 0 ]; } && pass "stale letter-suffixed id: 0 issue queries, 0 item-list" || fail "stale suffixed calls: $(cat "$LOG")"

stale_setup '{"id":"#12","itemId":"PVTI_gone","type":"Issue"}'
http200 "$SHIM_DIR/resp-node.http" '{"data":{"node":null},"errors":[{"type":"FORBIDDEN","message":"Resource not accessible"}]}'
out="$(bash "$PI" get 12 "$P" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "non-NOT_FOUND node error is still fatal (exit 2)" || fail "forbidden rc=$rc: $out"
[ "$(cnt "$LOG" 'repository(owner')" = 0 ] && pass "non-NOT_FOUND node error: no issue query" || fail "forbidden calls: $(cat "$LOG")"
http200 "$SHIM_DIR/resp-node.http" '{"data":{"node":{"id":"PVTI_d","content":{"__typename":"DraftIssue","body":"Draft plan."},"st":{"name":"In Progress"},"rd":null,"pr":{"name":"P2"},"es":null}}}'
rm -f "$SHIM_DIR/resp-node.rc"

echo "-- fields with githubProject.projectId (#799) --"
P2="$T/proj-pid"; mkdir -p "$P2"
cat > "$P2/.roadmap.json" <<'JSON'
{ "backend": "github-project",
  "githubProject": { "owner": "AcmeOrg", "projectNumber": 7, "projectId": "PVT_9",
    "stateMap": { "roadmap": ["Todo"], "inProgress": ["In Progress"], "history": ["Done"] } } }
JSON
http200 "$SHIM_DIR/resp-projnode.http" '{"data":{"node":{"id":"PVT_9","fields":{"nodes":[{},{"id":"F_st","name":"Status","options":[{"id":"O_todo","name":"Todo"}]}]}}}}'
reset
out="$(bash "$PI" fields "$P2" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r .projectId)" = PVT_9 ]; } && pass "fields with projectId prints projectId PVT_9" || fail "fields pid rc=$rc: $out"
{ [ "$(cnt "$LOG" 'node(id: $pid')" = 1 ] && [ "$(cnt "$LOG" 'pid=PVT_9|')" = 1 ] && [ "$(cnt "$LOG" 'repositoryOwner')" = 0 ]; } && pass "fields with projectId: 1 node(id: \$pid) call, 0 repositoryOwner" || fail "fields pid calls: $(cat "$LOG")"
bash "$PI" fields "$P2" >/dev/null 2>&1
[ "$(gh_total)" = 1 ] && pass "second fields within TTL makes 0 extra gh calls" || fail "fields pid refetched: $(gh_total)"

echo "-- body --"
reset
http200 "$SHIM_DIR/resp-issue.http" '{"data":{"repository":{"issue":{"body":"Plan body.\nA secondary rate limit is mentioned here.","projectItems":{"nodes":[{"project":{"number":7},"id":"PVTI_i12","content":{"__typename":"Issue","number":12},"st":{"name":"Todo"},"rd":null,"pr":null,"es":null}]}}}}}'
out="$(bash "$PI" body 12 "$P" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "body exits 0 even when the body text mentions a secondary rate limit (success is not wording-scanned)" || fail "body rc=$rc: $out"
[ "$out" = "$(printf 'Plan body.\nA secondary rate limit is mentioned here.')" ] && pass "body prints the issue body verbatim" || fail "body: $out"
[ "$(gh_total)" = 1 ] && pass "body: one read" || fail "body gh calls: $(gh_total)"

echo "-- fields cache / set-ready --"
reset
printf '%s' '{"id":"#77","itemId":"PVTI_d"}' > "$SHIM_DIR/cache-row"
out="$(bash "$PI" set-ready 77 true "$P" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "set-ready true exits 0" || fail "set-ready exit $rc: $out"
[ "$(cnt "$LOG" 'project|item-edit|')" = 1 ] && pass "set-ready: exactly 1 item-edit call" || fail "item-edit calls: $(cnt "$LOG" 'project|item-edit|')"
[ "$(cnt "$LOG" 'project|item-edit|--id|PVTI_d|--project-id|PVT_1|--field-id|F_rd|--single-select-option-id|O_ready|')" = 1 ] && pass "set-ready true: edits Ready to its option on the cached item" || fail "edit args: $(cat "$LOG")"
[ "$(cnt "$LOG" 'repositoryOwner')" = 1 ] && pass "first set-ready fetches fields once" || fail "fields calls: $(cnt "$LOG" 'repositoryOwner')"
[ "$(cnt "$CLOG" 'patch|#77|--ready|ready|')" = 1 ] && pass "set-ready true patches the cache row (ready)" || fail "cache patch: $(cat "$CLOG")"
out="$(bash "$PI" set-ready 77 false "$P" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "second set-ready (false) exits 0" || fail "set-ready false exit $rc: $out"
[ "$(cnt "$LOG" 'repositoryOwner')" = 1 ] && pass "second call serves fields from the cache (0 extra fields calls)" || fail "fields refetched: $(cnt "$LOG" 'repositoryOwner')"
[ "$(cnt "$LOG" 'project|item-edit|')" = 2 ] && [ "$(cnt "$LOG" '--field-id|F_rd|--clear|')" = 1 ] && pass "set-ready false clears the field with --clear" || fail "clear args: $(cat "$LOG")"
[ "$(cnt "$LOG" 'item-list')" = 0 ] && pass "set-ready never lists the board" || fail "item-list was called"
out="$(bash "$PI" set-ready 77 maybe "$P" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "set-ready rejects a non true/false value" || fail "set-ready maybe rc=$rc: $out"

echo "-- fields subcommand: TTL and --force --"
out="$(bash "$PI" fields "$P" 2>&1)"
[ "$(cnt "$LOG" 'repositoryOwner')" = 1 ] && [ "$(printf '%s' "$out" | jq -r .projectId)" = PVT_1 ] && pass "fields within TTL is served from cache" || fail "fields: $out"
bash "$PI" fields "$P" --force >/dev/null 2>&1
[ "$(cnt "$LOG" 'repositoryOwner')" = 2 ] && pass "fields --force refetches" || fail "--force fields calls: $(cnt "$LOG" 'repositoryOwner')"
ATELIER_PROJECT_ITEM_FIELDS_TTL=0 bash "$PI" fields "$P" >/dev/null 2>&1
[ "$(cnt "$LOG" 'repositoryOwner')" = 3 ] && pass "ATELIER_PROJECT_ITEM_FIELDS_TTL=0 treats the cache as expired" || fail "TTL=0 fields calls: $(cnt "$LOG" 'repositoryOwner')"
[ -f "$ATELIER_CONFIG_DIR/cache/project-AcmeOrg-7/fields.json" ] && pass "fields cache lives under ATELIER_CONFIG_DIR" || fail "fields.json not under config dir"

echo "-- set-status --"
reset
out="$(bash "$PI" set-status 12 inProgress --from history "$P" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "set-status --from refuses with exit 1 when not in the bucket" || fail "refusal rc=$rc: $out"
has "$out" "task-not-in-from-bucket" && pass "refusal names task-not-in-from-bucket" || fail "refusal text: $out"
[ "$(cnt "$LOG" 'project|item-edit|')" = 0 ] && pass "refused move makes 0 item-edit calls" || fail "item-edit ran on refusal"
{ [ ! -f "$CLOG" ] || [ "$(cnt "$CLOG" 'patch|')" = 0 ]; } && pass "refused move does not patch the cache" || fail "patched on refusal"

reset
http200 "$SHIM_DIR/resp-issue.http" '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":7},"id":"PVTI_i12","content":{"__typename":"Issue","number":12},"st":{"name":"Todo"},"rd":null,"pr":null,"es":null}]}}}}}'
out="$(bash "$PI" set-status 12 inProgress --from roadmap "$P" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "set-status --from <matching bucket> succeeds" || fail "set-status rc=$rc: $out"
[ "$(cnt "$LOG" 'project|item-edit|--id|PVTI_i12|--project-id|PVT_1|--field-id|F_st|--single-select-option-id|O_ip|')" = 1 ] && pass "stateMap bucket inProgress resolves to the In Progress option; 1 item-edit" || fail "edit args: $(cat "$LOG")"
[ "$(cnt "$CLOG" 'patch|#12|--status|In Progress|')" = 1 ] && pass "set-status patches the cache row" || fail "cache patch: $(cat "$CLOG" 2>/dev/null)"
out="$(bash "$PI" set-status 12 inProgress --from nonsense "$P" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && has "$out" "unknown --from bucket" && pass "unknown --from bucket is rejected" || fail "unknown bucket rc=$rc: $out"

reset
printf '%s' '{"id":"#77","itemId":"PVTI_d"}' > "$SHIM_DIR/cache-row"
out="$(bash "$PI" set-status 77 Done "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(cnt "$LOG" '--field-id|F_st|--single-select-option-id|O_done|')" = 1 ]; } && pass "set-status by literal option name, draft via cached itemId, no board read" || fail "set-status Done rc=$rc: $out / $(cat "$LOG")"
out="$(bash "$PI" set-status 77 Bogus "$P" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && has "$out" "no option 'Bogus'" && pass "unknown Status option is refused with the option list" || fail "bogus status rc=$rc: $out"

echo "-- id collision: draft #277 vs repo issue #277 (cache-first, identity check) --"
issue_nodes() {  # $1 = JSON of extra keys for the project-7 item (aid / title)
  http200 "$SHIM_DIR/resp-issue.http" '{"data":{"repository":{"issue":{"body":"Issue body.","projectItems":{"nodes":[{"project":{"number":7},"id":"PVTI_i277","content":{"__typename":"Issue","number":277'"$1"'},"st":{"name":"Done"},"rd":null,"pr":null,"es":null'"$2"'}]}}}}}'
}
issue_nodes ',"title":"Some issue"' ''
http200 "$SHIM_DIR/resp-node.http" '{"data":{"node":{"id":"PVTI_d277","content":{"__typename":"DraftIssue","body":"Draft 277 body."},"st":{"name":"Todo"},"rd":null,"pr":null,"es":null}}}'
DROW='{"id":"#277","itemId":"PVTI_d277"}'

reset
printf '%s' "$DROW" > "$SHIM_DIR/cache-row"
out="$(bash "$PI" get 277 "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r '[.itemId,.contentType,.status] | join(",")')" = "PVTI_d277,DraftIssue,Todo" ]; } && pass "collision get: resolves the cached draft, not the issue" || fail "collision get rc=$rc: $out"
[ "$(cnt "$LOG" 'repository(owner')" = 0 ] && [ "$(cnt "$LOG" 'node(id: $itemId')" = 1 ] && [ "$(gh_total)" = 1 ] && pass "collision get: 1 node(id:) read, 0 issue queries" || fail "collision get calls: $(cat "$LOG")"

reset
printf '%s' "$DROW" > "$SHIM_DIR/cache-row"
out="$(bash "$PI" body 277 "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = "Draft 277 body." ]; } && pass "collision body: prints the draft's body, not the issue's" || fail "collision body rc=$rc: $out"
[ "$(cnt "$LOG" 'repository(owner')" = 0 ] && pass "collision body: 0 issue queries" || fail "collision body calls: $(cat "$LOG")"

reset
printf '%s' "$DROW" > "$SHIM_DIR/cache-row"
out="$(bash "$PI" set-status 277 inProgress --from roadmap "$P" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "collision set-status --from roadmap: draft is Todo, so not refused (the issue is Done)" || fail "collision set-status rc=$rc: $out"
[ "$(cnt "$LOG" 'project|item-edit|--id|PVTI_d277|--project-id|PVT_1|--field-id|F_st|--single-select-option-id|O_ip|')" = 1 ] && [ "$(cnt "$LOG" 'PVTI_i277')" = 0 ] && pass "collision set-status: item-edit targets the draft item, never the issue's" || fail "collision edit args: $(cat "$LOG")"
[ "$(cnt "$CLOG" 'patch|#277|--status|In Progress|')" = 1 ] && pass "collision set-status: cache patch targets #277 (same item as the edit)" || fail "collision cache patch: $(cat "$CLOG" 2>/dev/null)"
[ "$(cnt "$LOG" 'repository(owner')" = 0 ] && pass "collision set-status: 0 issue queries" || fail "collision set-status issue queried: $(cat "$LOG")"

reset
printf '%s' "$DROW" > "$SHIM_DIR/cache-row"
out="$(bash "$PI" set-status 277 inProgress --from history "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && has "$out" "task-not-in-from-bucket" && [ "$(cnt "$LOG" 'project|item-edit|')" = 0 ]; } && pass "collision set-status --from history (the issue's bucket): refused, 0 item-edit" || fail "collision history rc=$rc: $out / $(cat "$LOG")"

reset
printf '%s' "$DROW" > "$SHIM_DIR/cache-row"
out="$(bash "$PI" set-ready 277 true "$P" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "collision set-ready exits 0" || fail "collision set-ready rc=$rc: $out"
[ "$(cnt "$LOG" 'project|item-edit|--id|PVTI_d277|')" = 1 ] && [ "$(cnt "$LOG" 'PVTI_i277')" = 0 ] && [ "$(cnt "$LOG" 'repository(owner')" = 0 ] && pass "collision set-ready: edits the draft item, 0 issue queries" || fail "collision set-ready args: $(cat "$LOG")"
[ "$(cnt "$CLOG" 'patch|#277|--ready|ready|')" = 1 ] && pass "collision set-ready: cache patch targets #277" || fail "collision set-ready patch: $(cat "$CLOG" 2>/dev/null)"

echo "-- identity check on the issue path --"
# uncached id; the issue query answers with an item that belongs to a different atelier id
reject_case() {  # $1 label
  local out rc
  out="$(bash "$PI" get 277 "$P" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && pass "$1: get exits 1" || fail "$1: get rc=$rc: $out"
  has "$out" "atelier-project-cache refresh" && pass "$1: tells the operator to run atelier-project-cache refresh" || fail "$1: no refresh hint: $out"
  rm -f "$LOG"
  out="$(bash "$PI" set-ready 277 true "$P" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && pass "$1: set-ready exits 1" || fail "$1: set-ready rc=$rc: $out"
  [ "$(cnt "$LOG" 'project|item-edit|')" = 0 ] && [ "$(cnt "$LOG" 'item-list')" = 0 ] && pass "$1: 0 item-edit, no listing" || fail "$1: unexpected calls: $(cat "$LOG")"
}
reset
issue_nodes '' ',"aid":{"text":"#278"}'
reject_case "issue item with a different Atelier ID field"
reset
issue_nodes ',"title":"#278 other task"' ''
reject_case "issue item with a different #NNN title prefix"
reset
issue_nodes ',"title":"#278 other task"' ',"aid":{"text":"277"}'
out="$(bash "$PI" get 277 "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r .itemId)" = PVTI_i277 ]; } && pass "Atelier ID field wins over a stale title prefix (matching id accepted)" || fail "aid-vs-title rc=$rc: $out"
reset
issue_nodes ',"title":"Plain title, no prefix"' ''
out="$(bash "$PI" get 277 "$P" 2>&1)"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r .itemId)" = PVTI_i277 ]; } && pass "issue item with no Atelier ID and no title prefix is still accepted" || fail "no-identity rc=$rc: $out"
[ "$(cnt "$LOG" 'api|graphql|')" = 1 ] && [ "$(cnt "$LOG" 'item-list')" = 0 ] && pass "uncached issue id: exactly 1 api graphql, 0 item-list" || fail "uncached issue calls: $(cat "$LOG")"

echo "-- rate limits: exit 4, one attempt, never retried --"
rl_case() {  # $1 label  $2 kind  $3 wait-substring ; override files already written
  local label="$1" kind="$2" expect="$3" out rc
  rm -f "$LOG" "$CLOG"
  out="$(bash "$PI" get 12 "$P" 2>&1)"; rc=$?
  [ "$rc" -eq 4 ] && pass "$label: exits 4" || fail "$label: exit $rc: $out"
  has "$out" "rate limit hit ($kind)" && pass "$label: names the kind ($kind)" || fail "$label: kind missing: $out"
  has "$out" "$expect" && pass "$label: prints the reset ($expect)" || fail "$label: wait missing: $out"
  has "$out" "local)" && pass "$label: prints a local reset time" || fail "$label: no local time: $out"
  [ "$(gh_total)" = 1 ] && pass "$label: exactly one gh attempt" || fail "$label: $(gh_total) gh calls"
}
reset
printf 'HTTP/2.0 403 Forbidden\r\nretry-after: 45\r\n\r\n{"message":"You have exceeded a secondary rate limit."}' > "$SHIM_DIR/override.http"
printf 'gh: You have exceeded a secondary rate limit. Please wait a few minutes (HTTP 403)\n' > "$SHIM_DIR/override.err"; echo 1 > "$SHIM_DIR/override.rc"
rl_case "secondary (stderr + retry-after)" secondary "retry after 45s"
future=$(( $(date +%s) + 600 ))
http200 "$SHIM_DIR/override.http" '{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}],"data":null}' "x-ratelimit-reset: $future"
rm -f "$SHIM_DIR/override.err" "$SHIM_DIR/override.rc"
rl_case "primary (RATE_LIMITED on HTTP 200)" primary "retry after "
# a clean 200 whose payload merely mentions the phrase is NOT a stop
http200 "$SHIM_DIR/override.http" '{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":7},"id":"PVTI_x","content":{"__typename":"Issue","number":12,"title":"secondary rate limit"},"st":{"name":"Todo"}}]}}}}}'
rm -f "$LOG"
out="$(bash "$PI" get 12 "$P" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "a successful response mentioning 'secondary rate limit' does not stop" || fail "false positive: rc=$rc $out"
rm -f "$SHIM_DIR"/override.*

# item-edit mutation path
reset
printf '%s' '{"id":"#77","itemId":"PVTI_d"}' > "$SHIM_DIR/cache-row"
printf 'GraphQL: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (updateProjectV2ItemFieldValue)\n' > "$SHIM_DIR/edit.err"
out="$(bash "$PI" set-ready 77 true "$P" 2>&1)"; rc=$?
[ "$rc" -eq 4 ] && pass "item-edit secondary limit: exits 4" || fail "item-edit limit rc=$rc: $out"
{ has "$out" "rate limit hit (secondary)" && has "$out" "nothing was retried"; } && pass "item-edit secondary limit: reports kind and stop" || fail "item-edit limit text: $out"
[ "$(cnt "$LOG" 'project|item-edit|')" = 1 ] && pass "item-edit secondary limit: exactly one attempt" || fail "item-edit attempts: $(cnt "$LOG" 'project|item-edit|')"
[ "$(cnt "$CLOG" 'patch|')" = 0 ] && pass "item-edit secondary limit: cache not patched" || fail "patched after limit"
printf 'boom: something else broke\n' > "$SHIM_DIR/edit.err"
out="$(bash "$PI" set-ready 77 true "$P" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "a non-rate-limit item-edit failure exits 2" || fail "item-edit failure rc=$rc: $out"

echo "-- config guards --"
Q="$T/files-proj"; mkdir -p "$Q"; printf '{"backend":"files"}' > "$Q/.roadmap.json"
out="$(bash "$PI" get 12 "$Q" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && has "$out" "only serves github-project" && pass "non github-project backend is refused" || fail "files backend rc=$rc: $out"

echo "-- install.sh symlinks the helper --"
n="$(grep -cE '^[[:space:]]*_phase_c_1_symlink_helper atelier-project-item$' "$REPO_ROOT/install.sh")"
[ "$n" = 1 ] && pass "install.sh calls _phase_c_1_symlink_helper atelier-project-item" || fail "install.sh symlink line count: $n"
[ -x "$PI" ] && pass "scripts/atelier-project-item is executable" || fail "helper not executable"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
