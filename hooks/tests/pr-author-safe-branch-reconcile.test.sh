#!/usr/bin/env bash
#
# Regression test for #33 — pr-author reconciles a diverged remote task branch
# non-destructively (force-with-lease), never by deleting the remote branch.
#
# Root cause: pr-author.md gave no guidance for a non-fast-forward push to an
# already-existing remote task/* branch, while forbidding all `--force`. Faced
# with a diverged remote branch, the agent improvised
# `git push origin --delete task/<id>-<slug>` to "clean" it and re-push — a
# destructive remote operation the auto-mode classifier blocks mid-chain
# (observed in deminut #28: 3 consecutive blocked actions, chain stalled).
#
# Contract invariants asserted:
#   Group 1 — agents/pr-author.md: safe reconciliation prescribed
#     - force-with-lease on the task branch is the prescribed reconciliation
#     - the non-fast-forward case is named explicitly
#     - the destructive delete (push origin --delete) is explicitly forbidden
#     - the colon-ref delete form is named as forbidden
#   Group 2 — templates/settings.template.json: static matrix matches the prose
#     - valid JSON
#     - the over-broad `Bash(git push --force*)` deny is GONE (it would also
#       block the now-prescribed --force-with-lease)
#     - hard force is still denied (narrowed: bare + space forms, plus -f*)
#     - remote-branch deletion is denied (--delete / colon form)
#     - --force-with-lease origin task/* is allowed
#   Group 3 — PLAN.md §3 records the carve-out
#     - the force-with-lease exception is documented
#     - the remote-branch-delete deny is documented
#
# Hermetic: all assertions run against committed files only — no network.
#
# Run:  hooks/tests/pr-author-safe-branch-reconcile.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PR_AUTHOR="$REPO_ROOT/agents/pr-author.md"
SETTINGS="$REPO_ROOT/templates/settings.template.json"
PLAN="$REPO_ROOT/PLAN.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label>
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' is still present in $file"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------------
# Group 1: agents/pr-author.md — safe reconciliation prescribed
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" 'git push --force-with-lease origin task/<id>-<slug>' \
  "pr-author: prescribes --force-with-lease on the task branch to reconcile divergence"

chk_prose "$PR_AUTHOR" 'non-fast-forward' \
  "pr-author: names the non-fast-forward push case explicitly"

chk_prose "$PR_AUTHOR" 'git push origin --delete task/<id>-<slug>' \
  "pr-author: names the destructive 'push origin --delete' so it can forbid it"

chk_prose "$PR_AUTHOR" 'colon form' \
  "pr-author: names the colon-ref delete form as forbidden too"

# ---------------------------------------------------------------------------
# Group 2: templates/settings.template.json — static matrix matches the prose
# ---------------------------------------------------------------------------

if jq -e . "$SETTINGS" >/dev/null 2>&1; then
  pass "settings.template.json: valid JSON"

  # The over-broad force deny must be gone — it also matches --force-with-lease.
  if jq -e '.permissions.deny | index("Bash(git push --force*)")' "$SETTINGS" >/dev/null 2>&1; then
    fail "settings.template.json: over-broad 'Bash(git push --force*)' deny still present (would block --force-with-lease)"
  else
    pass "settings.template.json: over-broad 'Bash(git push --force*)' deny removed"
  fi

  for entry in \
    'Bash(git push --force)' \
    'Bash(git push --force *)' \
    'Bash(git push -f*)' \
    'Bash(git push * --delete *)' \
    'Bash(git push * -d *)' \
    'Bash(git push origin :*)'; do
    if jq -e --arg e "$entry" '.permissions.deny | index($e)' "$SETTINGS" >/dev/null 2>&1; then
      pass "settings.template.json: deny contains '$entry'"
    else
      fail "settings.template.json: deny is missing '$entry'"
    fi
  done

  if jq -e '.permissions.allow | index("Bash(git push --force-with-lease origin task/*)")' "$SETTINGS" >/dev/null 2>&1; then
    pass "settings.template.json: allow contains '--force-with-lease origin task/*'"
  else
    fail "settings.template.json: allow is missing '--force-with-lease origin task/*'"
  fi
else
  fail "settings.template.json: not valid JSON"
fi

# ---------------------------------------------------------------------------
# Group 3: PLAN.md §3 records the carve-out
# ---------------------------------------------------------------------------

chk_prose "$PLAN" 'git push --force-with-lease origin task/*' \
  "PLAN §3: documents the --force-with-lease task-branch exception"

chk_prose "$PLAN" 'git push origin :*' \
  "PLAN §3: documents the remote-branch-delete deny (colon form)"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "pr-author-safe-branch-reconcile (#33): all assertions passed."
  exit 0
else
  echo "pr-author-safe-branch-reconcile (#33): $fails assertion(s) failed."
  exit 1
fi
