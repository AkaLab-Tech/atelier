#!/usr/bin/env bash
#
# Prose pin for #690 — a dispatch refused with "a hook changed this call's
# input" is re-issued once, verbatim, in the very next response (approved #457
# exception); a second refusal ends in the #691 held line. The contract lives
# in markdown the model reads, so a silent edit would defeat it.
#
# Hermetic: greps repo files only.
#
# Run:  hooks/tests/hook-input-reissue-prose.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
C="$REPO_ROOT/commands"; A="$REPO_ROOT/agents"
NEXT="$C/next-task.md"
AGENT="$A/task-orchestrator.md"
RULES="$REPO_ROOT/operator-rules.md"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   - $1"; }
bad() { fail=$((fail+1)); echo "  FAIL - $1"; }
contains() { # label file fixed-string
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 (missing: $3)"; fi
}

TRIGGER="a hook changed this call's input"
POINTER="If this dispatch is refused with 'a hook changed this call's input', follow \`/atelier:next-task\` §8 (one verbatim re-issue, then the held line)."

echo "== commands/next-task.md §8"
contains "sub-rule heading" "$NEXT" "**Hook-rewritten input: one automatic re-issue (#457 exception).**"
contains "trigger substring" "$NEXT" "$TRIGGER"
contains "once, next response" "$NEXT" "once, in the very next response"
contains "no tool call between" "$NEXT" "no other tool call between"
contains "no second re-issue" "$NEXT" "no second automatic re-issue"
contains "not an attempt" "$NEXT" "not an attempt"
contains "no selector on second refusal" "$NEXT" "no operator selector is shown for this refusal kind"
contains "never a third call" "$NEXT" "never issued a third time"
contains "record choice" "$NEXT" "--choice auto-reissue --reissue accepted|denied"
contains "neutralised: as first issued (#729)" "$NEXT" "re-issue the call exactly as first issued (the block-free brief), never the hook-produced input"
contains "other plugins: hook-produced input (#729)" "$NEXT" "(b) any other plugin hook: re-issue the hook-produced input verbatim"
contains "brief never includes block" "$NEXT" "A brief never includes a block of the form the context-mode plugin appends"
contains "regression: operator-answer rule" "$NEXT" "Only on the operator's own answer re-issue the identical brief, once"
contains "regression: generic orchestrator held line" "$NEXT" "held: orchestrator dispatch denied (<tag verbatim>) — <id>"
contains "regression: #691 held line" "$NEXT" "held: <agent> dispatch refused — plugin hook <plugin_key> rewrites Agent input (hook-changed-input) — <id>"

echo "== commands/plan-task.md, resume-task.md"
contains "plan-task: re-issue sentence" "$C/plan-task.md" "is first re-issued once automatically per \`/atelier:next-task\` §8"
contains "resume-task: re-issue sentence" "$C/resume-task.md" "is first re-issued once automatically per \`/atelier:next-task\` §8"
contains "regression: planner held line" "$C/plan-task.md" "held: planner dispatch denied (<tag verbatim>) — <id>"
contains "regression: resume held line" "$C/resume-task.md" "held: orchestrator dispatch denied (<tag verbatim>) — <id>"
contains "regression: plan operator-answer" "$C/plan-task.md" "Only on the operator's own answer re-issue the identical brief, once"
contains "regression: resume operator-answer" "$C/resume-task.md" "Only on the operator's own answer re-issue the identical brief, once"

echo "== pointers"
for f in "$C/release.md" "$C/babysit-prs.md" "$C/finish-task.md" "$C/abandon-task.md" "$A/pr-opener.md" "$A/planner.md"; do
  contains "pointer in $(basename "$f")" "$f" "$POINTER"
done
n="$(grep -cF -- "$POINTER" "$C/release.md")"
if [ "$n" -ge 3 ]; then ok "release.md pointer at steps 6, 7, 8b.3 ($n)"; else bad "release.md pointers (expected >=3, got $n)"; fi

echo "== agents/task-orchestrator.md"
contains "re-issue bullet" "$AGENT" "re-issue the call **once**"
contains "neutralised: as first issued" "$AGENT" "exactly as first issued (the block-free brief), never the hook-produced input"
contains "other plugins: hook-produced input" "$AGENT" "for any other plugin hook, the hook-produced input verbatim"
contains "record auto-reissue" "$AGENT" "--choice auto-reissue --reissue accepted|denied"
contains "record attempt 1 from orchestrator" "$AGENT" "--command task-orchestrator --agent <specialist> --task <id> --tag 'hook-changed-input' --hook '<plugin_key>' --attempt 1"
contains "not an attempt" "$AGENT" "It is **not an attempt**"
contains "ledger only for accepted" "$AGENT" "runs only for the accepted call"
contains "contract (g)" "$AGENT" "(g) specialist briefs never include a \`context_window_protection\` block"
contains "Never-rule carve-out" "$AGENT" "is the sole carve-out from re-sending a refused dispatch"
contains "second refusal terminal" "$AGENT" "is refused again with text containing"

echo "== operator-rules.md"
contains "exception sentence" "$RULES" "Exception (approved #457 exception, product lead, 2026-11-03)"
contains "no answer needed" "$RULES" "is the only case needing no"
contains "briefs never pre-include block" "$RULES" "never pre-includes a \`context_window_protection\`"

echo "== the 'appended twice' wording is gone (#729)"
for f in "$NEXT" "$AGENT" "$RULES" "$REPO_ROOT/docs/troubleshooting.md"; do
  if grep -qiE "arrives twice|block twice|including any context-window-protection block" "$f"; then bad "stale 'twice' wording in $(basename "$f")"; else ok "no 'twice' wording in $(basename "$f")"; fi
done

echo "== no literal appended block inside a command or agent file"
if grep -ln -- "<context_window_protection>" "$C"/*.md "$A"/*.md >/dev/null 2>&1; then
  bad "literal <context_window_protection> found in: $(grep -ln -- '<context_window_protection>' "$C"/*.md "$A"/*.md | tr '\n' ' ')"
else ok "no command/agent file embeds the block"; fi

echo ""
echo "hook-input-reissue-prose: $pass passed, $fail failed."
[ "$fail" -eq 0 ]
