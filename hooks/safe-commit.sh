#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Runs the push gate (lint → typecheck
# → tests) before every `git commit` and blocks the commit when any of
# the three is red.
#
# Layered defence (PLAN.md §3 "Defense-in-depth", §6 push gate):
#   - Operators reach the push gate two ways:
#       1. Deliberately, via the `atelier:safe-commit` skill (M2.2) —
#          invoked by `pr-author` agent / `/finish-task` slash command.
#       2. Reflexively, when an agent just runs `git commit` without
#          first invoking the skill.
#   - This hook is the runtime safety net for case (2). It re-runs the
#     gate even when the skill already ran a moment ago — the cost is
#     duplicated work in the green path, but the alternative is a
#     skip-marker scheme that would be easy to spoof.
#
# Performance / timeout:
#   Lint + typecheck + tests can take minutes in real projects. Claude
#   Code's default hook timeout is 60s; this hook's hooks.json entry
#   bumps it to 600000 ms (10 minutes) to fit medium-sized projects.
#   For very long suites, the operator has three escape hatches:
#     - Override the timeout in the operator's own settings.local.json.
#     - Export `ATELIER_SKIP_SAFE_COMMIT=1` for a single shell session
#       (e.g. when the operator has just run the gate manually and wants
#       to commit a docs-only follow-up without re-running it).
#     - Use `git commit --no-verify` — already covered by the global
#       no-verify guardrail in operator-rules.md; that requires explicit
#       operator confirmation.
#
# Contract per Claude Code hooks reference (PreToolUse):
#   stdin  — JSON: { tool_name, tool_input: { command } }
#   exit 0 — allow the commit
#   exit 2 — block (stderr goes to Claude's context with the explanation)

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="safe-commit"

# Escape hatch — operator has decided the gate is N/A for this session.
# Logged so a post-mortem can show every skip event.
if [ "${ATELIER_SKIP_SAFE_COMMIT:-0}" = "1" ]; then
  log_decision "$HOOK_NAME" "?" "" "allow" "skipped via ATELIER_SKIP_SAFE_COMMIT=1"
  exit 0
fi

# Read the payload.
input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Only inspect Bash.
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi
if [ -z "$command_str" ]; then
  exit 0
fi

# Only intercept `git commit`. We deliberately do NOT match `git commit`
# inside an unrelated quoted string (e.g. a `git log --grep="git commit"`)
# — the pattern `git commit ` (with the trailing space) avoids most of
# those edge cases, and the rest are not security-relevant.
case "$command_str" in
  *"git commit "*|*"git commit"|*"git commit;"*|*"git commit&"*)
    ;;
  *)
    exit 0
    ;;
esac

# Find the project root by walking up looking for package.json.
# If we never find one, this is not a pnpm project — allow.
project_root="$PWD"
while [ "$project_root" != "/" ] && [ ! -f "$project_root/package.json" ]; do
  project_root="$(dirname "$project_root")"
done

if [ ! -f "$project_root/package.json" ]; then
  log_decision "$HOOK_NAME" "Bash" "no-package-json" "allow" "no package.json in cwd tree — push gate N/A"
  exit 0
fi

# Helper: returns 0 if `scripts.<name>` exists in package.json.
has_script() {
  jq -e --arg s "$1" '.scripts[$s] // empty' "$project_root/package.json" >/dev/null 2>&1
}

# Helper: run a script, return 0 on success, non-zero on failure.
# Captures combined stdout/stderr into a variable so we can show the
# tail to Claude. The caller decides what to do with the exit code.
run_pnpm_step() {
  local script="$1"
  ( cd "$project_root" && pnpm run "$script" 2>&1 )
}

# Walk the three steps in order, stopping (blocking) on the first red.
# A step is N/A if `scripts.<name>` doesn't exist in package.json — we
# log it and continue, which mirrors the safe-commit skill from M2.2.
for step in lint typecheck test; do
  if ! has_script "$step"; then
    log_decision "$HOOK_NAME" "Bash" "${step}-na" "allow" "scripts.${step} not defined in package.json — step N/A"
    continue
  fi

  output="$(run_pnpm_step "$step" || printf '__EXIT_%d__' "$?")"
  # Detect our sentinel for failure. We can't capture $? cleanly through
  # a subshell + assignment without losing the output, so we encode it.
  if printf '%s' "$output" | tail -c 80 | grep -qE '__EXIT_[0-9]+__$'; then
    exit_code="$(printf '%s' "$output" | tail -c 80 | grep -oE '__EXIT_[0-9]+__' | grep -oE '[0-9]+')"
    output="$(printf '%s' "$output" | sed -E 's/__EXIT_[0-9]+__$//')"

    cat >&2 <<MSG
🚫 atelier:safe-commit BLOCKED
   Tool:   Bash(git commit)
   Reason: \`pnpm run $step\` failed with exit $exit_code
   Output (last 30 lines):
$(printf '%s' "$output" | tail -n 30)
   Rule:   PLAN.md §6 push gate — lint + typecheck + tests must pass before commit.
   Action: fix the failing $step, then commit again. The hook re-runs automatically.
   Override: set ATELIER_SKIP_SAFE_COMMIT=1 only when the operator confirms the gate has been validated another way.
MSG

    log_decision "$HOOK_NAME" "Bash" "${step}-red" "block" "pnpm run $step failed (exit $exit_code)"
    exit 2
  fi

  log_decision "$HOOK_NAME" "Bash" "${step}-green" "allow" "pnpm run $step passed"
done

log_decision "$HOOK_NAME" "Bash" "push-gate-green" "allow" "push gate green — commit allowed"
exit 0
