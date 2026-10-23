#!/usr/bin/env bash
#
# Prose pin for #577 — the no-orphaned-sub-agents contract lives in markdown
# and config the model reads, so a silent edit would defeat it. Pins:
#   agents/task-orchestrator.md, commands/resume-task.md (step 2b),
#   operator-rules.md (lifecycle subsection), hooks/hooks.json registrations,
#   install.sh helper symlink.
#
# Hermetic: greps repo files only. Requires jq for hooks.json.
#
# Run:  hooks/tests/orchestrator-handback-prose.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="$REPO_ROOT/agents/task-orchestrator.md"
RESUME="$REPO_ROOT/commands/resume-task.md"
RULES="$REPO_ROOT/operator-rules.md"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
INSTALL="$REPO_ROOT/install.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   - $1"; }
bad() { fail=$((fail+1)); echo "  FAIL - $1"; }
contains() { # label file fixed-string
  if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 (missing: $3)"; fi
}
count_is() { # label file fixed-string expected
  local n; n="$(grep -cF -- "$3" "$2")"
  if [ "$n" = "$4" ]; then ok "$1"; else bad "$1 (expected $4 lines, got $n: $3)"; fi
}

echo "== agents/task-orchestrator.md"
fm_tools="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f && /^tools:/ {print; exit}' "$AGENT")"
case "$fm_tools" in *'"TaskStop"'*) ok "frontmatter tools include TaskStop" ;; *) bad "frontmatter tools lack TaskStop: $fm_tools" ;; esac
contains "ledger section heading" "$AGENT" "## Sub-agent ledger"
contains "dispatch-ledger rule" "$AGENT" "**Dispatch-ledger rule.**"
contains "dispatch rule records start" "$AGENT" "atelier-subagent-ledger start --worktree <wt> --agent-id <id> --type <agent-type> --step <step>"
contains "completion records finish" "$AGENT" "atelier-subagent-ledger finish --agent-id <id> --state done"
contains "drain-before-handback rule" "$AGENT" "**Drain before handback.**"
contains "drain checks live" "$AGENT" "atelier-subagent-ledger live --worktree <wt>"
contains "wait option never sleeps" "$AGENT" "Waiting means ending the turn, never \`sleep\`, never polling, never a loop."
contains "stop option uses TaskStop then records stopped" "$AGENT" "atelier-subagent-ledger finish --agent-id <id> --state stopped"
contains "disclose option" "$AGENT" "**Disclose.**"
count_is "Live sub-agents Output line in both report variants" "$AGENT" '- Live sub-agents: `none` | `<agent_id> (<type>, <step>)' 2
contains "Output line exactness note" "$AGENT" 'the line must be `Live sub-agents:` exactly'
contains "Decision rule: never hand back with live child" "$AGENT" "Never** hand back while the ledger shows a live child you neither waited for, stopped, nor disclosed."

echo "== commands/resume-task.md step 2b"
contains "step 2b heading" "$RESUME" "### 2b. Live sub-agent preflight"
contains "always-hold wording" "$RESUME" 'held: live sub-agent(s) from a previous run in'
contains "no selector for this case" "$RESUME" "**Never open a selector**"
contains "interactive mode included in hold" "$RESUME" "in **every** mode, interactive included"
contains "--ignore-live in argument-hint" "$RESUME" 'argument-hint: "<task-id> [--yes|-y] [--ignore-live]"'
contains "--ignore-live flag documented" "$RESUME" '`--ignore-live` given:'
contains "superseded-by-resume state" "$RESUME" "--state superseded-by-resume"
contains "ledger helper allowed" "$RESUME" "Bash(atelier-subagent-ledger:*)"
contains "never-proceed rule without selector" "$RESUME" "never ask about it with a selector, in any mode"
step2b="$(awk '/^### 2b\./{f=1;next} /^###? /{f=0} f' "$RESUME")"
case "$step2b" in *AskUserQuestion*) bad "step 2b mentions AskUserQuestion" ;; *) ok "step 2b never mentions AskUserQuestion" ;; esac
case "$step2b" in *"never done here with a sleep or a poll"*) ok "step 2b rules out sleep/poll waiting" ;; *) bad "step 2b lacks the no-sleep/poll sentence" ;; esac

echo "== operator-rules.md"
contains "lifecycle subsection heading" "$RULES" "### Sub-agent lifecycle: no orphaned children"
sub="$(awk '/^### Sub-agent lifecycle: no orphaned children/{f=1;next} f && /^#{1,3} /{f=0} f' "$RULES")"
[ -n "$sub" ] && ok "subsection body extracted" || bad "subsection body empty"
case "$sub" in *"Live sub-agents:"*) ok "subsection names the Live sub-agents: line" ;; *) bad "subsection lacks Live sub-agents:" ;; esac
case "$sub" in *"never a \`sleep\`, a poll or a wait loop"*) ok "subsection forbids sleep/poll/wait loop" ;; *) bad "subsection lacks the no sleep/poll/wait-loop sentence" ;; esac
# Outside that one negative sentence, no instruction to sleep/poll/loop.
stripped="$(printf '%s\n' "$sub" | sed 's/never a `sleep`, a poll or a wait loop//; s/so nothing needs polling//')"
if printf '%s' "$stripped" | grep -Eiq 'sleep|poll|while[[:space:]]+(true|\[|:)|wait loop'; then
  bad "subsection contains sleep/poll/while-loop wording beyond the prohibition"
else
  ok "subsection has no sleep/poll/while-loop wording beyond the prohibition"
fi

echo "== hooks/hooks.json"
if command -v jq >/dev/null 2>&1; then
  n="$(jq '[.hooks.SubagentStop[]?.hooks[]?.command | select(test("hooks/subagent-ledger\\.sh$"))] | length' "$HOOKS_JSON")"
  [ "$n" = "1" ] && ok "SubagentStop registers subagent-ledger.sh" || bad "SubagentStop registration count: $n"
  n="$(jq '[.hooks.PreToolUse[]? | select(.matcher == "SubagentHandback") | .hooks[]?.command | select(test("hooks/subagent-ledger\\.sh$"))] | length' "$HOOKS_JSON")"
  [ "$n" = "1" ] && ok "PreToolUse SubagentHandback registers subagent-ledger.sh" || bad "PreToolUse SubagentHandback registration count: $n"
else
  bad "jq missing; cannot check hooks.json"
fi
[ -x "$REPO_ROOT/hooks/subagent-ledger.sh" ] && ok "hooks/subagent-ledger.sh is executable" || bad "hooks/subagent-ledger.sh not executable"

echo "== install.sh"
contains "helper symlinked in phase C.1" "$INSTALL" "_phase_c_1_symlink_helper atelier-subagent-ledger"

echo
echo "orchestrator-handback-prose: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
