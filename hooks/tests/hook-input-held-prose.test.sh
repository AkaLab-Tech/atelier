#!/usr/bin/env bash
#
# Prose pin for #691 — a dispatch refused with "a hook changed this call's
# input" ends in a distinct held line naming the plugin hook, and is recorded
# with tag hook-changed-input. The contract lives in markdown the model reads,
# so a silent edit would defeat it. Pins commands/next-task.md,
# commands/plan-task.md, commands/resume-task.md, agents/task-orchestrator.md,
# operator-rules.md, docs/troubleshooting.md and the helper usage.
#
# Hermetic: greps repo files only.
#
# Run:  hooks/tests/hook-input-held-prose.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NEXT="$REPO_ROOT/commands/next-task.md"
PLAN="$REPO_ROOT/commands/plan-task.md"
RESUME="$REPO_ROOT/commands/resume-task.md"
AGENT="$REPO_ROOT/agents/task-orchestrator.md"
RULES="$REPO_ROOT/operator-rules.md"
TROUBLE="$REPO_ROOT/docs/troubleshooting.md"
HELPER="$REPO_ROOT/scripts/atelier-dispatch-denial"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   - $1"; }
bad() { fail=$((fail+1)); echo "  FAIL - $1"; }
contains() { # label file fixed-string
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 (missing: $3)"; fi
}

TRIGGER="a hook changed this call's input"
HELD='held: <agent> dispatch refused — plugin hook <plugin_key> rewrites Agent input (hook-changed-input) — <id>'
SPEC_HELD='held: <specialist> dispatch refused — plugin hook <plugin_key> rewrites Agent input (hook-changed-input) — <task-id>'

echo "== commands/next-task.md"
contains "trigger substring" "$NEXT" "$TRIGGER"
contains "sub-rule heading" "$NEXT" "**Hook-rewritten input.**"
contains "detect command" "$NEXT" "atelier-agent-input-hooks detect --project <root>"
contains "unknown fallback" "$NEXT" "\`unknown\` (with a warning)"
contains "held-line template" "$NEXT" "$HELD"
contains "record tag and hook" "$NEXT" "--tag 'hook-changed-input' --hook '<plugin_key>'"
contains "regression: generic orchestrator held line" "$NEXT" "held: orchestrator dispatch denied (<tag verbatim>) — <id>"

echo "== commands/plan-task.md"
contains "trigger substring" "$PLAN" "$TRIGGER"
contains "pointer to next-task section" "$PLAN" "\"Hook-rewritten input\""
contains "planner agent" "$PLAN" "(\`<agent>\` = \`planner\`)"
contains "record tag" "$PLAN" "--tag 'hook-changed-input' --hook"
contains "regression: generic planner held line" "$PLAN" "held: planner dispatch denied (<tag verbatim>) — <id>"

echo "== commands/resume-task.md"
contains "trigger substring" "$RESUME" "$TRIGGER"
contains "pointer to next-task section" "$RESUME" "\"Hook-rewritten input\""
contains "orchestrator agent" "$RESUME" "(\`<agent>\` = \`task-orchestrator\`)"
contains "record tag" "$RESUME" "--tag 'hook-changed-input' --hook"
contains "regression: generic orchestrator held line" "$RESUME" "held: orchestrator dispatch denied (<tag verbatim>) — <id>"

echo "== agents/task-orchestrator.md"
contains "trigger substring" "$AGENT" "$TRIGGER"
contains "specialist held line" "$AGENT" "$SPEC_HELD"
contains "budget-exempt" "$AGENT" "terminal held state** — budget-exempt, no \`retry-with-logs\`, no \`unblocker\`"
contains "record command" "$AGENT" "atelier-dispatch-denial record --project <main_checkout_root> --command task-orchestrator --agent <specialist> --task <id> --tag 'hook-changed-input' --hook '<plugin_key>' --attempt <1|2> --prompt-file <path> --session-role unknown"
contains "prompt scratch path" "$AGENT" "<wt>/.task-log/tmp/dispatch-<specialist>.md"
n="$(grep -cF -- "\`held: <specialist> dispatch refused — plugin hook <plugin_key> rewrites Agent input (hook-changed-input) — <task-id>\`" "$AGENT")"
if [ "$n" -ge 2 ]; then ok "held line listed in both handback Status lists (found on $n lines)"; else bad "held line in Status lists (expected >=2 lines, got $n)"; fi

echo "== operator-rules.md"
contains "distinct held line sentence" "$RULES" "the distinct held line naming the plugin hook"
contains "record tag" "$RULES" "recorded with tag \`hook-changed-input\`"

echo "== docs/troubleshooting.md"
contains "held line" "$TROUBLE" "$HELD"
contains "report tag" "$TROUBLE" "atelier-dispatch-denial report"
contains "re-issue documented (#690)" "$TROUBLE" "re-issued once automatically and verbatim"

echo "== scripts/atelier-dispatch-denial"
contains "--hook in usage" "$HELPER" "[--hook <plugin_key[,plugin_key...]>]"

echo ""
echo "hook-input-held-prose: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
