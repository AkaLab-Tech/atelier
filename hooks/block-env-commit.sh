#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Blocks any `git add` or `git commit`
# that would put a `.env*` file under version control.
#
# Layered defence (PLAN.md §3 "Defense-in-depth"):
#   - Static permissions matrix denies `Edit(.env*)` writes outside the
#     worktree allowlist (M1.4).
#   - install.sh Phase C.1 adds `.env*` to git's GLOBAL excludes.
#   - This hook is the runtime safety net: even when an agent has a
#     local `.env` for testing and runs `git add .` reflexively, the
#     `.env` never reaches the index.
#
# Contract per Claude Code hooks reference (PreToolUse):
#   stdin  — JSON: { session_id, tool_name, tool_input: { command, ... } }
#   exit 0 — allow the tool call
#   exit 2 — block the tool call (the printed message on stderr goes to
#            Claude's context so it understands why it was blocked)
#   any other non-zero — block but treated as a hook error
#
# We exit 0 on any unexpected input shape: failing closed (default-deny)
# would block every Bash call when the JSON format eventually changes;
# we want the safety net, not a brittle gate.

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="block-env-commit"

# Read the entire stdin payload. The harness sends the JSON synchronously
# before the tool would run, so we can block while reading.
input="$(cat 2>/dev/null || true)"

# Parse with jq; if jq fails (unparseable input), allow and log the issue
# rather than aborting the operator's workflow.
if ! command -v jq >/dev/null 2>&1; then
  # jq missing is an install bug, but allow the call rather than block
  # everything. install.sh Phase A guarantees jq, so this branch is
  # mostly defensive.
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Only inspect Bash invocations. Edit/Write are handled by scan-edit-write
# in a separate sub-PR.
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi

# No command string (malformed input) — allow.
if [ -z "$command_str" ]; then
  exit 0
fi

# Quick filter: this hook only cares about `git add` and `git commit`.
# Match the verb robustly: any leading prefix (env vars, sudo, redirections
# we don't expect from agents but stay safe), then `git`, whitespace, then
# the subcommand. We use a permissive grep to catch chained commands too
# (e.g. `... && git add .env`).
is_git_add=0
is_git_commit=0
case "$command_str" in
  *"git add"*)    is_git_add=1 ;;
esac
case "$command_str" in
  *"git commit"*) is_git_commit=1 ;;
esac

if [ "$is_git_add" -eq 0 ] && [ "$is_git_commit" -eq 0 ]; then
  exit 0
fi

# Path-based scan for `.env` in the literal command. Catches the common
# explicit-path cases: `git add .env`, `git add app/.env.local`, etc.
# Pattern: any token in the command whose basename matches .env*.
#
# `git add .` / `git add -A` / `git add :*` don't list paths literally —
# for those we fall through to a working-tree scan below.
matched_path=""
if printf '%s' "$command_str" | grep -Eq '(^|[[:space:]/])\.env([^/[:space:]]*)?'; then
  # Pull out the first .env* token for the message. (Best-effort; we
  # don't need the complete list to justify the block.)
  matched_path="$(printf '%s' "$command_str" | grep -Eo '(^|[[:space:]/])\.env[^[:space:]]*' | head -n1 | sed -E 's/^[[:space:]/]*//')"
fi

# Wildcard-style adds (`git add .`, `git add -A`, `git add --all`,
# `git add :/`). Resolve what they would stage by asking git itself,
# scoped to the cwd of the hook (which is the worktree Claude is in).
if [ -z "$matched_path" ] && [ "$is_git_add" -eq 1 ]; then
  case "$command_str" in
    *"git add ."*|*"git add -A"*|*"git add --all"*|*"git add :/"*|*"git add *"*)
      # Untracked + modified .env* files that this wildcard add would pick up.
      # Both `git ls-files --others --exclude-standard` and `git diff --name-only`
      # are read-only and don't change repo state, so this is safe in a hook.
      candidates="$(
        {
          git ls-files --others --exclude-standard 2>/dev/null || true
          git diff --name-only 2>/dev/null || true
        } | grep -E '(^|/)\.env([^/]*)?$' | head -n5
      )"
      if [ -n "$candidates" ]; then
        matched_path="$(printf '%s' "$candidates" | head -n1)"
      fi
      ;;
  esac
fi

# `git commit` without prior staged .env*: inspect the index directly.
# This catches `git commit -a` (auto-stages tracked changes) and the
# rare case where an earlier add-with-path slipped past us.
if [ -z "$matched_path" ] && [ "$is_git_commit" -eq 1 ]; then
  staged_env="$(git diff --cached --name-only 2>/dev/null | grep -E '(^|/)\.env([^/]*)?$' | head -n1 || true)"
  if [ -n "$staged_env" ]; then
    matched_path="$staged_env"
  fi
  # `git commit -a` (and its variants -am, --all, etc.) re-stages tracked
  # .env* files at commit time. The single `-a` substring match covers
  # all of those variants since they all contain it.
  case "$command_str" in
    *"git commit -a"*|*"git commit --all"*)
      if [ -z "$matched_path" ]; then
        modified_env="$(git diff --name-only 2>/dev/null | grep -E '(^|/)\.env([^/]*)?$' | head -n1 || true)"
        if [ -n "$modified_env" ]; then
          matched_path="$modified_env"
        fi
      fi
      ;;
  esac
fi

if [ -z "$matched_path" ]; then
  # Nothing matched — allow the tool call and log the allow decision
  # only at low verbosity (omit it entirely to keep the JSONL useful).
  exit 0
fi

# Block. Print a clear message to stderr (Claude reads it) and exit 2.
verb="git add"
if [ "$is_git_commit" -eq 1 ] && [ "$is_git_add" -eq 0 ]; then
  verb="git commit"
fi

cat >&2 <<MSG
🚫 atelier:block-env-commit BLOCKED
   Tool:    Bash($verb)
   Reason:  staged or about-to-be-staged paths include a .env* file: $matched_path
   Rule:    PLAN.md §3 — .env* must never enter version control.
   Action:  remove the path from your add/commit, or use \`git stash --include-untracked\` if you need to keep the file locally.
   Override: if this is a deliberate exception (rare), commit it manually with --no-verify after the operator confirms.
MSG

log_decision "$HOOK_NAME" "Bash" ".env-staged" "block" "blocked $verb of $matched_path"

exit 2
