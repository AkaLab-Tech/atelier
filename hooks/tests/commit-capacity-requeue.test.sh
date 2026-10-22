#!/usr/bin/env bash
#
# Regression test for #524 — a commit held for machine capacity is re-issued,
# never abandoned, and never preceded by a CPU pre-check.
#
# Root cause pattern this guards against: the safe-commit hook blocks with
# `BLOCKED — CPU slot busy ...` and "re-run the same commit, it waits again",
# but no agent was told to re-run it; and agents ran their own pgrep / load
# reads / atelier-cpu-slot --status before committing, a second, unbounded wait
# on top of the hook's bounded queue. The fix: (a) pr-author, pr-opener and
# task-orchestrator carry the re-issue rule and the `capacity-held` terminal
# state; (b) no agent, skill or operator rule instructs a pre-commit CPU check;
# (c) the cap `safeCommit.capacityRequeues` ships in the template (default 8);
# (d) every rc-75 block message in hooks/safe-commit.sh starts with
# `BLOCKED — CPU `, the token the agents match on.
#
# Hermetic: greps committed prose and jq-parses the committed template; no
# network, no temp dirs.
#
# Run:  hooks/tests/commit-capacity-requeue.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

# shellcheck disable=SC2015,SC2016 # `A && pass || fail` idiom; backticks are literal prose tokens
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUTHOR="$REPO_ROOT/agents/pr-author.md"
OPENER="$REPO_ROOT/agents/pr-opener.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
RETRY="$REPO_ROOT/skills/retry-with-logs/SKILL.md"
SC_SKILL="$REPO_ROOT/skills/safe-commit/SKILL.md"
RULES="$REPO_ROOT/operator-rules.md"
TEMPLATE="$REPO_ROOT/templates/atelier.template.json"
HOOK="$REPO_ROOT/hooks/safe-commit.sh"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

for f in "$AUTHOR" "$OPENER" "$ORCH" "$RETRY" "$SC_SKILL" "$RULES" "$TEMPLATE" "$HOOK"; do
  [ -f "$f" ] || { echo "  FAIL: $f not found"; exit 1; }
done

# ---------------------------------------------------------------------------
echo "Group 1 — pr-author: re-issue rule and capacity-held terminal state"
chk_prose "$AUTHOR" 'BLOCKED — CPU ' "pr-author: names the BLOCKED — CPU token"
chk_prose "$AUTHOR" 're-issue the identical commit' "pr-author: re-issue the identical commit"
chk_prose "$AUTHOR" 'no sleep, no poll' "pr-author: no sleep, no poll between re-issues"
chk_prose "$AUTHOR" 'no change to the command' "pr-author: command unchanged between re-issues"
chk_prose "$AUTHOR" '`capacity-held`' "pr-author: capacity-held terminal state"
chk_prose "$AUTHOR" '"status":"capacity-held"' "pr-author: capacity-held return shape"
chk_prose "$AUTHOR" 'safeCommit.capacityRequeues' "pr-author: cap is safeCommit.capacityRequeues"
chk_prose "$AUTHOR" 'default 8' "pr-author: cap default is 8"
chk_prose "$AUTHOR" 'A capacity block is not a failed attempt' "pr-author: a capacity block is not a failed attempt"

echo "Group 2 — pr-opener: re-issue rule and held status"
chk_prose "$OPENER" 'BLOCKED — CPU ' "pr-opener: names the BLOCKED — CPU token"
chk_prose "$OPENER" 're-issue the identical commit' "pr-opener: re-issue the identical commit"
chk_prose "$OPENER" 'no sleep, no poll' "pr-opener: no sleep, no poll between re-issues"
chk_prose "$OPENER" 'no change to the command' "pr-opener: command unchanged between re-issues"
chk_prose "$OPENER" 'held: CPU capacity unavailable after <n>s' "pr-opener: held status line"
chk_prose "$OPENER" 'safeCommit.capacityRequeues' "pr-opener: cap is safeCommit.capacityRequeues"
chk_prose "$OPENER" 'A capacity block is not a failed attempt' "pr-opener: a capacity block is not a failed attempt"

echo "Group 3 — task-orchestrator and retry-with-logs: held, budget-exempt"
chk_prose "$ORCH" '`capacity-held`' "task-orchestrator: handles capacity-held"
chk_prose "$ORCH" 'held: CPU capacity unavailable' "task-orchestrator: surfaces the held status"
chk_prose "$ORCH" 'budget-exempt' "task-orchestrator: capacity hold is budget-exempt"
chk_prose "$ORCH" 'do **not** invoke `retry-with-logs`' "task-orchestrator: no retry-with-logs attempt log"
chk_prose "$ORCH" 'do **not** re-dispatch `pr-author`' "task-orchestrator: no pr-author re-dispatch"
chk_prose "$ORCH" '/atelier:resume-task' "task-orchestrator: resume path named"
chk_prose "$RETRY" "### What is not an attempt" "retry-with-logs: has the not-an-attempt section"
chk_prose "$RETRY" "CPU-capacity hold (\`pr-author\` \`capacity-held\`" "retry-with-logs: lists the CPU-capacity hold as not an attempt"
chk_prose "$RULES" "A CPU-capacity block on commit is not a failed attempt" "operator-rules: capacity block is not a failed attempt"
chk_prose "$RETRY" 'consume none of the six attempts' "retry-with-logs: consumes none of the six attempts"

