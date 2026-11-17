#!/usr/bin/env bash
#
# Regression test for #531 — skills and operator rules route single-item
# github-project board reads/writes through `atelier-project-item`.
#
# Asserts, against the committed prose only:
#   Group 1 — no skill / rule instructs `gh project item-list` (a full board
#     listing) to reach one item; the check has a self-test on fixtures
#   Group 2 — task-discovery: getTask / claim verify name `atelier-project-item get`
#   Group 3 — auto-merge: post-merge Done move names `atelier-project-item`
#   Group 4 — operator-rules: corrected costs, single-item helper, write rule,
#     patch-after-write, rate-limit stop
#
# Hermetic: reads files only — no network, no gh calls. Fixed-string `grep` on
# single files (no recursion); no output is piped into a quiet grep.
#
# Run:  hooks/tests/skills-project-item-routing.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TD="$REPO_ROOT/skills/task-discovery/SKILL.md"
AM="$REPO_ROOT/skills/auto-merge/SKILL.md"
OR="$REPO_ROOT/operator-rules.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
chk_prose() {
  local file="$1" pattern="$2" label="$3" n
  n="$(grep -cF -e "$pattern" "$file" 2>/dev/null || true)"
  if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then pass "$label"; else fail "$label — missing: $pattern"; fi
}

# listing_instructions <file>
# Prints each `gh project item-list` mention whose surrounding window (2 lines
# either side; prose is hard-wrapped) carries no prohibition / cost-description
# wording. Such a line is an instruction to list the board.
listing_instructions() {
  local file="$1" ln ctx
  while IFS=: read -r ln _; do
    [ -n "$ln" ] || continue
    ctx="$(sed -n "$((ln > 2 ? ln - 2 : 1)),$((ln + 2))p" "$file")"
    if ! grep -qE '[Nn]ever|must not|[Nn]ot |costs|exact call|no board listing|instead of' <<<"$ctx"; then
      printf '%s:%s\n' "$ln" "$(sed -n "${ln}p" "$file" | cut -c1-120)"
    fi
  done < <(grep -n -F -e 'gh project item-list' "$file" 2>/dev/null || true)
}

chk_no_listing_instructed() {
  local file="$1" label="$2" bad
  if [ ! -r "$file" ]; then fail "$label — file not readable: $file"; return 0; fi
  bad="$(listing_instructions "$file")"
  if [ -z "$bad" ]; then pass "$label"; else fail "$label — instructing line(s): $bad"; fi
}

# ---------------------------------------------------------------------------
# Self-test of the check (fixtures in a temp dir)
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' 'To read the claimed task, run `gh project item-list --format json` and pick it.' > "$TMP/bad.md"
printf '%s\n' 'Read one item with atelier-project-item get <id>;' 'never `gh project item-list` for it.' > "$TMP/good.md"
if [ -n "$(listing_instructions "$TMP/bad.md")" ]; then pass "self-test: instructing fixture is flagged"; else fail "self-test: instructing fixture not flagged"; fi
if [ -z "$(listing_instructions "$TMP/good.md")" ]; then pass "self-test: prohibiting fixture passes"; else fail "self-test: prohibiting fixture wrongly flagged"; fi

# ---------------------------------------------------------------------------
# Group 1 — no single-item listing instructed
# ---------------------------------------------------------------------------
chk_no_listing_instructed "$TD" "task-discovery: no gh project item-list instructed (#531)"
chk_no_listing_instructed "$AM" "auto-merge: no gh project item-list instructed (#531)"
chk_no_listing_instructed "$OR" "operator-rules: no gh project item-list instructed (#531)"
for f in "$REPO_ROOT"/skills/*/SKILL.md; do
  chk_no_listing_instructed "$f" "$(basename "$(dirname "$f")"): no gh project item-list instructed (#531)"
done

# ---------------------------------------------------------------------------
# Group 2 — task-discovery
# ---------------------------------------------------------------------------
chk_prose "$TD" '`getTask(id)` is `atelier-project-item get <id>`' \
  "task-discovery #531: github-project getTask is atelier-project-item get"
chk_prose "$TD" 'on `github-project`: `atelier-project-item get <id>`, never `gh project item-list`' \
  "task-discovery #531: claim verify uses atelier-project-item get, never item-list"
chk_prose "$TD" 'Exit 4 means rate limited' \
  "task-discovery #531: exit 4 rate-limit stop stated"

# ---------------------------------------------------------------------------
# Group 3 — auto-merge
# ---------------------------------------------------------------------------
chk_prose "$AM" '`atelier-project-item get <id>`: if its `status` is already in `stateMap.history`' \
  "auto-merge #531: post-merge step reads status with atelier-project-item get"
chk_prose "$AM" '`atelier-project-item set-status <id> Done`' \
  "auto-merge #531: Done move uses atelier-project-item set-status"
chk_prose "$AM" 'Never list the board for this.' \
  "auto-merge #531: never list the board for the Done move"
chk_prose "$AM" 'Exit 4 (rate limited)' \
  "auto-merge #531: exit 4 rate-limit handling"

# ---------------------------------------------------------------------------
# Group 4 — operator-rules
# ---------------------------------------------------------------------------
chk_prose "$OR" 'one legacy full listing of this' \
  "operator-rules #531: corrected legacy listing cost wording"
chk_prose "$OR" 'about 600 points' \
  "operator-rules #531: legacy listing cost is about 600 points"
chk_prose "$OR" 'roughly 8 listings per hour' \
  "operator-rules #531: roughly 8 listings per hour"
chk_prose "$OR" 'about 1 point per 100 items' \
  "operator-rules #531: paginated refresh cost is about 1 point per 100 items"
chk_prose "$OR" '`atelier-project-item get <id>`, the single-item path' \
  "operator-rules #531: helper named as the single-item path"
chk_prose "$OR" '3. **Patch the cache row after a write.**' \
  "operator-rules #531: rule 3 is patch-after-write"
chk_prose "$OR" '`set-status <id> <label> [--from <bucket>]`' \
  "operator-rules #531: Status write goes through set-status"
chk_prose "$OR" '`set-ready <id> true|false`' \
  "operator-rules #531: Ready write goes through set-ready"
chk_prose "$OR" 'Do not use crt'"'"'s' \
  "operator-rules #531: crt Status/Ready writers disallowed"
chk_prose "$OR" 'atelier-project-cache patch <id>' \
  "operator-rules #531: other writes patch the single cache row"
chk_prose "$OR" 'Never a whole-cache `invalidate` for one item.' \
  "operator-rules #531: no whole-cache invalidate for one item"
chk_prose "$OR" '4. **Rate limit: surface and stop.**' \
  "operator-rules #531: rule 4 is rate-limit stop"
chk_prose "$OR" 'no blind retries' \
  "operator-rules #531: no blind retries"
chk_prose "$OR" 'no REST workaround' \
  "operator-rules #531: no REST workaround"
chk_prose "$OR" 'Four rules, in order of how much they save' \
  "operator-rules #531: four rules heading"

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'ALL PASS\n'; exit 0; fi
printf '%s FAILED\n' "$fails"
exit 1
