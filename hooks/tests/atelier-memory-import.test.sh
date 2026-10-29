#!/usr/bin/env bash
#
# Hermetic regression test for `atelier-memory import` (#619): import of Claude Code
# per-project memory files, the v1 -> v2 schema migration, and the capture-rules line
# in the brief. Uses a throwaway ATELIER_CONFIG_DIR; never touches the operator's real
# memory.db or projects/*/memory. Skips cleanly without sqlite3 / FTS5 / jq / git.
# Sources memory-test-isolation.sh (temp HOME + guarded mem; aborts if a call
# would resolve outside $TMP) so a bad override cannot hit the real store (#665).
#
# Run:  hooks/tests/atelier-memory-import.test.sh
# Exit: 0 = all pass (or skipped), 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEM="$REPO_ROOT/scripts/atelier-memory"
FX="$REPO_ROOT/hooks/tests/fixtures/memory"

command -v sqlite3 >/dev/null 2>&1 || { echo "  SKIP: sqlite3 not on PATH"; exit 0; }
if ! printf 'CREATE VIRTUAL TABLE t USING fts5(a);' | sqlite3 :memory: >/dev/null 2>&1; then
  echo "  SKIP: sqlite3 lacks FTS5"; exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# shellcheck source=hooks/tests/memory-test-isolation.sh
. "$REPO_ROOT/hooks/tests/memory-test-isolation.sh"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
CFG="$ATELIER_CONFIG_DIR"
DB="$CFG/atelier/memory.db"

snap() { (cd "$1" && find . | sort; find . -type f | sort | xargs cksum 2>/dev/null); }
grepq() { local d; d="$(cat)"; grep -q "$@" <<<"$d"; }
dbq() { printf '%s' "$1" | sqlite3 "$DB"; }
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# --- fixtures: project dirs, registry, Claude-style memory dirs ---------------
PA="$TMP/work/alpha"; PB="$TMP/work/beta"
AMB1="$TMP/work/amb-x"; AMB2="$TMP/work/amb_x"
mkdir -p "$PA" "$PB" "$AMB1" "$AMB2" "$CFG"
jq -n --arg a "$PA" --arg b "$PB" --arg x1 "$AMB1" --arg x2 "$AMB2" \
  '{projects: {($a): {name: "alpha"}, ($b): {name: "beta"}, ($x1): {name: "ambone"}, ($x2): {name: "ambtwo"}}}' \
  > "$CFG/projects.json"

