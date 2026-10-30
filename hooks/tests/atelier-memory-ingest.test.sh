#!/usr/bin/env bash
#
# Hermetic regression test for `atelier-memory ingest` (#610d, #621).
# Verifies:
# - Markdown files in inbox are ingested: type=request by default, project derived
#   from prefix or global, verbatim quote, source=operator-verbatim, author=operator.
# - File moves to <inbox>/.processed/<UTC-timestamp>-<name>.md (or .procesado/ in Spanish).
# - Frontmatter options: type, project, supersedes, refs.
# - Secret-matching or malformed frontmatter generates .error.txt sidecar, leaves file in place.
# - Idempotency: re-running ingest on previously ingested content does not duplicate records.
# - Integration with hooks/memory-brief.sh: runs ingest before brief; covers startup|resume|clear;
#   fail-open; assert hooks.json registers clear.
#
# Run:  hooks/tests/atelier-memory-ingest.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEM="$REPO_ROOT/scripts/atelier-memory"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
BRIEF_HOOK="$REPO_ROOT/hooks/memory-brief.sh"

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
VAULT="$TMP/vault"
export ATELIER_MEMORY_VAULT="$VAULT"
mkdir -p "$VAULT/Inbox"

dbq() { printf '%s' "$1" | sqlite3 "$DB"; }

# Project fixture
PROJ_A="$TMP/work/palabrium"
PROJ_B="$TMP/work/dental"
mkdir -p "$PROJ_A" "$PROJ_B" "$CFG"
jq -n --arg a "$PROJ_A" --arg b "$PROJ_B" \
  '{projects: {($a): {name: "palabrium"}, ($b): {name: "dental"}}}' \
  > "$CFG/projects.json"

# --- 1. hooks.json registers clear event -----------------------------------
if jq -e '.hooks.SessionStart[] | select((.matcher // "") | test("(^|\\|)clear(\\||$)")) | .hooks[] | select(.command | test("/hooks/memory-brief\\.sh\"?$"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  pass "hooks.json registers memory-brief.sh for startup|resume|clear"
else
  fail "hooks.json missing clear event in SessionStart memory-brief matcher"
fi

# --- 2. Default ingestion (type=request, project=*, operator-verbatim) ------
cat > "$VAULT/Inbox/test-request.md" <<'EOF'
Please update the login page colors and layout.
Need it done before demo.
EOF

out="$(mem ingest 2>&1)"
r=$?
if [ "$r" -eq 0 ] && grep -q "ingested R-1: test-request" <<<"$out"; then
  pass "ingest returns 0 and reports ingested R-1"
else
  fail "ingest default failed (exit=$r, out=$out)"
fi

rec="$(dbq "SELECT type || '|' || project || '|' || source || '|' || created_by || '|' || quote || '|' || coalesce(body,'') FROM records WHERE id='R-1';")"
expected_quote="Please update the login page colors and layout.
Need it done before demo."
if [ "$rec" = "request|*|operator-verbatim|operator|$expected_quote|" ]; then
  pass "R-1 stored with type=request, project=*, source=operator-verbatim, author=operator, body empty"
else
  fail "R-1 record contents mismatch: $rec"
fi

# File moved to .processed with timestamp prefix; original inbox file gone
if [ ! -f "$VAULT/Inbox/test-request.md" ]; then
  pass "inbox file test-request.md moved out of Inbox root"
else
  fail "test-request.md still in Inbox root"
fi

proc_file="$(find "$VAULT/Inbox/.processed" -type f -name '*-test-request.md' 2>/dev/null | head -1)"
if [ -n "$proc_file" ] && [ -f "$proc_file" ]; then
  pass "test-request.md moved to .processed/<timestamp>-test-request.md"
  if diff -u "$proc_file" <(printf '%s\n' "$expected_quote") >/dev/null; then
    pass "processed file preserved verbatim content (never deleted)"
  else
    fail "processed file content corrupted"
  fi
else
  fail "processed file not found in .processed/"
fi

# --- 3. Heading extraction for title when no frontmatter title --------------
cat > "$VAULT/Inbox/note-with-heading.md" <<'EOF'
# Fix navigation drawer animation
The animation is jerky on Safari.
EOF
mem ingest >/dev/null 2>&1
ttl="$(dbq "SELECT title FROM records WHERE id='R-2';")"
if [ "$ttl" = "Fix navigation drawer animation" ]; then
  pass "title extracted from first markdown heading (# Heading)"
