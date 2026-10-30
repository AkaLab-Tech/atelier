#!/usr/bin/env bash
#
# Regression test for #607 — route worktree creation through atelier-worktree-create
# across commands/ and skills/, and enforce --scan-env pre-flight in resume-task.
#
# Asserts:
#   Group 1 — No raw `git wt switch ... --from` creation instructions exist in
#             any file under commands/ or skills/.
#   Group 2 — Frontmatter allowed-tools in touched commands (next-task.md,
#             resume-task.md, release.md, abandon-task.md) grant
#             Bash(atelier-worktree-create:*).
#   Group 3 — Every atelier-driven worktree creation uses atelier-worktree-create:
#             - commands/next-task.md step 5
#             - commands/resume-task.md step 3b
#             - skills/retry-with-logs/SKILL.md
#             - commands/release.md step 5
#             - commands/abandon-task.md step 7
#   Group 4 — resume-task pre-flight scan-env contract:
#             - runs `atelier-worktree-create --scan-env <worktree>` before dispatching
#             - on exit 1 stops and prints the flagged names
#             - points to cleanup procedure in docs/troubleshooting.md
#             - refuses to dispatch the orchestrator on exit 1
#
# Run:  hooks/tests/worktree-create-routing.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label>
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

echo "=== Group 1: No raw 'git wt switch ... --from' creation instructions ==="

raw_wt_matches="$(grep -rnE 'git wt switch[[:space:]]+.*--from' "$REPO_ROOT/commands" "$REPO_ROOT/skills" 2>/dev/null || true)"
if [ -z "$raw_wt_matches" ]; then
  pass "no files under commands/ or skills/ instruct raw 'git wt switch ... --from'"
else
  fail "found raw 'git wt switch ... --from' instructions:\n$raw_wt_matches"
fi

# Negative guard verification: ensure our pattern would catch a raw switch creation instruction
tmp_fixture="$(mktemp)"
printf 'git wt switch task/123-slug --from origin/main\n' > "$tmp_fixture"
if grep -qE 'git wt switch[[:space:]]+.*--from' "$tmp_fixture"; then
  pass "pattern matcher correctly detects raw 'git wt switch ... --from'"
else
  fail "pattern matcher failed to detect raw 'git wt switch ... --from'"
fi
rm -f "$tmp_fixture"

echo "=== Group 2: Frontmatter allowed-tools grants ==="

chk_prose "$REPO_ROOT/commands/next-task.md" 'Bash(atelier-worktree-create:*)' \
  "commands/next-task.md frontmatter: Bash(atelier-worktree-create:*)"

chk_prose "$REPO_ROOT/commands/resume-task.md" 'Bash(atelier-worktree-create:*)' \
  "commands/resume-task.md frontmatter: Bash(atelier-worktree-create:*)"

chk_prose "$REPO_ROOT/commands/release.md" 'Bash(atelier-worktree-create:*)' \
  "commands/release.md frontmatter: Bash(atelier-worktree-create:*)"

chk_prose "$REPO_ROOT/commands/abandon-task.md" 'Bash(atelier-worktree-create:*)' \
  "commands/abandon-task.md frontmatter: Bash(atelier-worktree-create:*)"

echo "=== Group 3: Atelier-driven worktree creations use atelier-worktree-create ==="

# 1. commands/next-task.md step 5
chk_prose "$REPO_ROOT/commands/next-task.md" 'atelier-worktree-create "$MAIN_ROOT" <branch> --from origin/<base>' \
  "commands/next-task.md step 5: uses atelier-worktree-create \"\$MAIN_ROOT\" <branch> --from origin/<base>"

# 2. commands/resume-task.md step 3b
chk_prose "$REPO_ROOT/commands/resume-task.md" 'atelier-worktree-create "$MAIN_ROOT" task/<id>-<slug> --from origin/<base>' \
  "commands/resume-task.md step 3b: uses atelier-worktree-create \"\$MAIN_ROOT\" task/<id>-<slug> --from origin/<base>"

# 3. skills/retry-with-logs/SKILL.md (table and restore instructions)
chk_prose "$REPO_ROOT/skills/retry-with-logs/SKILL.md" 'atelier-worktree-create "<project_root>" <branch> --from origin/<base>' \
  "skills/retry-with-logs/SKILL.md: uses atelier-worktree-create \"<project_root>\" <branch> --from origin/<base>"

# 4. commands/release.md step 5
chk_prose "$REPO_ROOT/commands/release.md" 'atelier-worktree-create "<project>" <branch> --from origin/main' \
  "commands/release.md step 5: uses atelier-worktree-create \"<project>\" <branch> --from origin/main"

# 5. commands/abandon-task.md step 7
chk_prose "$REPO_ROOT/commands/abandon-task.md" 'atelier-worktree-create "$MAIN_ROOT" docs/abandon-<id> --from <base>' \
  "commands/abandon-task.md step 7: uses atelier-worktree-create \"\$MAIN_ROOT\" docs/abandon-<id> --from <base>"

echo "=== Group 4: resume-task --scan-env contract ==="

chk_prose "$REPO_ROOT/commands/resume-task.md" 'atelier-worktree-create --scan-env <worktree>' \
  "commands/resume-task.md: runs atelier-worktree-create --scan-env <worktree> before dispatching"

chk_prose "$REPO_ROOT/commands/resume-task.md" 'On exit 1, stop and print the flagged names' \
  "commands/resume-task.md: on exit 1 stops and prints flagged names"

chk_prose "$REPO_ROOT/commands/resume-task.md" 'docs/troubleshooting.md' \
  "commands/resume-task.md: points to cleanup procedure in docs/troubleshooting.md"

chk_prose "$REPO_ROOT/commands/resume-task.md" 'do not dispatch the orchestrator' \
  "commands/resume-task.md: refuses to dispatch orchestrator on exit 1"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "worktree-create-routing (#607): all assertions passed."
  exit 0
else
  echo "worktree-create-routing (#607): $fails assertion(s) failed."
  exit 1
fi
