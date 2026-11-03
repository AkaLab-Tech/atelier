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

# shellcheck disable=SC2015,SC2016  # pass() always succeeds; literal backticks/$ in fixed strings
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

echo "=== Group 1: No raw 'git wt switch ... --from' / git-wt-skill creation wording ==="

SCAN_DIRS=("$REPO_ROOT/commands" "$REPO_ROOT/skills" "$REPO_ROOT/agents" "$REPO_ROOT/operator-rules.md")
RAW_RE='git wt switch[[:space:]]+.*--from'
SKILL_RE='(invoke|invokes|invoking) the `git-wt` skill|via the `git-wt` skill'

raw_wt_matches="$(grep -rnE "$RAW_RE" "${SCAN_DIRS[@]}" 2>/dev/null || true)"
if [ -z "$raw_wt_matches" ]; then
  pass "no file under commands/ skills/ agents/ operator-rules.md instructs raw 'git wt switch ... --from'"
else
  fail "found raw 'git wt switch ... --from' instructions:
$raw_wt_matches"
fi
skill_matches="$(grep -rniE "$SKILL_RE" "${SCAN_DIRS[@]}" 2>/dev/null || true)"
if [ -z "$skill_matches" ]; then
  pass "no file instructs creating a worktree via the git-wt skill"
else
  fail "found git-wt skill creation wording:
$skill_matches"
fi

# Negative-fixture self-check: the patterns must catch the forbidden shapes.
tmp_fixture="$(mktemp)"
printf 'git wt switch task/123-slug --from origin/main\n' > "$tmp_fixture"
grep -qE "$RAW_RE" "$tmp_fixture" && pass "self-check: raw-switch pattern detects 'git wt switch ... --from'" \
  || fail "self-check: raw-switch pattern failed to detect fixture"
for phrase in 'Invoke the `git-wt` skill to create the worktree' 'created via the `git-wt` skill' 'it invokes the `git-wt` skill'; do
  printf '%s\n' "$phrase" > "$tmp_fixture"
  grep -qiE "$SKILL_RE" "$tmp_fixture" && pass "self-check: skill pattern detects: $phrase" \
    || fail "self-check: skill pattern missed: $phrase"
done
printf 'Run `atelier-worktree-create "$MAIN_ROOT" <branch> --from origin/main`\n' > "$tmp_fixture"
if grep -qiE "$SKILL_RE" "$tmp_fixture" || grep -qE "$RAW_RE" "$tmp_fixture"; then
  fail "self-check: patterns false-positive on the correct wording"
else
  pass "self-check: patterns accept the correct wording"
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

# sect <file> <line-prefix> — prints from the first line starting with
# <line-prefix> up to (not including) the next markdown heading.
sect() {
  awk -v pre="$2" 'f && /^#+ /{exit} index($0,pre)==1{f=1} f{print}' "$1"
}
# chk_exit <label> <text>: text must spell out exit 1 and exit 2 handling.
chk_exit() {
  local label="$1" text="$2"
  if [ -z "$text" ]; then fail "$label — section not found"; return; fi
  printf '%s' "$text" | grep -qiF 'exit 1' && pass "$label: handles exit 1" || fail "$label: no exit 1 handling"
  printf '%s' "$text" | grep -qiE 'exit 2|exit 1 or 2' && pass "$label: handles exit 2" || fail "$label: no exit 2 handling"
}

echo "=== Group 5: heading / wording names atelier-worktree-create ==="

chk_prose "$REPO_ROOT/commands/next-task.md" '### 5. Create the per-task worktree — `atelier-worktree-create`' "next-task step 5 heading names atelier-worktree-create"
chk_prose "$REPO_ROOT/commands/release.md" '### 5. Create the release worktree — `atelier-worktree-create`' "release step 5 heading names atelier-worktree-create"
chk_absent "$REPO_ROOT/commands/next-task.md" '— `git-wt` skill' "next-task heading no longer names the git-wt skill"
chk_absent "$REPO_ROOT/commands/release.md" '— `git-wt` skill' "release heading no longer names the git-wt skill"
chk_prose "$REPO_ROOT/operator-rules.md" 'via `atelier-worktree-create`' "operator-rules names atelier-worktree-create"
chk_prose "$REPO_ROOT/skills/task-discovery/SKILL.md" 'atelier-worktree-create' "task-discovery names atelier-worktree-create"
orch="$REPO_ROOT/agents/task-orchestrator.md"
orch_step2="$(sect "$orch" '2. **Set up isolation.**')"
printf '%s' "$orch_step2" | grep -qF 'atelier-worktree-create "<project_root>" task/<id>-<slug> --from origin/<base>' \
  && pass "orchestrator step 2 uses atelier-worktree-create" || fail "orchestrator step 2 does not use atelier-worktree-create"
