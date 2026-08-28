#!/usr/bin/env bash
#
# Tests for cached backlog discovery on a `github-project` board.
#
# The problem: every /atelier:next-task did a full paginated sweep of the board
# (`listTasks("roadmap")`, contractually obliged to exhaust pagination) plus a
# `node(id:)` GraphQL round-trip PER CANDIDATE just to learn whether the item
# wrapped an Issue or a DraftIssue. GraphQL is charged per node requested, not
# per request: this project's 592-item board measured 607 points for one sweep
# against a 5,000/hour budget shared by every session and subagent. 594 of its
# 596 items are DraftIssues, so the per-candidate round-trip was wasted almost
# every time.
#
# scripts/atelier-project-cache (#372) already fetched the board once and
# served it from disk -- but nothing wired discovery to it. This covers the
# wiring plus the guards that make a cached shortlist safe to act on:
#
#   * meta.json carries a schemaVersion and a completeness flag, and a snapshot
#     failing either is a cache MISS, never a partial read.
#   * `backlog` filters to the roadmap bucket in one place (three consumers
#     otherwise re-derive the snake_case/camelCase stateMap translation) and
#     carries `type`, which is the datum the per-candidate round-trip fetched.
#   * atelier-refresh-mirror gates on a computed per-project TTL instead of a
#     single global calendar-day stamp -- a date cannot express an interval,
#     and one global stamp let one project's refresh silence six others.
#
# Hermetic: synthetic .roadmap.json + $ATELIER_PROJECT_CACHE_FIXTURE, so no
# `gh` call and no network. Mirrors hooks/tests/project-cache.test.sh.
#
# Run:  hooks/tests/mirror-cache-discovery.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PC="$REPO_ROOT/scripts/atelier-project-cache"
RM="$REPO_ROOT/scripts/atelier-refresh-mirror"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { printf '  SKIP: jq not available\n'; exit 0; }

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

export ATELIER_CONFIG_DIR="$TMP/cfg"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
mkdir -p "$ATELIER_CONFIG_DIR"

# A board carrying both content types and three distinct Status values, so the
# bucket filter has something to exclude and `type` has both answers present.
FIXTURE="$TMP/items.json"
cat > "$FIXTURE" <<'JSON'
{ "items": [
  { "id": "PVTI_a", "atelier ID": "#10", "title": "#10 draft in the backlog", "status": "Todo",
    "ready": "Ready", "priority": "P1",
    "content": { "id": "DI_a", "type": "DraftIssue", "body": "ten" } },
  { "id": "PVTI_b", "atelier ID": "#11", "title": "#11 issue-backed in the backlog", "status": "Todo",
    "content": { "id": "I_b", "type": "Issue", "body": "eleven" } },
  { "id": "PVTI_c", "atelier ID": "#12", "title": "#12 in flight", "status": "In Progress",
    "content": { "id": "DI_c", "type": "DraftIssue", "body": "twelve" } },
  { "id": "PVTI_d", "atelier ID": "#13", "title": "#13 shipped", "status": "Done",
    "content": { "id": "DI_d", "type": "DraftIssue", "body": "thirteen" } }
] }
JSON

mkproj() {  # $1 = dir, $2... = optional stateMap.roadmap JSON array
  local d="$1" roadmap="${2:-}"
  mkdir -p "$d"
  if [ -n "$roadmap" ]; then
    cat > "$d/.roadmap.json" <<JSON
{ "backend": "github-project", "offlineMirror": true,
  "githubProject": { "owner": "AcmeOrg", "projectNumber": 7,
    "stateMap": { "roadmap": $roadmap, "inProgress": ["In Progress"], "history": ["Done"] } } }
JSON
  else
    cat > "$d/.roadmap.json" <<JSON
{ "backend": "github-project", "offlineMirror": true,
  "githubProject": { "owner": "AcmeOrg", "projectNumber": 7 } }
JSON
  fi
}

CACHE_DIR="$ATELIER_CONFIG_DIR/cache/project-AcmeOrg-7"
META="$CACHE_DIR/meta.json"

# ===========================================================================
# 1. meta.json carries the trust-boundary fields.
# ===========================================================================
PROJ="$TMP/p1"; mkproj "$PROJ" '["Todo"]'
ATELIER_PROJECT_CACHE_FIXTURE="$FIXTURE" "$PC" refresh "$PROJ" >/dev/null 2>&1

if [ "$(jq -r '.schemaVersion // "absent"' "$META")" = "1" ]; then
  pass "meta.json records a schemaVersion"
else
  fail "meta.json has no schemaVersion (a reader cannot tell a v1 cache from a future v2)"
fi