else
  fail "title extraction mismatch: $ttl"
fi

# --- 4. Project derived from filename prefix -------------------------------
cat > "$VAULT/Inbox/palabrium-auth-fix.md" <<'EOF'
Fix authentication timeout in Supabase client.
EOF
mem ingest >/dev/null 2>&1
proj="$(dbq "SELECT project FROM records WHERE id='R-3';")"
if [ "$proj" = "$PROJ_A" ]; then
  pass "project derived from filename prefix (palabrium- -> $PROJ_A)"
else
  fail "filename prefix project deduction mismatch: $proj"
fi

# Multi-segment prefix fallback to global when unknown
cat > "$VAULT/Inbox/unknownproj-feature-task.md" <<'EOF'
Task for an unregistered project.
EOF
mem ingest >/dev/null 2>&1
unkn_proj="$(dbq "SELECT project FROM records WHERE id='R-4';")"
if [ "$unkn_proj" = "*" ]; then
  pass "unknown project prefix falls back to global (*)"
else
  fail "unknown prefix project fallback mismatch: $unkn_proj"
fi

# --- 5. Frontmatter options: type, project, refs, title --------------------
cat > "$VAULT/Inbox/custom-fact.md" <<EOF
---
type: fact
project: dental
title: Use Postgres with Prisma
refs:
  - file:packages/db/schema.prisma
  - issue:dental/app#101
---
We use Prisma ORM with PostgreSQL.
EOF
mem ingest >/dev/null 2>&1
f_rec="$(dbq "SELECT id || '|' || type || '|' || project || '|' || title || '|' || refs FROM records WHERE id='F-1';")"
if [ "$f_rec" = "F-1|fact|$PROJ_B|Use Postgres with Prisma|[\"file:packages/db/schema.prisma\",\"issue:dental/app#101\"]" ]; then
  pass "frontmatter type, project, title, refs (YAML list) parsed and stored"
else
  fail "frontmatter custom record mismatch: $f_rec"
fi

# Frontmatter refs as JSON array and CSV
cat > "$VAULT/Inbox/json-refs.md" <<'EOF'
---
type: fact
project: global
refs: ["file:README.md", "branch:main"]
---
Fact with JSON array refs.
EOF
mem ingest >/dev/null 2>&1
f_json="$(dbq "SELECT refs FROM records WHERE id='F-2';")"
if [ "$f_json" = '["file:README.md","branch:main"]' ]; then
  pass "frontmatter refs as JSON array parsed correctly"
else
  fail "frontmatter JSON refs mismatch: $f_json"
fi

# --- 6. Frontmatter supersedes ---------------------------------------------
cat > "$VAULT/Inbox/supersede-fact.md" <<'EOF'
---
type: fact
project: dental
supersedes: F-1
title: Prisma updated to v5
---
We upgraded Prisma to version 5 with driverAdapters.
EOF
mem ingest >/dev/null 2>&1
sup_old="$(dbq "SELECT superseded_by FROM records WHERE id='F-1';")"
sup_new="$(dbq "SELECT id || '|' || quote FROM records WHERE id='F-3';")"
if [ "$sup_old" = "F-3" ] && [[ "$sup_new" =~ F-3\|We\ upgraded\ Prisma ]]; then
  pass "frontmatter supersedes links F-1 -> F-3 atomically"
else
  fail "supersedes link mismatch: old_sup=$sup_old new=$sup_new"
fi

# --- 7. Spanish vault (Entrada/ -> .procesado/) ----------------------------
VAULT_ES="$TMP/vault-es"
mkdir -p "$VAULT_ES/Entrada"
cat > "$CFG/operator.json" <<'EOF'
{
  "chatLanguage": "es"
}
EOF
cat > "$VAULT_ES/Entrada/nota-espanol.md" <<'EOF'
Revisar configuracion de backups de la base de datos.
EOF

es_out="$(ATELIER_MEMORY_VAULT="$VAULT_ES" mem ingest 2>&1)"
es_r=$?
proc_es="$(find "$VAULT_ES/Entrada/.procesado" -type f -name '*-nota-espanol.md' 2>/dev/null | head -1)"
if [ "$es_r" -eq 0 ] && [ -n "$proc_es" ] && [ -f "$proc_es" ] && [ ! -f "$VAULT_ES/Entrada/nota-espanol.md" ]; then
  pass "Spanish vault ingests from Entrada/ and moves to Entrada/.procesado/"
