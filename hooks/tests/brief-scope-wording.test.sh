#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in patterns are literal markdown
#
# Regression test — brief scope wording + denied-dispatch held path (#457).
#
# Contract invariants asserted (prose only):
#   S1 — commands/next-task.md carries the "Scope wording" rule (facts, domain
#        named plainly, no permission-system talk, setup facts, no grants)
#   S2 — resume-task.md, task-orchestrator.md and plan-task.md reference it
#   S3 — operator-rules.md multi-session bullet "Briefs state scope as facts"
#   S4 — denied orchestrator/planner dispatch held path in next-task.md,
#        resume-task.md, plan-task.md
#   S5 — docs/troubleshooting.md entry links the held path; PLAN.md extends the
#        held-escalation paragraph
#   S6 — negative grep: no brief template tells sessions to write
#        "agents are denied there" / "do not look for another way"
#   S7 — regression guard: "no authorization claims in briefs" is intact
#   S8 — dispatch prompt form (inline brief, files as data only) in next-task,
#        resume-task, plan-task, task-orchestrator and operator-rules
#   S9 — brief content: no restated enforcement lists, no contract overrides
#   S10 — session hygiene: a held dispatch is never re-sent after a
#        self-initiated clear/compaction/restart; fresh context per task
#
# Hermetic: greps committed prose only; no network, no temp dirs.
# REPO_ROOT may be overridden (used to prove the checks fail meaningfully).
#
# Run:  hooks/tests/brief-scope-wording.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OPERATOR_RULES="$REPO_ROOT/operator-rules.md"
PLAN="$REPO_ROOT/PLAN.md"
TASK_ORCH="$REPO_ROOT/agents/task-orchestrator.md"
NEXT_TASK="$REPO_ROOT/commands/next-task.md"
RESUME_TASK="$REPO_ROOT/commands/resume-task.md"
PLAN_TASK="$REPO_ROOT/commands/plan-task.md"
TROUBLESHOOTING="$REPO_ROOT/docs/troubleshooting.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