if [ "$(jq -r '.complete' "$META")" = "true" ]; then
  pass "a full listing is recorded as complete"
else
  fail "a full listing was not recorded as complete"
fi

# ===========================================================================
# 2. An unservable snapshot is a MISS, not a partial read.
# ===========================================================================
# (a) No schemaVersion at all -- the shape every pre-#372-upgrade cache on disk
# is in right now. It must not be served, and must rebuild when allowed to.
jq 'del(.schemaVersion)' "$META" > "$META.t" && mv "$META.t" "$META"
if ! "$PC" backlog "$PROJ" --no-refresh >/dev/null 2>&1; then
  pass "a pre-versioned cache is refused under --no-refresh"
else
  fail "a pre-versioned cache was served as if this version had written it"
fi

if ATELIER_PROJECT_CACHE_FIXTURE="$FIXTURE" "$PC" backlog "$PROJ" >/dev/null 2>&1 \
   && [ "$(jq -r '.schemaVersion' "$META")" = "1" ]; then
  pass "a pre-versioned cache rebuilds on first contact when refresh is allowed"
else
  fail "a pre-versioned cache did not rebuild"
fi

# (b) A schemaVersion this build does not understand.
jq '.schemaVersion = 99' "$META" > "$META.t" && mv "$META.t" "$META"
if ! "$PC" backlog "$PROJ" --no-refresh >/dev/null 2>&1; then
  pass "a future schemaVersion is refused rather than misread"
else
  fail "a cache written by a different schema version was served anyway"
fi

# (c) An incomplete fetch (a listing that hit the --limit ceiling) must never
# be served: a silently short backlog is the failure with no visible symptom.
ATELIER_PROJECT_CACHE_FIXTURE="$FIXTURE" "$PC" refresh "$PROJ" >/dev/null 2>&1
jq '.complete = false' "$META" > "$META.t" && mv "$META.t" "$META"
if ! "$PC" backlog "$PROJ" --no-refresh >/dev/null 2>&1; then
  pass "an incomplete snapshot is refused under --no-refresh"
else
  fail "an incomplete snapshot was served (a truncated backlog reads as the whole board)"
fi

# ===========================================================================
# 3. `backlog` -- the one place the bucket filter lives.
# ===========================================================================
ATELIER_PROJECT_CACHE_FIXTURE="$FIXTURE" "$PC" refresh "$PROJ" >/dev/null 2>&1
OUT="$("$PC" backlog "$PROJ" --no-refresh 2>/dev/null)"

ids="$(printf '%s' "$OUT" | jq -r '[.items[].id] | sort | join(",")')"
if [ "$ids" = "#10,#11" ]; then
  pass "backlog returns only the roadmap bucket (in-progress and done excluded)"
else
  fail "backlog returned '$ids', expected '#10,#11'"
fi

# The whole point of the change: `type` is on the row, so a consumer never
# issues a node(id:) round-trip per candidate to learn it.
t10="$(printf '%s' "$OUT" | jq -r '.items[] | select(.id=="#10") | .type')"
t11="$(printf '%s' "$OUT" | jq -r '.items[] | select(.id=="#11") | .type')"
if [ "$t10" = "DraftIssue" ] && [ "$t11" = "Issue" ]; then
  pass "backlog rows carry the content type (kills the per-candidate round-trip)"
else
  fail "backlog rows lost the content type: #10='$t10' #11='$t11'"
fi

