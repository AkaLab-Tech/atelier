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
chk_prose "$AM" '`atelier-project-item set-status <id> history`' \
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

# chk_none <file> <fixed-string> <label>  (#800)
# Passes when the fixed string occurs zero times; counts on the file path, no pipe.
chk_none() {
  local file="$1" pattern="$2" label="$3" n
  n="$(grep -cF -e "$pattern" "$file" 2>/dev/null || true)"
  if [ "${n:-0}" = "0" ]; then pass "$label"; else fail "$label — found $n x: $pattern"; fi
}

# #800: Status writes pass stateMap bucket names, never hardcoded board labels.
for f in commands/next-task.md commands/abandon-task.md skills/auto-merge/SKILL.md; do
  chk_none "$REPO_ROOT/$f" 'set-status <id> "In Progress"' "#800: $f has no hardcoded In Progress set-status"
  chk_none "$REPO_ROOT/$f" 'set-status <id> "Todo"' "#800: $f has no hardcoded Todo set-status"
  chk_none "$REPO_ROOT/$f" 'set-status <id> Done' "#800: $f has no hardcoded Done set-status"
done
chk_prose "$REPO_ROOT/commands/next-task.md" 'atelier-project-item set-status <id> inProgress --from roadmap' \
  "#800: next-task claims with the inProgress bucket"
chk_prose "$REPO_ROOT/commands/abandon-task.md" 'atelier-project-item set-status <id> roadmap --from inProgress' \
  "#800: abandon-task fallback uses the roadmap bucket"

# #801: restored closed-without-merge note + operator-rules line width.
NOTE='A PR closed without merging leaves the issue open (correct).'
MAXW=86

# wrap_report <file> <start-marker> <end-marker> <max>
# Prints "NOSTART", "NOEND", or "OK <lines>" plus one "LONG <n>: <head>" line
# per over-long line. Markers are fixed strings anchored at line start; the
# range is [start, end). A missing marker never yields an empty-range pass.
wrap_report() {
  awk -v s="$2" -v e="$3" -v max="$4" '
    index($0, s) == 1 { st = 1; inr = 1; n = 0 }
    inr && st && index($0, e) == 1 { en = 1; inr = 0 }
    inr { n++; if (length($0) > max) printf "LONG %d: %s\n", length($0), substr($0, 1, 60) }
    END { if (!st) print "NOSTART"; else if (!en) print "NOEND"; else print "OK " n }
  ' "$1"
}

# chk_wrap <file> <start> <end> <label>  — passes only when the report has no LONG line and ends OK
chk_wrap() {
  local file="$1" start="$2" end="$3" label="$4" out
  if [ ! -r "$file" ]; then fail "$label — file not readable: $file"; return 0; fi
  out="$(wrap_report "$file" "$start" "$end" "$MAXW")"
  case "$out" in
    LONG\ *|NOSTART*|NOEND*) fail "$label — $(printf '%s' "$out" | tr '\n' ';')" ;;
    OK\ *) pass "$label" ;;
    *) fail "$label — unexpected report: $out" ;;
  esac
}

R1='1. **Subagents never LIST the board.**'
R2='2. **Read through `atelier-project-cache`.**'
R3='3. **Patch the cache row after a write.**'
R4='4. **Rate limit: surface and stop.**'

# Restored note: the github-project bullet itself (single line), not a file-wide count.
am_gp="$(grep -F -e '- **`github-project` backend.**' "$AM" 2>/dev/null || true)"
am_gp_n="$(grep -cF -e '- **`github-project` backend.**' "$AM" 2>/dev/null || true)"
if [ "${am_gp_n:-0}" != "1" ]; then
  fail "#801: auto-merge has exactly one github-project backend bullet (found ${am_gp_n:-0})"
else
  case "$am_gp" in
    *"$NOTE"*) pass "#801: auto-merge github-project bullet carries the closed-without-merge note" ;;
    *) fail "#801: auto-merge github-project bullet lacks: $NOTE" ;;
  esac
fi

chk_wrap "$OR" "$R1" "$R2" "#801: operator-rules rule 1 lines are <= $MAXW chars"
chk_wrap "$OR" "$R3" "$R4" "#801: operator-rules rule 3 lines are <= $MAXW chars"

# Self-test of the wrap check on fixtures: over-long must be flagged, wrapped
# must pass, a missing marker must fail.
w_tmp="$(mktemp -d)"
long_line="$(printf 'x%.0s' $(seq 1 100))"
printf '%s\n' "$R1 start" "   $long_line" "$R2 next" >"$w_tmp/long.md"
printf '%s\n' "$R1 start" "   short wrapped line" "   another short line" "$R2 next" >"$w_tmp/wrapped.md"
printf '%s\n' "$R1 start" "   short" >"$w_tmp/noend.md"
printf '%s\n' "no markers here" >"$w_tmp/nostart.md"
case "$(wrap_report "$w_tmp/long.md" "$R1" "$R2" "$MAXW")" in
  LONG\ *) pass "#801 self-test: over-long rule fixture is flagged" ;;
  *) fail "#801 self-test: over-long rule fixture not flagged" ;;
esac
case "$(wrap_report "$w_tmp/wrapped.md" "$R1" "$R2" "$MAXW")" in
  "OK 3") pass "#801 self-test: wrapped rule fixture passes" ;;
  *) fail "#801 self-test: wrapped rule fixture did not pass" ;;
esac
if [ "$(wrap_report "$w_tmp/noend.md" "$R1" "$R2" "$MAXW")" = "NOEND" ]; then
  pass "#801 self-test: missing end marker fails"
else
  fail "#801 self-test: missing end marker did not fail"
fi
if [ "$(wrap_report "$w_tmp/nostart.md" "$R1" "$R2" "$MAXW")" = "NOSTART" ]; then
  pass "#801 self-test: missing start marker fails"
else
  fail "#801 self-test: missing start marker did not fail"
fi
rm -r "$w_tmp"

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'ALL PASS\n'; exit 0; fi
printf '%s FAILED\n' "$fails"
exit 1
