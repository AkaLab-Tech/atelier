#!/usr/bin/env bash
#
# Regression test for task #6 (M4.4) — blocked-task visibility in
# /atelier:status.
#
# Asserts the following invariants against commands/status.md so that
# future careless edits that silently drop or contradict these contracts
# fail CI:
#
#   Group 1 — the ▶ Blocked section header exists and both labelled
#     subsections (Hard-stopped, Dependency-gated) are present
#   Group 2 — ▶ Blocked is ordered after ▶ Oversize and before ▶ Open PRs
#   Group 3 — Hard-stopped detection: exact gh issue list command + json fields
#   Group 4 — backend resolved once via atelier-task-backend
#   Group 5 — Dependency-gated subsection is backend-aware (files vs. board)
#   Group 6 — frontmatter allowed-tools gained both read-only verbs
#   Group 7 — no write verb crept in; read-only guard phrase still present
#   Group 8 — omitted-when-empty behavior + graceful gh issue list degradation
#
# Hermetic: all assertions run against the committed commands/status.md
# only — no network, no gh calls, no filesystem side effects.
#
# Run:  hooks/tests/status-blocked.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CMD="$REPO_ROOT/commands/status.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
# Passes when the fixed string is present in the file; fails otherwise.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label>
# Passes when the fixed string is NOT present in the file; fails otherwise.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    fail "$label — unexpected token '$pattern' found in $file"
  else
    pass "$label"
  fi
}

# chk_absent_in <string> <fixed-string> <label>
# Passes when the fixed string is NOT present in the given (already-extracted)
# text blob; fails otherwise. Used to scope a check to the new blocked-
# visibility prose rather than the whole file, where a pre-existing, unrelated
# mention would otherwise produce a false positive.
chk_absent_in() {
  local blob="$1" pattern="$2" label="$3"
  if printf '%s' "$blob" | grep -qF "$pattern"; then
    fail "$label — unexpected token '$pattern' found"
  else
    pass "$label"
  fi
}

if [ -f "$CMD" ]; then
  pass "cross-ref: commands/status.md exists"
else
  fail "cross-ref: commands/status.md not found — cannot run status-blocked assertions"
  echo ""
  echo "status-blocked (#6): $((fails)) assertion(s) failed."
  exit 1
fi

# ---------------------------------------------------------------------------
# Group 1: ▶ Blocked header + both labelled subsections
# ---------------------------------------------------------------------------

chk_prose "$CMD" '▶ Blocked' \
  "header: ▶ Blocked section header present"

chk_prose "$CMD" 'Hard-stopped' \
  "subsection: Hard-stopped labelled subsection present"

chk_prose "$CMD" '/atelier:resume-task' \
  "subsection: Hard-stopped operator action mentions /atelier:resume-task"

chk_prose "$CMD" 'Dependency-gated' \
  "subsection: Dependency-gated labelled subsection present"

# ---------------------------------------------------------------------------
# Group 2: ordering — ▶ Blocked after ▶ Oversize, before ▶ Open PRs
# ---------------------------------------------------------------------------

oversize_line="$(grep -n '^▶ Oversize' "$CMD" | head -1 | cut -d: -f1)"
blocked_line="$(grep -n '^▶ Blocked$' "$CMD" | head -1 | cut -d: -f1)"
openprs_line="$(grep -n '^▶ Open PRs' "$CMD" | head -1 | cut -d: -f1)"

if [ -n "$oversize_line" ] && [ -n "$blocked_line" ] && [ -n "$openprs_line" ] \
   && [ "$blocked_line" -gt "$oversize_line" ] && [ "$blocked_line" -lt "$openprs_line" ]; then
  pass "ordering: ▶ Blocked (line $blocked_line) is after ▶ Oversize (line $oversize_line) and before ▶ Open PRs (line $openprs_line)"
else
  fail "ordering: ▶ Blocked is not strictly between ▶ Oversize and ▶ Open PRs (oversize=$oversize_line blocked=$blocked_line open-prs=$openprs_line)"
fi

# ---------------------------------------------------------------------------
# Group 3: Hard-stopped detection — exact command + json fields
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'gh issue list --label blocked --state open' \
  "hard-stopped: exact gh issue list command string present"

chk_prose "$CMD" 'number,title,url,createdAt' \
  "hard-stopped: --json fields number,title,url,createdAt present"

# ---------------------------------------------------------------------------
# Group 4: backend resolved once via atelier-task-backend
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'atelier-task-backend' \
  "backend: atelier-task-backend command referenced"

# ---------------------------------------------------------------------------
# Group 5: Dependency-gated subsection is backend-aware
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'blocked_by:' \
  "dependency-gated: files-backend blocked_by: ROADMAP scan described"

chk_prose "$CMD" 'lives on the' \
  "dependency-gated: non-files-backend 'lives on the ... board' note present"

# ---------------------------------------------------------------------------
# Group 6: frontmatter allowed-tools gained both read-only verbs
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'Bash(atelier-task-backend:*)' \
  "frontmatter: allowed-tools includes Bash(atelier-task-backend:*)"

chk_prose "$CMD" 'Bash(gh issue list:*)' \
  "frontmatter: allowed-tools includes Bash(gh issue list:*)"

# ---------------------------------------------------------------------------
# Group 7: no write verb crept in; read-only guard still present
#
# 'gh pr create' is checked scoped to the new blocked-visibility prose only
# (frontmatter + section 4 + the ▶ Blocked output block), not the whole file:
# the pre-existing, unrelated ▶ Oversize resolution line legitimately mentions
# `gh pr create` in backticks as manual operator guidance (predates this
# task's diff) and is out of scope for this acceptance criterion.
# ---------------------------------------------------------------------------

chk_absent "$CMD" 'gh issue create' \
  "no-write: 'gh issue create' absent"

chk_absent "$CMD" 'gh pr merge' \
  "no-write: 'gh pr merge' absent"

frontmatter_line="$(grep '^allowed-tools:' "$CMD")"
blocked_section="$(sed -n '/^### 4\. Blocked tasks/,/^## Output format/p' "$CMD")"
blocked_output="$(sed -n '/^▶ Blocked$/,/^▶ Open PRs/p' "$CMD")"

chk_absent_in "$frontmatter_line
$blocked_section
$blocked_output" 'gh pr create' \
  "no-write: 'gh pr create' absent from the blocked-visibility prose (frontmatter + section 4 + ▶ Blocked output block)"

chk_absent "$CMD" 'git commit' \
  "no-write: 'git commit' absent"

chk_absent "$CMD" 'git push' \
  "no-write: 'git push' absent"

chk_prose "$CMD" 'never modify any file' \
  "guard: read-only guard phrase 'never modify any file' still present"

# ---------------------------------------------------------------------------
# Group 8: omitted-when-empty + graceful gh issue list degradation
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'omit each subsection when empty; omit the whole section when both are empty' \
  "empty-state: each subsection omitted-when-empty, whole section omitted-when-both-empty"

chk_prose "$CMD" 'If `gh issue list` fails' \
  "degradation: gh issue list failure is described"

chk_prose "$CMD" 'do not skip the whole' \
  "degradation: gh issue list failure does not skip the whole ▶ Blocked section"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "status-blocked (#6): all assertions passed."
  exit 0
else
  echo "status-blocked (#6): $fails assertion(s) failed."
  exit 1
fi