if [ "$(printf '%s' "$OUT" | jq -r '.items[] | select(.id=="#10") | .ready')" = "Ready" ]; then
  pass "backlog rows carry the Ready field (the planning gate reads it)"
else
  fail "backlog rows lost the Ready field"
fi

# A project that declares no stateMap must still work, on the documented
# defaults -- otherwise every such project silently gets an empty backlog.
PROJ2="$TMP/p2"; mkproj "$PROJ2"
ATELIER_PROJECT_CACHE_FIXTURE="$FIXTURE" "$PC" refresh "$PROJ2" >/dev/null 2>&1
n="$("$PC" backlog "$PROJ2" --no-refresh 2>/dev/null | jq -r '.items | length')"
if [ "$n" = "2" ]; then
  pass "backlog falls back to the default roadmap stateMap when none is declared"
else
  fail "backlog with no declared stateMap returned $n items, expected 2"
fi

# ===========================================================================
# 4. The cache TTL default.
# ===========================================================================
if grep -q 'ATELIER_PROJECT_CACHE_TTL:-3600' "$PC"; then
  pass "cache TTL defaults to 3600s"
else
  fail "cache TTL default is not 3600s (900 refetches ~607 points up to 4x/hour)"
fi

# ===========================================================================
# 5. atelier-refresh-mirror -- computed, per-project TTL.
# ===========================================================================
MPROJ="$TMP/m1"; mkproj "$MPROJ" '["Todo"]'; (cd "$MPROJ" && git init -q .)
NPROJ="$TMP/m2"; mkproj "$NPROJ" '["Todo"]'; (cd "$NPROJ" && git init -q .)

first="$("$RM" "$MPROJ" 2>/dev/null)"
if [ -n "$first" ]; then
  pass "refresh-mirror surfaces the instruction on a cold stamp"
else
  fail "refresh-mirror said nothing on a cold stamp"
fi

second="$("$RM" "$MPROJ" 2>/dev/null)"
if [ -z "$second" ]; then
  pass "refresh-mirror stays silent inside the TTL"
else
  fail "refresh-mirror re-fired inside the TTL"
fi

# The bug the per-project stamp fixes: with one global stamp, refreshing
# project A silenced every other project for the rest of the day.
other="$("$RM" "$NPROJ" 2>/dev/null)"
if [ -n "$other" ]; then
  pass "a second project is not silenced by the first project's stamp"
else
  fail "one project's refresh suppressed another project (global stamp regression)"
fi

third="$(ATELIER_MIRROR_REFRESH_TTL=0 "$RM" "$MPROJ" 2>/dev/null)"
if [ -n "$third" ]; then
  pass "TTL=0 always re-fires"
else
  fail "TTL=0 did not re-fire"
fi

if [ ! -e "$ATELIER_CONFIG_DIR/mirror-refresh-last-check" ]; then
  pass "the global calendar-day stamp is gone"
else
  fail "the global once-per-calendar-day stamp is still being written"
fi

if grep -q 'date +%F' "$RM"; then
  fail "refresh-mirror still derives staleness from a calendar date string"
else
  pass "refresh-mirror computes staleness from an mtime, not a date string"
fi

# GNU-first stat ordering: BSD-first leaks a filesystem block on Linux and
# breaks the arithmetic, which would make the gate permanently open.
if grep -q 'stat -c %Y .* || stat -f %m' "$RM"; then
  pass "refresh-mirror probes GNU stat before BSD stat"
else
  fail "refresh-mirror does not use the GNU-first/BSD-fallback stat ordering"
fi

# ===========================================================================
# 6. The consumers are actually wired to the cache.
# ===========================================================================
NT="$REPO_ROOT/commands/next-task.md"
TD="$REPO_ROOT/skills/task-discovery/SKILL.md"
ST="$REPO_ROOT/commands/status.md"

if grep -q 'atelier-project-cache backlog' "$NT"; then
  pass "/next-task reads the backlog from the cache"
else
  fail "/next-task still sweeps the board for the backlog"
fi

if grep -q 'Bash(atelier-project-cache:\*)' "$NT"; then
  pass "/next-task is permitted to run atelier-project-cache"
else
  fail "/next-task calls atelier-project-cache without allow-listing it (it would prompt or fail)"
fi

if grep -qi 'never served from the cache\|never served from a snapshot' "$NT" "$TD"; then
  pass "the claimed item is documented as an authoritative read"
else
  fail "nothing states the claimed item is re-read fresh -- the guard that makes a cached shortlist safe"
fi

if grep -qi 'force one refresh before concluding\|forces a refresh before concluding' "$NT" "$TD"; then
  pass "the no-eligible-task path forces a refresh before concluding"
else
  fail "a cached empty backlog can report 'no work' without ever re-checking the board"
fi

if grep -q -- '--refresh' "$NT"; then
  pass "/next-task offers --refresh as the manual escape"
else
  fail "/next-task has no manual cache-refresh escape"
fi

if grep -q 'atelier-project-cache backlog' "$TD"; then
  pass "task-discovery reads the backlog from the cache"
else
  fail "task-discovery still sources the backlog from a board sweep"
fi

# The per-candidate round-trip must be described as a field read now. The
# `node(id:` query shape should no longer be prescribed for this purpose.
if grep -q 'node(id: \$id)' "$TD"; then
  fail "task-discovery still prescribes a node(id:) round-trip per candidate"
else
  pass "task-discovery no longer issues a node(id:) round-trip per candidate"
fi

if grep -q 'atelier-project-cache get' "$ST"; then
  pass "/status resolves board items through the cache"
else
  fail "/status resolves board items without the cache"
fi

if [ "$fails" -eq 0 ]; then
  printf 'mirror-cache-discovery: all pass\n'
  exit 0
fi
printf 'mirror-cache-discovery: %d failure(s)\n' "$fails"
exit 1