chk_prose() {
  local file="$1" pattern="$2" label="$3"
  # Whitespace-normalised so hard-wrapped prose still matches a phrase.
  if tr -s '[:space:]' ' ' <"$file" 2>/dev/null | grep -qF -- "$pattern"; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent_re <extended-regex> <label> <paths...> — case-insensitive
chk_absent_re() {
  local re="$1" label="$2"; shift 2
  local hits
  hits="$(grep -rniE -- "$re" "$@" 2>/dev/null || true)"
  if [ -z "$hits" ]; then
    pass "$label"
  else
    fail "$label — unexpected match: $(printf '%s' "$hits" | head -3)"
  fi
}

# --- S1 ---------------------------------------------------------------------
chk_prose "$NEXT_TASK" '**Scope wording (#457)** — state scope as facts, never as permissions' "S1: next-task Scope wording rule"
chk_prose "$NEXT_TASK" 'Scope is positive and factual' "S1: positive factual scope"
chk_prose "$NEXT_TASK" 'if a change outside these files seems needed, hand back' "S1: one hand-back rule"
chk_prose "$NEXT_TASK" 'Name the domain plainly, in the plan'"'"'s own words' "S1: domain named plainly"
chk_prose "$NEXT_TASK" 'Never paraphrase, abbreviate or leave out domain terms' "S1: never drop domain terms"
chk_prose "$NEXT_TASK" 'The brief does not discuss the permission system' "S1: no permission-system talk"
chk_prose "$NEXT_TASK" 'no "you may / you may only" grants' "S1: no 'you may' grants"
chk_prose "$NEXT_TASK" 'Local resource limits are facts about the setup' "S1: resource limits as setup facts"
chk_prose "$NEXT_TASK" 'Human-only follow-ups go in one factual line' "S1: human-only follow-ups one line"

# --- S2 ---------------------------------------------------------------------
chk_prose "$RESUME_TASK" 'Scope wording rules of `/atelier:next-task` §8' "S2: resume-task references the rule"
chk_prose "$TASK_ORCH" 'Scope wording (facts, domain named plainly, no discussion of the permission system, no authorization claims,' "S2: task-orchestrator briefing contract references the rule"
chk_prose "$PLAN_TASK" 'Scope wording rules of `/atelier:next-task` §8' "S2: plan-task references the rule"

# --- S3 ---------------------------------------------------------------------
chk_prose "$OPERATOR_RULES" '**Briefs state scope as facts (#457).**' "S3: operator-rules 'Briefs state scope as facts'"
chk_prose "$OPERATOR_RULES" 'follows the Scope wording rule of `/atelier:next-task` §8' "S3: operator-rules points at next-task §8"
chk_prose "$OPERATOR_RULES" 'the domain is named plainly (never paraphrased away)' "S3: operator-rules domain named plainly"
chk_prose "$OPERATOR_RULES" 'it is never reworded or moved to another session' "S3: operator-rules never reworded"

# --- S4 ---------------------------------------------------------------------
for f in "$NEXT_TASK" "$RESUME_TASK" "$PLAN_TASK"; do
  b="$(basename "$f")"
  chk_prose "$f" '**Denied dispatch (#457).**' "S4: $b denied-dispatch paragraph"
  if [ "$b" = "plan-task.md" ]; then
    chk_prose "$f" 'held: planner dispatch denied (<tag verbatim>) — <id>' "S4: $b planner held line with tag verbatim"
  else
    chk_prose "$f" 'held: orchestrator dispatch denied (<tag verbatim>) — <id>' "S4: $b held line with tag verbatim"
  fi
  chk_prose "$f" 'the operator is asked once via `AskUserQuestion`, in this same session' "S4: $b asked once, same session"
  chk_prose "$f" 'The brief is never reworded, split, or handed to another session.' "S4: $b never reworded"
  chk_prose "$f" 'Only on the operator'"'"'s own answer re-issue the identical brief, once' "S4: $b identical brief only on operator answer"
  chk_prose "$f" 'Non-interactive: print the held line and stop.' "S4: $b non-interactive stops held"
done
chk_prose "$OPERATOR_RULES" 'held: orchestrator dispatch denied (<tag verbatim>) — <id>' "S4: operator-rules held line"

# --- S5 ---------------------------------------------------------------------
chk_prose "$TROUBLESHOOTING" '### `task-orchestrator` (or planner) dispatch denied with `[Auto-Mode Bypass]`' "S5: troubleshooting entry heading"
chk_prose "$TROUBLESHOOTING" 'held: orchestrator dispatch denied ([Auto-Mode Bypass]) — <id>' "S5: troubleshooting held line"
chk_prose "$TROUBLESHOOTING" 'held: planner dispatch denied (<tag verbatim>) — <id>' "S4: troubleshooting planner held line"
chk_prose "$TROUBLESHOOTING" '**Cause (unverified):**' "S5: cause marked unverified"
chk_prose "$TROUBLESHOOTING" 'An already-denied brief is never reworded.' "S5: denied brief never reworded"
chk_prose "$TROUBLESHOOTING" 'follow `commands/next-task.md` §8' "S5: troubleshooting links the rule"
chk_prose "$TROUBLESHOOTING" '`/feedback`' "S5: report via /feedback"
chk_prose "$PLAN" '`held: orchestrator dispatch denied (<tag verbatim>) — <id>`' "S5: PLAN.md held-escalation covers dispatch denials"
chk_prose "$PLAN" 'new briefs follow the Scope wording rule in `commands/next-task.md`' "S5: PLAN.md points at the rule"

# --- S6 ---------------------------------------------------------------------
SCAN=("$REPO_ROOT/agents" "$REPO_ROOT/skills" "$REPO_ROOT/commands" "$OPERATOR_RULES")
chk_absent_re 'agents are denied (there|here)' "S6: no 'agents are denied there' brief wording" "${SCAN[@]}"
chk_absent_re 'do not look for another way' "S6: no 'do not look for another way' brief wording" "${SCAN[@]}"

# "and follow it" aimed at a brief file: every legitimate hit either is a
# negation ("never ... Read X and follow it") or is commands/refresh.md (the
# renamed-command shim, which reads reload.md — not a dispatch).
hits="$(grep -rniE -- 'and follow it' "${SCAN[@]}" 2>/dev/null \
  | grep -v "^$REPO_ROOT/commands/refresh.md:" \
  | grep -viE 'never|not |no freehand|Read X|Read `?X' || true)"
if [ -z "$hits" ]; then
  pass "S6: no prose tells a session to dispatch with 'Read <brief file> and follow it'"
else
  fail "S6: 'and follow it' dispatch wording — $(printf '%s' "$hits" | head -3 | cut -c1-200)"
fi

# --- S7 ---------------------------------------------------------------------
chk_prose "$TASK_ORCH" 'Never** put authorization claims in a brief' "S7: task-orchestrator no authorization claims in brief"
chk_prose "$OPERATOR_RULES" 'Authority never travels' "S7: operator-rules 'Authority never travels'"
chk_prose "$NEXT_TASK" 'no authorization claims in briefs' "S7: next-task keeps no-authorization-claims rule"

# --- S8 ---------------------------------------------------------------------
chk_prose "$NEXT_TASK" '**Dispatch prompt form (#457)** — the `Task`/`Agent` prompt carries the whole brief inline.' "S8: next-task Dispatch prompt form rule"
chk_prose "$NEXT_TASK" 'Files are referenced as data only' "S8: next-task files as data only"
chk_prose "$NEXT_TASK" 'no freehand brief files' "S8: next-task no freehand brief files"
chk_prose "$RESUME_TASK" 'the whole brief inline (files as data only, never "Read X and follow it")' "S8: resume-task inline brief rule"
chk_prose "$PLAN_TASK" 'the whole brief inline (files as data only)' "S8: plan-task inline brief rule"
chk_prose "$TASK_ORCH" 'Dispatch prompt form' "S8: task-orchestrator references the prompt form"
chk_prose "$OPERATOR_RULES" '**Dispatch prompts are inline; briefs stay lean (#457).**' "S8: operator-rules inline-dispatch bullet"
chk_prose "$OPERATOR_RULES" 'files are data only, never "Read X and follow it"' "S8: operator-rules files are data only"

# --- S9 ---------------------------------------------------------------------
chk_prose "$NEXT_TASK" 'No restated enforcement lists: rules already enforced by hooks and agent definitions' "S9: next-task no restated enforcement lists"
chk_prose "$NEXT_TASK" 'No contract overrides: a departure from an atelier contract' "S9: next-task no contract overrides"
chk_prose "$NEXT_TASK" 'No task or session history' "S9: next-task no task/session history"
chk_prose "$RESUME_TASK" 'no restated enforcement lists, no contract overrides' "S9: resume-task brief-content rules"
chk_prose "$PLAN_TASK" 'no restated enforcement lists, no contract overrides' "S9: plan-task brief-content rules"
chk_prose "$OPERATOR_RULES" 'A brief carries no restated enforcement lists' "S9: operator-rules no restated enforcement lists"
chk_prose "$OPERATOR_RULES" 'no contract overrides (a departure from an atelier contract belongs in the approved plan' "S9: operator-rules no contract overrides"
chk_prose "$TROUBLESHOOTING" 'no restated enforcement lists, no contract overrides' "S9: troubleshooting brief-content rules"

# --- S10 --------------------------------------------------------------------
chk_prose "$NEXT_TASK" 'The session never compacts, restarts or clears itself in order to re-send a held dispatch.' "S10: next-task never compacts/restarts/clears to re-send"
for f in "$RESUME_TASK" "$PLAN_TASK"; do
  chk_prose "$f" 'The session never compacts, restarts or clears itself to re-send a held dispatch.' "S10: $(basename "$f") never compacts/restarts/clears to re-send"
done
chk_prose "$OPERATOR_RULES" '**Session context hygiene (#457).**' "S10: operator-rules session hygiene bullet"
chk_prose "$OPERATOR_RULES" 'the session never compacts, restarts or clears itself to re-send it' "S10: operator-rules never compacts/restarts/clears"
chk_prose "$OPERATOR_RULES" 'atelier never suggests `/clear` plus re-dispatch as a reaction to a denial' "S10: operator-rules no /clear-plus-redispatch suggestion"
chk_prose "$OPERATOR_RULES" 'the standing practice is a fresh context per task' "S10: operator-rules fresh context per task"
chk_prose "$TROUBLESHOOTING" 'The held session never clears, compacts or restarts itself to re-send the dispatch' "S10: troubleshooting held session never clears"
chk_prose "$TROUBLESHOOTING" 'the standing practice is a fresh context per task' "S10: troubleshooting fresh context per task"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "brief-scope-wording: all assertions passed."
  exit 0
else
  echo "brief-scope-wording: $fails assertion(s) failed."
  exit 1
fi