# ---------------------------------------------------------------------------
echo "Group 4 — nobody is told to run a pre-commit CPU check"
# Instruction lines: any mention of pgrep / uptime / a load read / the helper's
# --status or --wait. A line is acceptable only when it carries a negation
# (never / no / not / don't / without): the new text names these in negated
# form. Everything else would be an instruction to run them.
CPU_CHECK_RE='pgrep|uptime|loadavg|load average|load read|cpu-slot[^|]*--(status|wait)'
NEG_RE="(^|[^a-z])(never|no|not|don't|without|nor)([^a-z]|$)"
scan_files=("$RULES")
while IFS= read -r f; do scan_files+=("$f"); done < <(find "$REPO_ROOT/agents" "$REPO_ROOT/skills" -type f -name '*.md' | sort)

mentions=0 offenders=""
for f in "${scan_files[@]}"; do
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mentions=$((mentions + 1))
    if ! printf '%s' "$line" | grep -qiE "$NEG_RE"; then
      offenders="$offenders
$f: ${line:0:160}"
    fi
  done < <(grep -iE "$CPU_CHECK_RE" "$f" 2>/dev/null)
done
if [ -z "$offenders" ]; then
  pass "no un-negated pgrep / uptime / load read / cpu-slot --status|--wait line in agents/, skills/, operator-rules.md"
else
  fail "instruction to run a pre-commit CPU check found:$offenders"
fi
[ "$mentions" -ge 4 ] \
  && pass "scan is live: $mentions negated mentions seen (pr-author, pr-opener, safe-commit skill)" \
  || fail "scan saw only $mentions mentions; expected the negated prose in pr-author/pr-opener/safe-commit"
chk_prose "$SC_SKILL" 'no pre-commit CPU check' "safe-commit skill: states there is no pre-commit CPU check"
chk_prose "$SC_SKILL" 'machine load is informational and never blocks a commit' "safe-commit skill: load never blocks a commit"
chk_prose "$AUTHOR" 'Never run a pre-commit CPU check' "pr-author: never run a pre-commit CPU check"
chk_prose "$OPENER" 'Never** run a pre-commit CPU check' "pr-opener: never run a pre-commit CPU check"

# ---------------------------------------------------------------------------
echo "Group 5 — template: safeCommit.capacityRequeues"
if command -v jq >/dev/null 2>&1; then
  v="$(jq -r '.safeCommit.capacityRequeues // "absent"' "$TEMPLATE" 2>/dev/null)"
  [ "$v" = "8" ] && pass "template: safeCommit.capacityRequeues defaults to 8" || fail "template: capacityRequeues is '$v', expected 8"
  v="$(jq -r '.safeCommit.slotMaxWait // "absent"' "$TEMPLATE" 2>/dev/null)"
  [ "$v" = "240" ] && pass "template: safeCommit.slotMaxWait still 240" || fail "template: slotMaxWait is '$v', expected 240"
  v="$(jq -r '.safeCommit._capacityRequeues_comment // ""' "$TEMPLATE" 2>/dev/null)"
  case "$v" in *"BLOCKED — CPU "*) pass "template: comment names the BLOCKED — CPU token" ;; *) fail "template: capacityRequeues comment missing or without the token" ;; esac
else
  echo "  SKIP: jq not installed, template not checked"
fi

# ---------------------------------------------------------------------------
echo "Group 6 — drift guard: every rc-75 block message starts with 'BLOCKED — CPU '"
# The 75) branch of the acquire case in hooks/safe-commit.sh, up to its `;;`.
branch="$(awk '/^ *75\)/{f=1} f{print} f && /;;/{exit}' "$HOOK")"
[ -n "$branch" ] && pass "found the rc-75 branch of the slot acquire case" || fail "rc-75 branch not found in hooks/safe-commit.sh"
echos="$(printf '%s\n' "$branch" | grep -E '^ *echo ' || true)"
n_echo="$(printf '%s' "$echos" | grep -c . || true)"
[ "$n_echo" -ge 1 ] && pass "rc-75 branch emits $n_echo block message(s)" || fail "rc-75 branch emits no echo message"
bad="$(printf '%s\n' "$echos" | grep -vE '^ *echo "BLOCKED — CPU ' || true)"
[ -z "$bad" ] && pass "every rc-75 block message starts with 'BLOCKED — CPU '" || fail "rc-75 message not starting with 'BLOCKED — CPU ': $bad"
printf '%s\n' "$branch" | grep -q 'exit 2' && pass "rc-75 branch blocks with exit 2" || fail "rc-75 branch does not exit 2"

# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "commit-capacity-requeue (#524): all assertions passed."
  exit 0
else
  echo "commit-capacity-requeue (#524): $fails assertion(s) failed."
  exit 1
fi
