#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Runs the push gate (lint → typecheck
# → tests) before every `git commit` and blocks the commit when any of
# the three is red.
#
# Layered defence (PLAN.md §3 "Defense-in-depth", §6 push gate):
#   - Operators reach the push gate two ways:
#       1. Deliberately, via the `atelier:safe-commit` skill —
#          invoked by `pr-author` agent / `/atelier:finish-task` slash command.
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

# Escape hatch — operator-only, out-of-band affordance. This checks the
# hook's *environment* (a var the operator exported before invoking
# Claude Code, or set for a single shell session — see the header
# comment). It is NOT a substitute for the in-command bypass-signature
# refusal below: an inline `ATELIER_SKIP_SAFE_COMMIT=1 git commit …` never
# reaches this check (the hook runs as a separate process and receives
# the command as JSON on stdin — the Bash-tool shell's env does not
# persist into the hook), so an agent cannot smuggle the flag through
# here. Logged so a post-mortem can show every skip event.
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
#
# M7.1.F57 — also match `git -C <path> commit`, the atelier convention
# for committing inside a task worktree. Without this the gate never
# fired on the real per-task commit pattern (the `-C <path>` token sits
# between `git` and `commit`, so the plain substring above misses it).
#
# #277 — also match `git --git-dir=…`/`--work-tree=…` commit forms. A
# `git --git-dir=… --work-tree=… commit` matched NEITHER arm above and
# fell through to the `exit 0` default (silent allow) — exactly the
# gate-bypass vector observed in #208. These forms are refused outright
# by the bypass-signature check below (they are not a legitimate way to
# address a task worktree — `git -C <path>` is), so intercepting them
# here only ensures they reach that refusal instead of slipping past.
case "$command_str" in
  *"git commit "*|*"git commit"|*"git commit;"*|*"git commit&"*)
    ;;
  *"git -C "*"commit "*|*"git -C "*"commit"|*"git -C "*"commit;"*|*"git -C "*"commit&"*)
    ;;
  *"--git-dir"*"commit "*|*"--git-dir"*"commit"|*"--git-dir"*"commit;"*|*"--git-dir"*"commit&"*)
    ;;
  *"--work-tree"*"commit "*|*"--work-tree"*"commit"|*"--work-tree"*"commit;"*|*"--work-tree"*"commit&"*)
    ;;
  *)
    exit 0
    ;;
esac