else
  fail "Spanish vault ingest failed (exit=$es_r, proc=$proc_es, out=$es_out)"
fi
rm -f "$CFG/operator.json"

# --- 8. Secret matching: refuses ingest, leaves file in place, writes sidecar
SECRET_VAL="AKIA""0123456789EXAMPLE"
cat > "$VAULT/Inbox/secret-note.md" <<EOF
Here is the API credential: $SECRET_VAL
Please do not commit.
EOF

sec_cnt_before="$(dbq "SELECT count(*) FROM records;")"
mem ingest >/dev/null 2>&1 || true
sec_cnt_after="$(dbq "SELECT count(*) FROM records;")"
sidecar="$VAULT/Inbox/secret-note.error.txt"

if [ "$sec_cnt_before" -eq "$sec_cnt_after" ] \
   && [ -f "$VAULT/Inbox/secret-note.md" ] \
   && [ -f "$sidecar" ] \
   && grep -q 'Secret pattern' "$sidecar"; then
  pass "secret matching prevents ingest, leaves file in place, writes .error.txt sidecar"
else
  fail "secret handling failed (before=$sec_cnt_before, after=$sec_cnt_after, file_exists=$([ -f "$VAULT/Inbox/secret-note.md" ] && echo 1 || echo 0))"
fi
rm -f "$VAULT/Inbox/secret-note.md" "$sidecar"

# --- 9. Malformed frontmatter (open without close) -------------------------
cat > "$VAULT/Inbox/unclosed-fm.md" <<'EOF'
---
title: Unclosed Frontmatter
type: request
Body text without closing triple dashes.
EOF

cnt_before="$(dbq "SELECT count(*) FROM records;")"
mem ingest >/dev/null 2>&1 || true
cnt_after="$(dbq "SELECT count(*) FROM records;")"
fm_sidecar="$VAULT/Inbox/unclosed-fm.error.txt"

if [ "$cnt_before" -eq "$cnt_after" ] \
   && [ -f "$VAULT/Inbox/unclosed-fm.md" ] \
   && [ -f "$fm_sidecar" ] \
   && grep -q 'Invalid frontmatter syntax' "$fm_sidecar"; then
  pass "malformed frontmatter prevents ingest, leaves file in place, writes .error.txt sidecar"
else
  fail "malformed frontmatter handling failed"
fi

# Sidecar cleanup on fix
cat > "$VAULT/Inbox/unclosed-fm.md" <<'EOF'
---
title: Now Closed Frontmatter
type: request
---
Body text with closing triple dashes.
EOF
mem ingest >/dev/null 2>&1
if [ ! -f "$VAULT/Inbox/unclosed-fm.md" ] && [ ! -f "$fm_sidecar" ]; then
  pass "fixing invalid file in place allows subsequent ingest and removes .error.txt sidecar"
else
  fail "fixing file did not clear sidecar or move file"
fi

# --- 10. Invalid frontmatter fields produce sidecars -----------------------
# Bad type
cat > "$VAULT/Inbox/bad-type.md" <<'EOF'
---
type: invalid_type_123
---
Body content.
EOF
mem ingest >/dev/null 2>&1 || true
if [ -f "$VAULT/Inbox/bad-type.md" ] && grep -q 'Invalid type' "$VAULT/Inbox/bad-type.error.txt" 2>/dev/null; then
  pass "invalid type in frontmatter rejected with .error.txt sidecar"
else
  fail "invalid type rejected failed"
fi
rm -f "$VAULT/Inbox/bad-type.md" "$VAULT/Inbox/bad-type.error.txt"

# Bad project
cat > "$VAULT/Inbox/bad-proj.md" <<'EOF'
---
project: non-existent-project-xyz-999
---
Body content.
EOF
mem ingest >/dev/null 2>&1 || true
if [ -f "$VAULT/Inbox/bad-proj.md" ] && grep -q 'Unknown project' "$VAULT/Inbox/bad-proj.error.txt" 2>/dev/null; then
  pass "unknown project in frontmatter rejected with .error.txt sidecar"
else
  fail "unknown project rejection failed"
fi
rm -f "$VAULT/Inbox/bad-proj.md" "$VAULT/Inbox/bad-proj.error.txt"