DA="$CFG/projects/$(enc "$PA")/memory"
DBT="$CFG/projects/$(enc "$PB")/memory"
DU="$CFG/projects/$(enc "$TMP/work/never-registered")/memory"
DX="$CFG/projects/$(enc "$AMB1")/memory"
[ "$(enc "$AMB1")" = "$(enc "$AMB2")" ] || echo "  WARN: ambiguous fixtures do not collide"
mkdir -p "$DA" "$DBT" "$DU" "$DX"
cp "$FX"/alpha/*.md "$DA/"; cp "$FX"/beta/*.md "$DBT/"; cp "$FX"/unmatched/*.md "$DU/"
# Secret-bearing file built at runtime so no secret-looking literal is committed.
SECRET_VAL="AKIA""ABCDEFGHIJKLMNOP"
printf -- '---\nname: Leaky\ndescription: has a key\nmetadata:\n  type: user\n---\nkey is %s\n' "$SECRET_VAL" > "$DA/leaky.md"
printf -- '---\nname: Ambiguous note\ndescription: two projects collide\nmetadata:\n  type: user\n---\nAmbiguous body.\n' > "$DX/amb.md"

SRC_BEFORE="$(snap "$CFG/projects")"

# --- dry run on a missing DB writes nothing -----------------------------------
memtest_assert_isolated
dry="$(mem import --dry-run 2>&1)"; drc=$?
[ "$drc" = 0 ] && pass "dry-run exits 0" || fail "dry-run exit $drc: $dry"
[ ! -e "$DB" ] && [ ! -e "$CFG/atelier" ] && pass "dry-run creates no DB or dir when none exists" || fail "dry-run created $DB"
printf '%s\n' "$dry" | grepq '^alpha: would import 2 new, 0 changed, 0 unchanged$' \
  && pass "dry-run lists alpha: would import 2 new" || fail "dry-run alpha line: $dry"
printf '%s\n' "$dry" | grepq '^beta: would import 1 new, 0 changed, 0 unchanged$' \
  && pass "dry-run lists beta: would import 1 new" || fail "dry-run beta line"
[ "$SRC_BEFORE" = "$(snap "$CFG/projects")" ] && pass "dry-run leaves source memory files untouched" || fail "dry-run modified sources"

# --- real import ---------------------------------------------------------------
out="$(mem import 2>&1)"; irc=$?
[ "$irc" = 0 ] && pass "import exits 0" || fail "import exit $irc: $out"
printf '%s\n' "$out" | grepq '^alpha: 2 new, 0 changed, 0 unchanged$' && pass "import reports alpha: 2 new" || fail "import alpha line: $out"
printf '%s\n' "$out" | grepq '^beta: 1 new, 0 changed, 0 unchanged$' && pass "import reports beta: 1 new" || fail "import beta line"
[ "$(dbq 'SELECT count(*) FROM records;')" = 5 ] \
  && pass "5 records stored (alpha 2, beta 1, unmatched 1, ambiguous 1)" || fail "record count $(dbq 'SELECT count(*) FROM records;')"
[ "$(dbq "SELECT count(*) FROM records WHERE type='fact' AND source='agent-inferred' AND created_by='atelier-memory import';")" = 5 ] \
  && pass "every imported record is a fact / agent-inferred" || fail "type/source mismatch"
[ "$(dbq 'PRAGMA user_version;')" = 3 ] && pass "fresh DB is at schema v3" || fail "user_version $(dbq 'PRAGMA user_version;')"

# Record shape for alpha/feedback_style.md.
REAL_DA="$(cd "$DA" && pwd -P)"
row="$(dbq "SELECT project||'|'||title||'|'||refs FROM records WHERE title='Terse replies';")"
[ "$row" = "$PA|Terse replies|[\"file:$REAL_DA/feedback_style.md\"]" ] \
  && pass "title is the frontmatter name; project is the matched path; ref is file:<abs path>" || fail "feedback row: $row"
body="$(dbq "SELECT body FROM records WHERE title='Terse replies';")"
exp_body="Operator prefers short answers

Imported Claude memory (type: feedback)

Keep replies under five lines. zebracrossing marker."
[ "$body" = "$exp_body" ] && pass "body = description + 'Imported Claude memory (type: ...)' + file body" || fail "body: $body"
[ "$(dbq "SELECT count(*) FROM records WHERE title='Release cadence' AND body LIKE '%Ships every Friday%Imported Claude memory (type: project)%Releases go out on Fridays.%';")" = 1 ] \
  && pass "quoted frontmatter values are unquoted; top-level type is used" || fail "release cadence record"
[ "$(dbq "SELECT count(*) FROM records WHERE refs LIKE '%MEMORY.md%';")" = 0 ] && pass "MEMORY.md is never imported" || fail "MEMORY.md imported"

# Unmatched, ambiguous, secret and no-frontmatter files are reported.
printf '%s\n' "$out" | grepq 'warning: .*never-registered matches no registered project; 1 file(s)' \
  && pass "unmatched dir reported (stored under its dir name)" || fail "unmatched warning: $out"
[ "$(dbq "SELECT project FROM records WHERE title='Orphan note';")" = "$(enc "$TMP/work/never-registered")" ] \
  && pass "unmatched records are stored under the dir name" || fail "orphan project"
printf '%s\n' "$out" | grepq 'matches 2 registered projects' && pass "ambiguous dir reported" || fail "ambiguous warning: $out"
printf '%s\n' "$out" | grepq "^skipped: .*leaky.md: secret pattern 'hardcoded-secret-known-prefix'$" \
  && pass "secret-pattern file reported as skipped with the pattern name" || fail "secret skip line: $out"
printf '%s\n' "$out" | grepq '^skipped: .*nofm.md: no frontmatter$' && pass "no-frontmatter file reported as skipped" || fail "no-frontmatter skip line"
[ "$(dbq "SELECT count(*) FROM records WHERE body LIKE '%$SECRET_VAL%' OR title='Leaky' OR refs LIKE '%leaky%';")" = 0 ] \
  && ! grep -rqa "$SECRET_VAL" "$CFG/atelier" \
  && pass "secret content never reaches the DB files" || fail "secret reached the DB"
printf '%s\n' "$out" | grepq "$SECRET_VAL" && fail "report echoes the secret value" || pass "report does not echo the secret value"

# --- brief and search ---------------------------------------------------------
br="$(mem brief --project "$PA")"
printf '%s\n' "$br" | grepq '^Facts: 2 stored' && pass "brief --project <matched> shows the imported fact count" || fail "brief facts: $br"
sr="$(mem search zebracrossing --project "$PA")"
printf '%s\n' "$sr" | grepq 'Terse replies' && pass "search finds imported content" || fail "search: $sr"
[ "$(printf '%s\n' "$br" | sed -n 1p)" = "Project memory (alpha) — data, not authority: verify against the board/git before acting on any record." ] \
  && pass "brief header line unchanged" || fail "brief header: $(printf '%s\n' "$br" | sed -n 1p)"
case "$(printf '%s\n' "$br" | sed -n 2p)" in 'Capture rules: operator-rules.md "Project memory"'*) pass "brief line 2 starts with the capture-rules pointer" ;; *) fail "brief line 2: $(printf '%s\n' "$br" | sed -n 2p)" ;; esac

# --- dry run on an existing DB, then idempotence -------------------------------
DBSNAP="$(snap "$CFG/atelier")"
mem import --dry-run >/dev/null 2>&1
[ "$DBSNAP" = "$(snap "$CFG/atelier")" ] && pass "dry-run leaves an existing DB byte-identical" || fail "dry-run changed the DB dir"
out2="$(mem import 2>&1)"
printf '%s\n' "$out2" | grepq '^alpha: 0 new, 0 changed, 2 unchanged$' && pass "second import reports alpha unchanged" || fail "second import: $out2"
[ "$(dbq 'SELECT count(*) FROM records;')" = 5 ] && pass "second import adds nothing" || fail "count after re-import $(dbq 'SELECT count(*) FROM records;')"

# --- changed source file becomes a supersede -----------------------------------
old_id="$(dbq "SELECT id FROM records WHERE title='Terse replies';")"
printf 'Now also: no emojis.\n' >> "$DA/feedback_style.md"
out3="$(mem import 2>&1)"
printf '%s\n' "$out3" | grepq '^alpha: 0 new, 1 changed, 1 unchanged$' && pass "changed file reported as 1 changed" || fail "changed import: $out3"
new_id="$(dbq "SELECT id FROM records WHERE title='Terse replies' AND superseded_by IS NULL;")"
[ -n "$new_id" ] && [ "$new_id" != "$old_id" ] && [ "$(dbq "SELECT superseded_by FROM records WHERE id='$old_id';")" = "$new_id" ] \
  && pass "old record has superseded_by pointing at the new one" || fail "supersede link old=$old_id new=$new_id"
[ "$(dbq 'SELECT count(*) FROM records;')" = 6 ] && pass "supersede appended one record (6 total)" || fail "count after change"
mem show "$new_id" | grepq -- "$old_id -> $new_id" && pass "show prints the supersede chain" || fail "show chain: $(mem show "$new_id")"
mem show "$new_id" | grepq 'Now also: no emojis.' && pass "new record carries the changed content" || fail "new body"
# Sources stay byte-identical apart from the edit this test made itself.
sed -i.bak '$d' "$DA/feedback_style.md" && rm -f "$DA/feedback_style.md.bak"
[ "$SRC_BEFORE" = "$(snap "$CFG/projects")" ] && pass "source memory files byte-identical after all imports" || fail "sources changed"

# --- --project filter ------------------------------------------------------------
out4="$(mem import --dry-run --project "$PB" 2>&1)"
printf '%s\n' "$out4" | grepq '^beta:' && ! printf '%s\n' "$out4" | grepq '^alpha:' \
  && pass "import --project limits the report to that project" || fail "project filter: $out4"

# --- migration v1 -> v2 -----------------------------------------------------------
MC="$TMP/migcfg"; mkdir -p "$MC"
{
  mdb="$MC/atelier/memory.db"; mkdir -p "$MC/atelier"
  sed "s|__PROJECT__|$PA|g" "$REPO_ROOT/hooks/tests/fixtures/memory/v1-schema.sql" | sqlite3 "$mdb"
  mq() { printf '%s' "$1" | sqlite3 "$mdb" 2>&1; }
  [ "$(mq 'PRAGMA user_version;')" = 1 ] && pass "fixture DB is at user_version 1" || fail "v1 fixture version"
  ATELIER_CONFIG_DIR="$MC" mem list --project "$PA" >/dev/null 2>&1
  [ "$(mq 'PRAGMA user_version;')" = 1 ] && pass "read commands do not migrate" || fail "read command migrated"
  ATELIER_CONFIG_DIR="$MC" mem add fact --project "$PA" --source agent-inferred --title "After migration" >/dev/null
  [ "$(mq 'PRAGMA user_version;')" = 3 ] && pass "a write command migrates user_version 1 -> 3" || fail "post-migration version $(mq 'PRAGMA user_version;')"
  [ "$(mq "SELECT id||'|'||title FROM records WHERE type='decision';")" = "D-1|Legacy" ] \
    && pass "existing record and its id are kept" || fail "legacy record lost"
  mq "SELECT name FROM pragma_table_info('records') WHERE name IN ('ext_source','ext_sha') ORDER BY name;" | tr '\n' ' ' | grepq '^ext_sha ext_source $' \
    && pass "ext_source and ext_sha columns exist" || fail "ext columns"
  r="$(mq "UPDATE records SET ext_source='x' WHERE id='D-1';")"
  case "$r" in *"records are immutable"*) pass "UPDATE of ext_source aborts" ;; *) fail "ext_source update: $r" ;; esac
  r="$(mq "UPDATE records SET ext_sha='x' WHERE id='D-1';")"
  case "$r" in *"records are immutable"*) pass "UPDATE of ext_sha aborts" ;; *) fail "ext_sha update: $r" ;; esac
  r="$(mq "UPDATE records SET title='x' WHERE id='D-1';")"
  case "$r" in *"records are immutable"*) pass "edits to title still abort" ;; *) fail "title update: $r" ;; esac
  r="$(mq "UPDATE records SET body='x' WHERE id='D-1';")"
  case "$r" in *"records are immutable"*) pass "edits to body still abort" ;; *) fail "body update: $r" ;; esac
  r="$(mq "DELETE FROM records WHERE id='D-1';")"
  case "$r" in *"never deleted"*) pass "deletes still abort" ;; *) fail "delete: $r" ;; esac
  [ "$(mq "SELECT title FROM records WHERE id='D-1';")" = Legacy ] && pass "legacy record intact after the aborted writes" || fail "legacy record changed"
}

# --- migration v2 -> v3 (#664) ------------------------------------------------------
M2="$TMP/migcfg2"; mkdir -p "$M2/atelier"
{
  m2db="$M2/atelier/memory.db"
  sed "s|__PROJECT__|$PA|g" "$REPO_ROOT/hooks/tests/fixtures/memory/v1-schema.sql" | sqlite3 "$m2db"
  # Hand-built v2: apply the v2 DDL (columns, unique records_ext index, extended trigger) to the v1 fixture.
  v2ddl="$(sed -n '/^SCHEMA_V2="$/,/^"$/p' "$MEM" | sed '1d;$d')"
  printf '%s\nPRAGMA user_version=2;\n' "$v2ddl" | sqlite3 "$m2db"
  m2q() { printf '%s' "$1" | sqlite3 "$m2db" 2>&1; }
  [ "$(m2q 'PRAGMA user_version;')" = 2 ] && [ "$(m2q "SELECT count(*) FROM sqlite_master WHERE name='records_ext';")" = 1 ] \
    && pass "v2 fixture DB is at user_version 2 with records_ext" || fail "v2 fixture: $(m2q 'PRAGMA user_version;')"
  ATELIER_CONFIG_DIR="$M2" mem list --project "$PA" >/dev/null 2>&1
  ATELIER_CONFIG_DIR="$M2" mem import --dry-run >/dev/null 2>&1
  [ "$(m2q 'PRAGMA user_version;')" = 2 ] && pass "read commands and import --dry-run do not migrate a v2 DB" || fail "v2 migrated by read/dry-run"
  ATELIER_CONFIG_DIR="$M2" mem add fact --project "$PA" --source agent-inferred --title "After v3" >/dev/null
  [ "$(m2q 'PRAGMA user_version;')" = 3 ] && pass "a write command migrates user_version 2 -> 3" || fail "v2->v3 version $(m2q 'PRAGMA user_version;')"
  [ "$(m2q "SELECT id||'|'||title FROM records WHERE type='decision';")" = "D-1|Legacy" ] \
    && pass "v3 migration keeps the existing record and id" || fail "v3 legacy record lost"
  [ "$(m2q "SELECT count(*) FROM sqlite_master WHERE name='records_ext';")" = 0 ] && pass "records_ext index is gone" || fail "records_ext still present"
  [ "$(m2q "SELECT count(*) FROM sqlite_master WHERE name='records_ext_source' AND sql NOT LIKE '%UNIQUE%';")" = 1 ] \
    && pass "non-unique ext_source index exists" || fail "records_ext_source missing or unique"
  for col in ext_source ext_sha title body; do
    r="$(m2q "UPDATE records SET $col='x' WHERE id='D-1';")"
    case "$r" in *"records are immutable"*) pass "v3: UPDATE of $col aborts" ;; *) fail "v3 $col update: $r" ;; esac
  done
  r="$(m2q "DELETE FROM records WHERE id='D-1';")"
  case "$r" in *"never deleted"*) pass "v3: deletes still abort" ;; *) fail "v3 delete: $r" ;; esac
}

# --- current-state import: A->B->A revert, hand-superseded, closed head (#664) -----
mkproj() { # <name>: sets P, CF, MD, and registers a fresh project under its own config dir
  P="$TMP/work/$1"; CF="$TMP/cfg-$1"; mkdir -p "$P" "$CF"
  jq -n --arg a "$P" --arg n "$1" '{projects: {($a): {name: $n}}}' > "$CF/projects.json"
  MD="$CF/projects/$(enc "$P")/memory"; mkdir -p "$MD"
}
wr() { printf -- '---\nname: Note\ndescription: d\nmetadata:\n  type: user\n---\n%s\n' "$2" > "$1"; }
cq() { printf '%s' "$1" | sqlite3 "$CF/atelier/memory.db"; }
ci() { ATELIER_CONFIG_DIR="$CF" mem import 2>&1; }

# Case 1: A -> B -> A
mkproj revert
wr "$MD/n.md" "content-A"; ci >/dev/null
a1="$(cq "SELECT id FROM records;")"
wr "$MD/n.md" "content-B"; ci >/dev/null
wr "$MD/n.md" "content-A"; o="$(ci)"; rc=$?
[ "$rc" = 0 ] && pass "A->B->A: third import exits 0" || fail "A-B-A exit $rc: $o"
printf '%s\n' "$o" | grepq '^revert: 0 new, 1 changed, 0 unchanged$' && pass "A->B->A: third import reports 1 changed" || fail "A-B-A report: $o"
[ "$(cq "SELECT count(*) FROM records;")" = 3 ] && pass "A->B->A: batch written (3 records)" || fail "A-B-A count $(cq "SELECT count(*) FROM records;")"
[ "$(cq "SELECT count(*) FROM records WHERE superseded_by IS NULL;")" = 1 ] && pass "A->B->A: exactly one non-superseded record" || fail "A-B-A heads"
cur="$(cq "SELECT id FROM records WHERE superseded_by IS NULL;")"
[ "$(cq "SELECT count(*) FROM records WHERE id='$cur' AND body LIKE '%content-A%';")" = 1 ] && pass "A->B->A: current record carries content A" || fail "A-B-A content"
b="$(cq "SELECT id FROM records WHERE body LIKE '%content-B%';")"
ATELIER_CONFIG_DIR="$CF" mem show "$cur" | grepq -- "$a1 -> $b -> $cur" && pass "A->B->A: show prints A1 -> B -> A2" || fail "A-B-A chain: $(ATELIER_CONFIG_DIR="$CF" mem show "$cur")"
o="$(ci)"
printf '%s\n' "$o" | grepq '^revert: 0 new, 0 changed, 1 unchanged$' && pass "A->B->A: 4th import of A is unchanged" || fail "A-B-A 4th: $o"
[ "$(cq "SELECT count(*) FROM records;")" = 3 ] && pass "A->B->A: 4th import adds nothing" || fail "A-B-A 4th count"
wr "$MD/n.md" "content-B"; o="$(ci)"
printf '%s\n' "$o" | grepq '^revert: 0 new, 1 changed, 0 unchanged$' && pass "sha matching only a superseded imported row counts as a change" || fail "superseded-sha: $o"

# Case 2: hand-superseded record, then re-import
mkproj hand
wr "$MD/n.md" "content-one"; ci >/dev/null
f1="$(cq "SELECT id FROM records;")"
ATELIER_CONFIG_DIR="$CF" mem supersede "$f1" --type decision --source agent-inferred --title "Hand made" --body "hand body" >/dev/null 2>&1
h="$(cq "SELECT id FROM records WHERE title='Hand made';")"
[ -n "$h" ] && [ "$(cq "SELECT superseded_by FROM records WHERE id='$f1';")" = "$h" ] && pass "hand supersede created a linked record" || fail "hand supersede: h=$h"
[ "$(cq "SELECT type FROM records WHERE id='$h';")" = decision ] && case "$h" in D-*) pass "hand-made head is a decision with D- prefix" ;; *) fail "hand id $h" ;; esac || fail "hand type"
o="$(ci)"
printf '%s\n' "$o" | grepq '^hand: 0 new, 0 changed, 1 unchanged$' && pass "unchanged file after a hand supersede is unchanged" || fail "hand unchanged: $o"
[ "$(cq "SELECT count(*) FROM records;")" = 2 ] && pass "no record added for the unchanged file" || fail "hand count"
wr "$MD/n.md" "content-two"; o="$(ci)"
printf '%s\n' "$o" | grepq '^hand: 0 new, 1 changed, 0 unchanged$' && pass "changed file after a hand supersede reports 1 changed" || fail "hand changed: $o"
[ "$(cq "SELECT count(*) FROM records WHERE superseded_by IS NULL;")" = 1 ] && pass "exactly one current record (no duplicate)" || fail "hand heads: $(cq "SELECT id FROM records WHERE superseded_by IS NULL;")"
cur="$(cq "SELECT id FROM records WHERE superseded_by IS NULL;")"
[ "$(cq "SELECT id FROM records WHERE superseded_by='$cur';")" = "$h" ] && pass "re-imported record's predecessor is the hand-made record" || fail "hand predecessor"
ATELIER_CONFIG_DIR="$CF" mem show "$cur" | grepq -- "$f1 -> $h -> $cur" && pass "show prints imported -> hand-made -> re-imported" || fail "hand chain: $(ATELIER_CONFIG_DIR="$CF" mem show "$cur")"
[ "$(cq "SELECT type FROM records WHERE id='$cur';")" = decision ] && case "$cur" in D-*) pass "superseding a re-typed head keeps its type and D- prefix" ;; *) fail "cur id $cur" ;; esac || fail "cur type $(cq "SELECT type FROM records WHERE id='$cur';")"

# Closed head: import supersedes it and the new record is open
mkproj closed
wr "$MD/n.md" "content-one"; ci >/dev/null
c1="$(cq "SELECT id FROM records;")"
ATELIER_CONFIG_DIR="$CF" mem close "$c1" --by "test closure" >/dev/null 2>&1
[ -n "$(cq "SELECT closed_at FROM records WHERE id='$c1';")" ] && pass "head was closed before the file change" || fail "close did not take effect"
wr "$MD/n.md" "content-two"; o="$(ci)"
printf '%s\n' "$o" | grepq '^closed: 0 new, 1 changed, 0 unchanged$' && pass "closed head: changed file reports 1 changed" || fail "closed changed: $o"
[ "$(cq "SELECT count(*) FROM records WHERE superseded_by IS NULL;")" = 1 ] && n1="$(cq "SELECT id FROM records WHERE superseded_by IS NULL;")" \
  && [ "$(cq "SELECT superseded_by FROM records WHERE id='$c1';")" = "$n1" ] && [ -z "$(cq "SELECT closed_at FROM records WHERE id='$n1';")" ] \
  && pass "closed head is superseded and the new record is open" || fail "closed head chain"

# --- no memory dirs ----------------------------------------------------------------
EC="$TMP/emptycfg"; mkdir -p "$EC"
e="$(ATELIER_CONFIG_DIR="$EC" mem import 2>&1)"; erc=$?
[ "$erc" = 0 ] && [ "$e" = "no Claude memory files found under $EC/projects" ] && [ ! -e "$EC/atelier" ] \
  && pass "import with no memory dirs says so and creates nothing" || fail "empty import: rc=$erc $e"

echo
if [ "$fails" -eq 0 ]; then echo "atelier-memory-import: all tests passed"; exit 0
else echo "atelier-memory-import: $fails failure(s)"; exit 1; fi
