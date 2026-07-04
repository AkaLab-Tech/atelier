#!/usr/bin/env bash
#
# Regression test for #7 — /atelier:abandon-task command.
#
# Asserts the following invariants so that future careless edits that
# silently drop or contradict these contracts fail CI:
#
#   Group 1 — command file + frontmatter
#     - `commands/abandon-task.md` exists
#     - frontmatter has `description:`, `argument-hint: "<id> [--yes|-y]"`, `allowed-tools:`
#   Group 2 — allowed-tools contract
#     - allowed-tools includes `gh pr close` and `git worktree`
#     - allowed-tools (and the whole file) never grants `git push`
#     - body never invokes `gh pr merge` or a raw `gh pr create`
#   Group 3 — closes without merging
#     - references `gh pr close` and `--delete-branch`
#     - never references `gh pr merge`
#   Group 4 — worktree + branch removal tolerating dirty
#     - references `git worktree remove --force` and `git branch -D`
#   Group 5 — backend-aware terminal tracking move
#     - references `moveTask` and the `in_progress` bucket
#     - references the Abandoned/Cancelled-if-present-else-Todo fallback contract
#   Group 6 — confirmation gate
#     - references `--yes` / `-y` and `ATELIER_AUTO`
#     - references `AskUserQuestion` for the interactive confirm path
#   Group 7 — hard refusals present before destruction
#     - not-in-flight refusal
#     - MERGED PR refusal
#     - protected / non-task/* branch refusal
#   Group 8 — stale [BLOCKED] issue closed
#     - references `gh issue close` for a `[BLOCKED] see #NN` task
#   Group 9 — cross-file: task-orchestrator forward-ref resolves
#     - `agents/task-orchestrator.md` references `/atelier:abandon-task`
#   Group 10 — PLAN.md §7 catalog entry
#     - `PLAN.md` contains an `abandon-task` entry in the command catalog
#
# Hermetic: all assertions run against committed files only — no network, no
# git/gh execution, no temp dirs persisted after exit.
#
# Run:  hooks/tests/abandon-task.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CMD="$REPO_ROOT/commands/abandon-task.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
PLAN="$REPO_ROOT/PLAN.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
# Passes when the fixed string is present in the file; fails otherwise.
# Uses `grep -e` so patterns starting with '-' (e.g. '--yes') are treated
# as fixed strings, never as grep options.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label>
# Passes when the fixed string is NOT present in the file; fails otherwise.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then
    fail "$label — unexpected token '$pattern' found in $file"
  else
    pass "$label"
  fi
}

# extract_bash_blocks <file>
# Prints the contents of every fenced ```bash ... ``` block in <file>.
extract_bash_blocks() {
  awk '/^```bash/{flag=1; next} /^```/{flag=0; next} flag' "$1"
}

# chk_absent_in_bash <file> <fixed-string> <label>
# Passes when the fixed string does NOT appear inside any fenced ```bash```
# code block (i.e. it is never actually invoked) — prose that documents the
# refusal (e.g. "never `gh pr merge`") outside a code block is allowed.
chk_absent_in_bash() {
  local file="$1" pattern="$2" label="$3"
  if extract_bash_blocks "$file" | grep -qF -e "$pattern"; then
    fail "$label — unexpected invocation of '$pattern' found in a bash code block of $file"
  else
    pass "$label"
  fi
}

# chk_regex <file> <ere-pattern> <label>
# Passes when the extended-regex pattern matches somewhere in the file.
chk_regex() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — regex '$pattern' not matched in $file"
  fi
}

# chk_regex_absent <file> <ere-pattern> <label>
# Passes when the extended-regex pattern does NOT match anywhere in the file.
chk_regex_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    fail "$label — unexpected match for regex '$pattern' in $file"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------------
# Group 1: command file + frontmatter
# ---------------------------------------------------------------------------

if [ -f "$CMD" ]; then
  pass "file: commands/abandon-task.md exists"
else
  fail "file: commands/abandon-task.md not found"
fi

chk_prose "$CMD" 'description:' \
  "frontmatter: description: key present"

chk_regex "$CMD" 'argument-hint: *"<id> \[--yes\|-y\]"' \
  "frontmatter: argument-hint: \"<id> [--yes|-y]\" present"

