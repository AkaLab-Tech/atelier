#!/usr/bin/env bash
#
# Regression test — top-level sessions only orchestrate (#439 / #405a).
#
# Static doc-contract assertions: /finish-task and the blocked-resume path of
# /resume-task must not commit, push or open a PR from the top-level session;
# they dispatch task-orchestrator (non-task PR coordination mode) instead.
# operator-rules.md must no longer carry the /finish-task "benign exception".
# (commands/align.md `ask` and the operator-rules section are covered in
# pr-opener-delegation.test.sh.)

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FINISH="$ROOT/commands/finish-task.md"
RESUME="$ROOT/commands/resume-task.md"
RULES="$ROOT/operator-rules.md"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

# allowed-tools frontmatter line of a command file
tools_of() { grep -m1 '^allowed-tools:' "$1"; }

has() { grep -qF -- "$2" "$1"; }

# --- finish-task -----------------------------------------------------------
FT_TOOLS="$(tools_of "$FINISH")"
for forbidden in 'Bash(git commit' 'Bash(git push' 'Bash(gh pr create' 'Bash(git add'; do
  if printf '%s' "$FT_TOOLS" | grep -qF -- "$forbidden"; then
    fail "finish-task: allowed-tools still grants $forbidden"
  else
    pass "finish-task: allowed-tools does not grant $forbidden"
  fi
done

if printf '%s' "$FT_TOOLS" | grep -qE '(^|[ ,])Task(,|$)'; then
  pass "finish-task: allowed-tools grants Task (needed to dispatch task-orchestrator)"
else
  fail "finish-task: allowed-tools lacks Task"
fi

if has "$FINISH" 'Dispatch the `task-orchestrator` agent via `Task`' \
  && has "$FINISH" '`mode: non-task-pr`' \
  && has "$FINISH" '`author_agent: pr-author`'; then
  pass "finish-task: body dispatches task-orchestrator in non-task-pr mode with author_agent: pr-author"
else
  fail "finish-task: body does not dispatch task-orchestrator non-task-pr with author_agent: pr-author"
fi

if has "$FINISH" 'No `task_id`'; then
  pass "finish-task: forbids passing task_id (would re-run the standard task chain)"
else
  fail "finish-task: missing the no-task_id rule"
fi

if has "$FINISH" '**Never** commit, push, or run `gh pr create` from this command'; then
  pass "finish-task: hard refusal against inline commit/push/gh pr create"
else
  fail "finish-task: hard refusal against inline commit/push/gh pr create missing"
fi

# No executable inline step: no fenced/indented git commit|push or gh pr create command lines.
if grep -nE '^[[:space:]]*(git (add|commit|push)|gh pr create)( |$)' "$FINISH" >/dev/null; then
  fail "finish-task: still contains an inline git add/commit/push or gh pr create command line"
else
  pass "finish-task: no inline git add/commit/push or gh pr create command line"
fi

if has "$FINISH" 'Open the PR — `pr-flow` skill'; then
  fail "finish-task: old inline 'Open the PR — pr-flow skill' step still present"
else
  pass "finish-task: old inline pr-flow PR-opening step removed"
fi

# --- resume-task (blocked-resume docs PR) ----------------------------------
RS_TOOLS="$(tools_of "$RESUME")"
for forbidden in 'Bash(git commit' 'Bash(git push' 'Bash(gh pr create' 'Bash(git add' 'Bash(git checkout'; do
  if printf '%s' "$RS_TOOLS" | grep -qF -- "$forbidden"; then
    fail "resume-task: allowed-tools still grants $forbidden"
  else
    pass "resume-task: allowed-tools does not grant $forbidden"
  fi
done

if printf '%s' "$RS_TOOLS" | grep -qE '(^|[ ,])Task(,|$)'; then
  pass "resume-task: allowed-tools still grants Task"
else
  fail "resume-task: allowed-tools lacks Task"
fi

if has "$RESUME" 'dispatch `task-orchestrator` via `Task` in **non-task PR coordination mode**' \
  && has "$RESUME" 'head: docs/resume-<id>' \
  && has "$RESUME" 'Do **not** pass a `task_id`'; then
  pass "resume-task: blocked-resume docs PR delegates to task-orchestrator non-task mode (head docs/resume-<id>, no task_id)"
else
  fail "resume-task: blocked-resume docs PR does not delegate to task-orchestrator non-task mode"
fi

if grep -nE '^[[:space:]]*(git (add|commit|push|checkout)|gh pr create)( |$)' "$RESUME" >/dev/null; then
  fail "resume-task: still contains an inline git add/commit/push/checkout or gh pr create command line"
else
  pass "resume-task: no inline git add/commit/push/checkout or gh pr create command line"
fi

if has "$RESUME" 'git worktree add -b docs/resume-<id>'; then
  pass "resume-task: unmark edit is prepared in a temporary docs/resume-<id> worktree"
else
  fail "resume-task: temporary docs/resume-<id> worktree step missing"
fi

# --- operator-rules ---------------------------------------------------------
if grep -qi 'benign exception' "$RULES"; then
  fail "operator-rules: 'benign exception' for /finish-task still present"
else
  pass "operator-rules: 'benign exception' removed"
fi

if has "$RULES" '### Top-level sessions only orchestrate'; then
  pass "operator-rules: 'Top-level sessions only orchestrate' section present"
else
  fail "operator-rules: 'Top-level sessions only orchestrate' section missing"
fi

if has "$RULES" 'R1 — plan/tracking commits' && has "$RULES" '`.plan/**`' && has "$RULES" 'R2 — release tag' && has "$RULES" '`origin v*`'; then
  pass "operator-rules: orchestrate-only section carries the plan/tracking commit and origin v* tag carve-outs"
else
  fail "operator-rules: orchestrate-only section lacks the R1/R2 carve-outs"
fi

if has "$RULES" 'Known gap (pre-enforcement)' && has "$RULES" '/atelier:release' && has "$RULES" '#440'; then
  pass "operator-rules: documents the /release step 6 known gap (reroute before #440)"
else
  fail "operator-rules: lacks the /release known-gap note naming #440"
fi

if has "$FINISH" 'AskUserQuestion' && ! has "$FINISH" 'push_gate_partial_confirmed'; then
  pass "finish-task: confirms a PARTIAL gate itself, no hand-off flag"
else
  fail "finish-task: PARTIAL confirmation missing or stale push_gate_partial_confirmed flag"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "orchestrate-only-reroutes: all assertions passed."
  exit 0
else
  echo "orchestrate-only-reroutes: $fails assertion(s) failed."
  exit 1
fi