# Bad supersedes
cat > "$VAULT/Inbox/bad-sup.md" <<'EOF'
---
supersedes: R-99999
---
Body content.
EOF
mem ingest >/dev/null 2>&1 || true
if [ -f "$VAULT/Inbox/bad-sup.md" ] && grep -q 'Invalid supersedes' "$VAULT/Inbox/bad-sup.error.txt" 2>/dev/null; then
  pass "nonexistent supersedes target rejected with .error.txt sidecar"
else
  fail "nonexistent supersedes rejection failed"
fi
rm -f "$VAULT/Inbox/bad-sup.md" "$VAULT/Inbox/bad-sup.error.txt"

# Bad refs
cat > "$VAULT/Inbox/bad-ref.md" <<'EOF'
---
refs: [invalid_ref_without_scheme]
---
Body content.
EOF
mem ingest >/dev/null 2>&1 || true
if [ -f "$VAULT/Inbox/bad-ref.md" ] && grep -q 'Invalid refs' "$VAULT/Inbox/bad-ref.error.txt" 2>/dev/null; then
  pass "malformed ref item rejected with .error.txt sidecar"
else
  fail "malformed ref rejection failed"
fi
rm -f "$VAULT/Inbox/bad-ref.md" "$VAULT/Inbox/bad-ref.error.txt"

# Empty body
cat > "$VAULT/Inbox/empty-body.md" <<'EOF'
---
title: Only Title
---

EOF
mem ingest >/dev/null 2>&1 || true
if [ -f "$VAULT/Inbox/empty-body.md" ] && grep -q 'Empty body' "$VAULT/Inbox/empty-body.error.txt" 2>/dev/null; then
  pass "empty body note rejected with .error.txt sidecar"
else
  fail "empty body rejection failed"
fi
rm -f "$VAULT/Inbox/empty-body.md" "$VAULT/Inbox/empty-body.error.txt"

# --- 11. Idempotency -------------------------------------------------------
cat > "$VAULT/Inbox/idempotent-test.md" <<'EOF'
This note tests ingest idempotency.
EOF
mem ingest >/dev/null 2>&1
rec_cnt_1="$(dbq "SELECT count(*) FROM records;")"

# Copy identical file back to Inbox
cat > "$VAULT/Inbox/idempotent-test.md" <<'EOF'
This note tests ingest idempotency.
EOF
mem ingest >/dev/null 2>&1
rec_cnt_2="$(dbq "SELECT count(*) FROM records;")"

if [ "$rec_cnt_1" -eq "$rec_cnt_2" ] && [ ! -f "$VAULT/Inbox/idempotent-test.md" ]; then
  pass "re-ingesting file with identical content and name does not duplicate record in DB"
else
  fail "idempotency check failed (cnt1=$rec_cnt_1, cnt2=$rec_cnt_2, file_in_inbox=$([ -f "$VAULT/Inbox/idempotent-test.md" ] && echo 1 || echo 0))"
fi

# --- 12. Integration with hooks/memory-brief.sh ----------------------------
cat > "$VAULT/Inbox/brief-integration-req.md" <<'EOF'
---
project: palabrium
title: Urgent task surfaced via brief hook execution
---
Urgent task surfaced via brief hook execution.
EOF

# Ensure memory-brief.sh runs ingest before generating brief
brief_out="$(PATH="$REPO_ROOT/scripts:$PATH" ATELIER_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$PROJ_A" bash "$BRIEF_HOOK")"
brief_r=$?

if [ "$brief_r" -eq 0 ] \
   && [ ! -f "$VAULT/Inbox/brief-integration-req.md" ] \
   && grep -q "Urgent task surfaced via brief hook execution" <<<"$brief_out"; then
  pass "memory-brief.sh runs ingest before brief and includes newly ingested record"
else
  fail "memory-brief.sh integration failed (exit=$brief_r, brief_out=$brief_out)"
fi

# Fail-open: memory-brief.sh exits 0 even if DB or memory command encounters error
bad_brief_out="$(PATH="$TMP/nonexistent:$PATH" ATELIER_CONFIG_DIR="$TMP/bad-dir" CLAUDE_PROJECT_DIR="$PROJ_A" bash "$BRIEF_HOOK" 2>&1)"
bad_brief_r=$?
if [ "$bad_brief_r" -eq 0 ]; then
  pass "memory-brief.sh fails open (exit 0) when environment or DB has errors"
else
  fail "memory-brief.sh failed closed (exit=$bad_brief_r, out=$bad_brief_out)"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "atelier-memory-ingest: all checks passed"
  exit 0
fi
echo "atelier-memory-ingest: $fails check(s) failed"
exit 1