printf '%s' "$orch_step2" | grep -qF 'Invoke the `git-wt` skill' && fail "orchestrator step 2 still invokes git-wt skill" || pass "orchestrator step 2: no git-wt skill invocation"
orch_reset="$(grep -F -- '- `reset` →' "$orch")"
printf '%s' "$orch_reset" | grep -qF 'atelier-worktree-create "<project_root>" <branch> --from origin/<base>' \
  && pass "orchestrator reset uses atelier-worktree-create" || fail "orchestrator reset does not use atelier-worktree-create"
printf '%s' "$orch_reset" | grep -qF 'git fetch origin <base>' && printf '%s' "$orch_reset" | grep -qF 'git wt rm <branch> --force' \
  && pass "orchestrator reset matches retry-with-logs (rm --force, fetch, create)" || fail "orchestrator reset differs from retry-with-logs"
printf '%s' "$orch_reset" | grep -qF 're-`switch`' && fail "orchestrator reset still says rm + re-switch" || pass "orchestrator reset: no rm + re-switch cycle"

echo "=== Group 6: exit 1 / exit 2 handling spelled out per creation site ==="

chk_exit "next-task step 5" "$(sect "$REPO_ROOT/commands/next-task.md" '### 5. ')"
chk_exit "release step 5" "$(sect "$REPO_ROOT/commands/release.md" '### 5. ')"
chk_exit "abandon-task step 7" "$(sect "$REPO_ROOT/commands/abandon-task.md" '  1. **Prepare the branch in a throwaway worktree**' | head -n1)"
chk_exit "resume-task 3b.2" "$(grep -F '2. **Worktree found**' "$REPO_ROOT/commands/resume-task.md")"
chk_exit "resume-task 3b.3" "$(sect "$REPO_ROOT/commands/resume-task.md" '3. **Worktree not found**')"
chk_exit "retry-with-logs reset" "$(grep -F '**(between 03 and 04)**' "$REPO_ROOT/skills/retry-with-logs/SKILL.md")"
chk_exit "task-orchestrator step 2" "$orch_step2"
chk_exit "task-orchestrator reset" "$orch_reset"

echo "=== Group 7: resume-task scans before reuse and stops on exit 2 ==="

rt="$REPO_ROOT/commands/resume-task.md"
r3b2="$(grep -F '2. **Worktree found**' "$rt")"
printf '%s' "$r3b2" | grep -qF 'On exit 2 (scan failed), stop' && printf '%s' "$r3b2" | grep -qF 'do not dispatch' \
  && pass "resume-task 3b.2 stops on exit 2 without dispatching" || fail "resume-task 3b.2 does not stop on exit 2"
SCAN='atelier-worktree-create --scan-env <'
r4b="$(sect "$rt" '### 4b.')"
r4c="$(sect "$rt" '### 4c.')"
r3="$(sect "$rt" '### 3. ')"
for pair in "4b:$r4b" "4c:$r4c" "files-backend interrupted resume (step 3):$r3"; do
  label="${pair%%:*}"; body="${pair#*:}"
  printf '%s' "$body" | grep -qF -- "$SCAN" && pass "resume-task $label runs --scan-env before reuse" || fail "resume-task $label lacks --scan-env"
  printf '%s' "$body" | grep -qF 'Exit 2 → the scan failed: stop' && pass "resume-task $label stops on scan exit 2" || fail "resume-task $label lacks exit 2 stop"
done
printf '%s' "$r4c" | grep -qF 'If the worktree exists' && pass "resume-task 4c scans only when the worktree exists" || fail "resume-task 4c scan not conditioned on existing worktree"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "worktree-create-routing (#607): all assertions passed."
  exit 0
else
  echo "worktree-create-routing (#607): $fails assertion(s) failed."
  exit 1
fi