chk_prose "$CMD" 'allowed-tools:' \
  "frontmatter: allowed-tools: key present"

# ---------------------------------------------------------------------------
# Group 2: allowed-tools contract
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'Bash(gh pr close:' \
  "allowed-tools: grants Bash(gh pr close:*)"

chk_prose "$CMD" 'Bash(git worktree:' \
  "allowed-tools: grants Bash(git worktree:*)"

chk_absent "$CMD" 'Bash(git push' \
  "allowed-tools: NEVER grants Bash(git push — abandon never pushes"

chk_absent_in_bash "$CMD" 'gh pr merge' \
  "body: never invokes gh pr merge in a bash code block"

chk_regex_absent "$CMD" 'Bash\(gh pr create' \
  "allowed-tools: never grants a raw Bash(gh pr create:*) invocation"

chk_absent_in_bash "$CMD" 'gh pr create' \
  "body: never invokes gh pr create directly in a bash code block (delegated to pr-flow skill)"

# ---------------------------------------------------------------------------
# Group 3: closes the PR without merging
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'gh pr close' \
  "close-pr: references gh pr close"

chk_prose "$CMD" '--delete-branch' \
  "close-pr: references --delete-branch"

# (gh pr merge absence already asserted in Group 2; re-assert under this
# group's own label so the acceptance-criteria mapping is explicit)
chk_absent_in_bash "$CMD" 'gh pr merge' \
  "close-pr: never invokes gh pr merge in a bash code block"

# ---------------------------------------------------------------------------
# Group 4: worktree + local branch removal tolerating dirty
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'git worktree remove --force' \
  "worktree-removal: references git worktree remove --force"

chk_prose "$CMD" 'git branch -D' \
  "worktree-removal: references git branch -D"

# ---------------------------------------------------------------------------
# Group 5: backend-aware terminal tracking move
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'moveTask' \
  "tracking-move: references moveTask"

chk_prose "$CMD" 'in_progress' \
  "tracking-move: references the in_progress bucket"

chk_regex "$CMD" '(Abandoned|Cancelled)' \
  "tracking-move: references an Abandoned/Cancelled terminal state"

chk_prose "$CMD" 'fall back to' \
  "tracking-move: documents the Abandoned/Cancelled-else-Todo fallback"

# ---------------------------------------------------------------------------
# Group 6: confirmation gate — skipped only under non-interactive
# ---------------------------------------------------------------------------

chk_prose "$CMD" '--yes' \
  "confirm-gate: references --yes"

chk_prose "$CMD" '-y' \
  "confirm-gate: references -y"

chk_prose "$CMD" 'ATELIER_AUTO' \
  "confirm-gate: references ATELIER_AUTO"

chk_prose "$CMD" 'AskUserQuestion' \
  "confirm-gate: references AskUserQuestion for the interactive confirm path"

# ---------------------------------------------------------------------------
# Group 7: hard refusals present before destruction
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'is not in flight' \
  "hard-refusal: not-in-flight refusal present"

chk_prose "$CMD" 'MERGED' \
  "hard-refusal: MERGED PR refusal present"

chk_regex "$CMD" '(Protected or non-.task/\*.|does not start with .task/.)' \
  "hard-refusal: protected / non-task/* branch refusal present"

# ---------------------------------------------------------------------------
# Group 8: stale [BLOCKED] issue closed
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'gh issue close' \
  "blocked-issue: references gh issue close"

chk_prose "$CMD" '[BLOCKED]' \
  "blocked-issue: references the [BLOCKED] marker"

# ---------------------------------------------------------------------------
# Group 9: cross-file — task-orchestrator forward-ref resolves
# ---------------------------------------------------------------------------

chk_prose "$ORCH" '/atelier:abandon-task' \
  "cross-ref: agents/task-orchestrator.md references /atelier:abandon-task"

# ---------------------------------------------------------------------------
# Group 10: PLAN.md §7 catalog entry
# ---------------------------------------------------------------------------

chk_prose "$PLAN" '/abandon-task' \
  "PLAN.md §7: /abandon-task catalog entry present"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "abandon-task (#7): all assertions passed."
  exit 0
else
  echo "abandon-task (#7): $fails assertion(s) failed."
  exit 1
fi
