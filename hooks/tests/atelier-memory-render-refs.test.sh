#!/usr/bin/env bash
#
# Hermetic regression test for #684 7c: refs never reach SQL as raw text (exact issue
# stub matching, planted malformed stored refs skipped), split from
# atelier-memory-render.test.sh in #764.
# Run:  bash hooks/tests/atelier-memory-render-refs.test.sh
# Exit: 0 = all pass (or skipped), 1 = at least one failure.

set -uo pipefail

# shellcheck source=hooks/tests/memory-render-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/memory-render-fixture.sh"

ATELIER_MEMORY_VAULT=off mem add fact --project "$PROJ" --source agent-inferred --title "seed fact" >/dev/null
V684="$TMP/vault684"
export ATELIER_MEMORY_VAULT="$V684"
vault_assert_isolated "$V684"
DBF="$ATELIER_CONFIG_DIR/atelier/memory.db"

mem render --full >/dev/null 2>&1

# 7c. refs never reach SQL as raw text
n684="$(printf 'SELECT count(*) FROM records;' | sqlite3 "$DBF")"
inj="issue:o/r#1' UNION SELECT 'X-9', hex('INJECTED') --"
[ "$(rc mem add fact --project "$PROJ" --source agent-inferred --title inj --ref "$inj")" = 2 ] \
  && pass "UNION-shaped ref rejected at the CLI" || fail "UNION-shaped ref accepted"
[ "$(printf 'SELECT count(*) FROM records;' | sqlite3 "$DBF")" = "$n684" ] && pass "rejected ref wrote nothing" || fail "rejected ref wrote a row"

id_w1="$(mem add fact --project "$PROJ" --source agent-inferred --title "wild one" --ref "issue:o_r/x#1")"
id_w2="$(mem add fact --project "$PROJ" --source agent-inferred --title "wild two" --ref "issue:oar/x#1")"
id_w3="$(mem add fact --project "$PROJ" --source agent-inferred --title "wild three" --ref "pr:o_r/x#1")"
mem render --full >/dev/null 2>&1
stub="$V684/Issues/o_r-x#1.md"
if [ -f "$stub" ] && grep -q "\[\[$id_w1\]\]" "$stub" && ! grep -q "\[\[$id_w2\]\]" "$stub" && ! grep -q "\[\[$id_w3\]\]" "$stub"; then
  pass "issue stub matches the exact ref ('_' is not a wildcard, pr: refs excluded)"
else
  fail "issue stub widened by LIKE wildcard: $(cat "$stub" 2>/dev/null)"
fi

# a malformed ref planted in the DB is skipped and never injected
printf "INSERT INTO records (id,type,project,source,title,body,quote,refs,created_at,created_by) SELECT 'F-900','fact',project,'agent-inferred','planted','b',NULL,json_array('issue:o/r#1'' UNION SELECT ''X-9'', hex(''INJECTED'') --', 'pr:a/b#2'),strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now'),'test' FROM records WHERE id='%s';\n" "$id_w1" | sqlite3 "$DBF"
bad_err="$(mem render --full 2>&1 >/dev/null)"
if ! grep -rqF -e '[[X-9]]' "$V684" 2>/dev/null && [ ! -e "$V684/Records/X-9.md" ] && [ -f "$V684/PRs/a-b#2.md" ]; then
  pass "planted malformed stored ref is not injected; valid sibling ref still rendered"
else
  fail "malformed stored ref leaked into notes"
fi
case "$bad_err" in *"skipping malformed stored ref"*) pass "malformed stored ref skipped with a warning" ;; *) fail "no warning for malformed stored ref: $bad_err" ;; esac
mem close F-900 --by "$id_w1" >/dev/null 2>&1
if ! grep -rqF -e '[[X-9]]' "$V684" 2>/dev/null; then pass "incremental render does not inject a planted ref"; else fail "incremental render injected"; fi

finish "atelier-memory-render-refs"