# M7.1.F57 — resolve the directory the commit actually targets.
#
# Atelier's cwd-vs-worktree rule (operator-rules.md) means an agent keeps
# its cwd at the main repo / home and addresses the task worktree through
# `git -C <worktree>` (or, less often, a `cd <worktree> &&` prefix). The
# hook inherits that cwd, so `$PWD` is the WRONG tree: validating it runs
# the gate against the main repo, not the change being committed. Derive
# the target directory from the command itself, falling back to `$PWD`
# only for a plain `git commit` with no `-C` / `cd`.
target_dir="$PWD"
if printf '%s' "$command_str" | grep -qE 'git[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-C[[:space:]]'; then
  # `git -C <path> ... commit` — the atelier convention.
  c_path="$(printf '%s' "$command_str" | sed -nE "s/.*git[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-C[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\3\4\5/p")"
  [ -n "$c_path" ] && target_dir="$c_path"
elif printf '%s' "$command_str" | grep -qE -- '--work-tree(=|[[:space:]])'; then
  # #277 — `git --work-tree=<path> ... commit`. The bypass-signature check
  # below refuses this form on a commit; resolving it here keeps the
  # refusal message pointed at the tree the agent was trying to redirect
  # to (both `--flag=value` and `--flag value` forms).
  wt_path="$(printf '%s' "$command_str" | sed -nE "s/.*--work-tree(=|[[:space:]]+)(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\3\4\5/p")"
  [ -n "$wt_path" ] && target_dir="$wt_path"
elif printf '%s' "$command_str" | grep -qE -- '--git-dir(=|[[:space:]])'; then
  # #277 — `git --git-dir=<path> ... commit`. Same redirection family and
  # same refusal treatment as `--work-tree` above.
  gd_path="$(printf '%s' "$command_str" | sed -nE "s/.*--git-dir(=|[[:space:]]+)(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\3\4\5/p")"
  [ -n "$gd_path" ] && target_dir="$gd_path"
elif printf '%s' "$command_str" | grep -qE '^[[:space:]]*cd[[:space:]]'; then
  # `cd <path> && git commit …` prefix.
  cd_path="$(printf '%s' "$command_str" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]&;|]+)).*/\2\3\4/p")"
  [ -n "$cd_path" ] && target_dir="$cd_path"
fi
# Canonicalise relative paths against $PWD and validate the directory
# exists; fall back to $PWD if it doesn't.
if [ -d "$target_dir" ]; then
  target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || target_dir="$PWD"
else
  target_dir="$PWD"
fi

# #277 — gate-bypass signature refusal, placed BEFORE every green-path
# allow below (including the F48 docs-only and no-package-json N/A
# short-circuits). The bypass check runs on command SHAPE, not content:
# an agent smuggling a skip flag, a redirected git-dir/work-tree, or
# `--no-verify` into the commit command itself must never reach a path
# that reports N/A or green — those checks are orthogonal and must stay
# unaffected for legitimate commits. This is distinct from the
# operator's out-of-band `ATELIER_SKIP_SAFE_COMMIT=1` escape hatch above
# (set in the hook's *environment*, never inside the command).
bypass_signature=""
if printf '%s' "$command_str" | grep -qE '(^|[;&|[:space:]])ATELIER_SKIP_SAFE_COMMIT[[:space:]]*='; then
  bypass_signature="inline ATELIER_SKIP_SAFE_COMMIT= assignment"
elif printf '%s' "$command_str" | grep -qE -- '--git-dir(=|[[:space:]])'; then
  bypass_signature="--git-dir"
elif printf '%s' "$command_str" | grep -qE -- '--work-tree(=|[[:space:]])'; then
  bypass_signature="--work-tree"
elif printf '%s' "$command_str" | grep -qE -- '(^|[[:space:]])--no-verify([[:space:]]|;|&|$)'; then
  bypass_signature="--no-verify"
fi

if [ -n "$bypass_signature" ]; then
  cat >&2 <<MSG
🚫 atelier:safe-commit BLOCKED
   Tool:   Bash(git commit)
   Reason: gate-bypass attempt refused — the push gate cannot be routed around; fix the red gate or hand back to tester
   Signature: $bypass_signature
   Target: $target_dir
   Rule:   PLAN.md §6 push gate — lint + typecheck + tests must pass before every commit; this signature would route the commit around that gate.
   Action: fix the underlying red check, or hand back to tester. The operator's out-of-band ATELIER_SKIP_SAFE_COMMIT=1 escape hatch must be set in the shell environment — never inline it in the commit command.
MSG

  log_decision "$HOOK_NAME" "Bash" "bypass-attempt" "block" "gate-bypass signature: $bypass_signature"
  exit 2
fi

# M7.1.F48 — docs-only short-circuit.
#
# If every file the commit will touch is documentation, the push gate
# (lint + typecheck + tests) has nothing to validate. Running it under a
# worktree with missing deps produces the F48 symptom: the gate fails
# with `turbo: command not found` (or similar), the operator gets asked
# whether to skip — but the gate would not have rejected anything even
# if it could run.
#
# Detection rule: every staged file matches at least one of
#   - extension in {.md, .markdown, .txt, .rst, .adoc, .asciidoc}
#   - path prefix docs/ or documentation/
#   - basename in {LICENSE, NOTICE, CHANGELOG, AUTHORS, CONTRIBUTORS, README}
#     with or without an extension
#
# If even one staged file falls outside those patterns, the gate runs as
# before. This is intentionally conservative: a commit that touches both
# README.md and src/index.ts must validate.
#
# `git diff --cached --name-only` lists the staged files. For `git commit
# -a` / `--all` the index is not updated yet at hook time, so we also
# include `git diff --name-only` (modified-tracked files) when the
# command carries `-a` or `--all`.
staged_files="$(git -C "$target_dir" diff --cached --name-only 2>/dev/null || true)"
if printf '%s' "$command_str" | grep -qE '\bcommit\b[^|;&]*( -a\b| --all\b)'; then
  modified_files="$(git -C "$target_dir" diff --name-only 2>/dev/null || true)"
  all_files="$(printf '%s\n%s\n' "$staged_files" "$modified_files" | sort -u | sed '/^$/d')"
else
  all_files="$staged_files"
fi

# When there's nothing staged, we have nothing to short-circuit; fall
# through to the gate (it will surface the empty-commit case in its own
# voice).
if [ -n "$all_files" ]; then
  is_docs_only=true
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    matched=false
    # Extension match
    case "$f" in
      *.md|*.markdown|*.txt|*.rst|*.adoc|*.asciidoc) matched=true ;;
    esac
    # Path prefix match
    if ! $matched; then
      case "$f" in
        docs/*|documentation/*) matched=true ;;
      esac
    fi
    # Exact filename match (with or without trailing extension)
    if ! $matched; then
      base="$(basename "$f")"
      case "$base" in
        LICENSE|LICENSE.*|NOTICE|NOTICE.*|CHANGELOG|CHANGELOG.*|AUTHORS|AUTHORS.*|CONTRIBUTORS|CONTRIBUTORS.*|README|README.*) matched=true ;;
      esac
    fi
    if ! $matched; then
      is_docs_only=false
      break
    fi
  done <<EOF
$all_files
EOF

  if $is_docs_only; then
    file_count="$(printf '%s\n' "$all_files" | wc -l | tr -d ' ')"
    log_decision "$HOOK_NAME" "Bash" "docs-only" "allow" "all $file_count staged file(s) are documentation — push gate N/A (F48)"
    exit 0
  fi
fi

# Find the project root by walking up from the commit's target worktree
# (NOT $PWD — see F57 above) looking for package.json. If we never find
# one, this is not a JS/TS project — allow.
project_root="$target_dir"
while [ "$project_root" != "/" ] && [ ! -f "$project_root/package.json" ]; do
  project_root="$(dirname "$project_root")"
done

if [ ! -f "$project_root/package.json" ]; then
  log_decision "$HOOK_NAME" "Bash" "no-package-json" "allow" "no package.json in target worktree tree — push gate N/A"
  exit 0
fi

# M7.1.F57 — detect the package manager by lockfile instead of assuming
# pnpm. pnpm is the atelier default (PLAN.md §2) when no lockfile is
# present, but a workspace member on npm/yarn/bun must be gated with its
# own tool or the scripts mis-run / fail.
detect_pm() {
  if   [ -f "$project_root/pnpm-lock.yaml" ];   then echo pnpm
  elif [ -f "$project_root/yarn.lock" ];        then echo yarn
  elif [ -f "$project_root/bun.lockb" ] || [ -f "$project_root/bun.lock" ]; then echo bun
  elif [ -f "$project_root/package-lock.json" ]; then echo npm
  else echo pnpm
  fi
}
pm="$(detect_pm)"

# Helper: returns 0 if `scripts.<name>` exists in package.json.
has_script() {
  jq -e --arg s "$1" '.scripts[$s] // empty' "$project_root/package.json" >/dev/null 2>&1
}

# Helper: run a script, return 0 on success, non-zero on failure.
# Captures combined stdout/stderr into a variable so we can show the
# tail to Claude. The caller decides what to do with the exit code.
run_pm_step() {
  local script="$1"
  ( cd "$project_root" && "$pm" run "$script" 2>&1 )
}

# Walk the three steps in order, stopping (blocking) on the first red.
# A step is N/A if `scripts.<name>` doesn't exist in package.json — we
# log it and continue, which mirrors the `safe-commit` skill.
for step in lint typecheck test; do
  if ! has_script "$step"; then
    log_decision "$HOOK_NAME" "Bash" "${step}-na" "allow" "scripts.${step} not defined in package.json — step N/A"
    continue
  fi

  output="$(run_pm_step "$step" || printf '__EXIT_%d__' "$?")"
  # Detect our sentinel for failure. We can't capture $? cleanly through
  # a subshell + assignment without losing the output, so we encode it.
  if printf '%s' "$output" | tail -c 80 | grep -qE '__EXIT_[0-9]+__$'; then
    exit_code="$(printf '%s' "$output" | tail -c 80 | grep -oE '__EXIT_[0-9]+__' | grep -oE '[0-9]+')"
    output="$(printf '%s' "$output" | sed -E 's/__EXIT_[0-9]+__$//')"

    cat >&2 <<MSG
🚫 atelier:safe-commit BLOCKED
   Tool:   Bash(git commit)
   Reason: \`$pm run $step\` failed with exit $exit_code
   Output (last 30 lines):
$(printf '%s' "$output" | tail -n 30)
   Rule:   PLAN.md §6 push gate — lint + typecheck + tests must pass before commit.
   Action: fix the failing $step, then commit again. The hook re-runs automatically.
   Override: set ATELIER_SKIP_SAFE_COMMIT=1 only when the operator confirms the gate has been validated another way.
MSG

    log_decision "$HOOK_NAME" "Bash" "${step}-red" "block" "$pm run $step failed (exit $exit_code)"
    exit 2
  fi

  log_decision "$HOOK_NAME" "Bash" "${step}-green" "allow" "$pm run $step passed"
done

log_decision "$HOOK_NAME" "Bash" "push-gate-green" "allow" "push gate green — commit allowed"
exit 0
