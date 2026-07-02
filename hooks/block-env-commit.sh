#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Blocks any `git add` or `git commit`
# that would put a `.env*` file under version control.
#
# Layered defence (PLAN.md §3 "Defense-in-depth"):
#   - Static permissions matrix denies `Edit(.env*)` writes outside the
#     worktree allowlist.
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
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
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

# Allowlist + secret-scan: .env.example / .env.sample / .env.template are
# placeholder templates that are legitimately version-controlled — BUT only
# when their content is genuinely placeholder. If the template carries what
# looks like a real secret (named like one, prefixed like one, or high-entropy
# enough to be one), block the commit and surface the offending lines so the
# operator can scrub them. Three-layer detection:
#   A — sensitive key name (key|secret|token|password|pass|pwd|api|credential|private|auth)
#       paired with a non-empty, non-placeholder value.
#   B — known secret prefix in the value (sk-..., pk_live_..., xoxb-..., ghp_...,
#       AKIA..., JWT eyJ...).
#   C — value > 20 chars with Shannon entropy > 4.5 bits/char (catches random
#       hex/base64 secrets that miss layers A and B).
# Placeholders (your_key, xxx, <...>, changeme, example, localhost, etc.) are
# skipped from all three layers — that's the entire point of a template.
scan_env_template() {
  local file="$1"
  awk '
    function shannon(s,    i, c, n, p, entropy, counts) {
      n = length(s)
      if (n == 0) return 0
      delete counts
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        counts[c]++
      }
      entropy = 0
      for (c in counts) {
        p = counts[c] / n
        entropy -= p * log(p) / log(2)
      }
      return entropy
    }
    function is_placeholder(v,    vl) {
      vl = tolower(v)
      if (v ~ /^[[:space:]]*$/) return 1
      if (vl ~ /^<[^>]*>$/) return 1
      if (vl ~ /^-?[0-9]+(\.[0-9]+)?$/) return 1
      if (vl ~ /^(true|false)$/) return 1
      if (vl ~ /^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:[0-9]+)?$/) return 1
      if (vl ~ /^https?:\/\/(localhost|example\.[a-z]+|127\.0\.0\.1|0\.0\.0\.0)/) return 1
      if (vl ~ /^(secret|password|token|key|api[_-]?key|apikey|none|null|todo)$/) return 1
      # Substring placeholder markers — value contains operator-intent words
      # like "xxx", "example", "here", "your_", "changeme". Two scope rules:
      #   - "xxx" (3+ X-es): always a placeholder. The triple-X is vanishingly
      #     uncommon in real secrets at any length.
      #   - "example|placeholder|changeme|here|your|fixme|tbd|tba": only when
      #     the value is short (<= 32 chars). Real secrets are typically
      #     longer; AWSs canonical AKIAIOSFODNN7EXAMPLE (20 chars) and the
      #     Stripe sk_test_xxx pattern fit comfortably. Long random tokens
      #     that happen to embed "example" do NOT — they get scanned.
      if (vl ~ /xxx/) return 1
      if (length(v) <= 32 && vl ~ /(example|placeholder|changeme|change-me|change_me|fixme|tbd|tba|here|your)/) return 1
      return 0
    }
    function known_prefix(v) {
      if (v ~ /^sk-[A-Za-z0-9_-]{20,}/) return "OpenAI-style (sk-...)"
      if (v ~ /^sk_(live|test)_[A-Za-z0-9]{20,}/) return "Stripe secret (sk_live_.../sk_test_...)"
      if (v ~ /^pk_(live|test)_[A-Za-z0-9]{20,}/) return "Stripe publishable (pk_live_.../pk_test_...)"
      if (v ~ /^xox[abpsroe]-[A-Za-z0-9-]{10,}/) return "Slack token (xox?-...)"
      if (v ~ /^gh[ops]_[A-Za-z0-9]{30,}/) return "GitHub token (ghp_.../gho_.../ghs_...)"
      if (v ~ /^github_pat_[A-Za-z0-9_]{20,}/) return "GitHub fine-grained PAT (github_pat_...)"
      if (v ~ /^AKIA[0-9A-Z]{16}$/) return "AWS access key (AKIA...)"
      if (v ~ /^ASIA[0-9A-Z]{16}$/) return "AWS temp key (ASIA...)"
      if (v ~ /^eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\./) return "JWT (eyJ...)"
      return ""
    }
    function is_sensitive_key(k,    kl) {
      kl = tolower(k)
      if (kl ~ /(key|secret|token|password|pass|pwd|api|credential|private|auth)/) return 1
      return 0
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      eq = index($0, "=")
      if (eq == 0) next
      key = substr($0, 1, eq - 1)
      val = substr($0, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+/, "", val)
      if (val ~ /^".*"$/) { val = substr(val, 2, length(val) - 2) }
      else if (val ~ /^'\''.*'\''$/) { val = substr(val, 2, length(val) - 2) }
      else { gsub(/[[:space:]]+$/, "", val) }
      if (is_placeholder(val)) next
      pfx = known_prefix(val)
      if (pfx != "") {
        printf "line %d: %s — matches known secret prefix: %s\n", NR, key, pfx
        hits++
        if (hits >= 5) exit
        next
      }
      if (is_sensitive_key(key)) {
        printf "line %d: %s — sensitive key with non-placeholder value (%d chars)\n", NR, key, length(val)
        hits++
        if (hits >= 5) exit
        next
      }
      # Layer C: structural randomness checks
      #   - pure hex 24+ chars (MD5/SHA/random hex tokens — too uniform for
      #     Shannon at 4.5 threshold but unmistakably a secret)
      #   - any value > 20 chars with Shannon entropy > 4.5 (base64-ish secrets)
      if (length(val) >= 24 && val ~ /^[A-Fa-f0-9]+$/) {
        printf "line %d: %s — looks like a hex token (%d chars, pure hex)\n", NR, key, length(val)
        hits++
        if (hits >= 5) exit
        next
      }
      if (length(val) > 20) {
        e = shannon(val)
        if (e > 4.5) {
          printf "line %d: %s — high-entropy value (%.2f bits/char, %d chars)\n", NR, key, e, length(val)
          hits++
          if (hits >= 5) exit
        }
      }
    }
  ' "$file" 2>/dev/null
}

if [ -n "$matched_path" ]; then
  case "$(basename "$matched_path")" in
    .env.example|.env.sample|.env.template)
      template_path="$matched_path"
      [ -f "$template_path" ] || template_path="$(git rev-parse --show-toplevel 2>/dev/null)/$matched_path"
      if [ -f "$template_path" ]; then
        findings="$(scan_env_template "$template_path")"
        if [ -n "$findings" ]; then
          cat >&2 <<MSG
🚫 atelier:block-env-commit BLOCKED (template carries what looks like a real secret)
   Tool:     Bash(git add/commit)
   Template: $matched_path
   Findings (first 5):
$(printf '%s\n' "$findings" | sed 's/^/     - /')
   Rule:     templates ($(basename "$matched_path")) must hold placeholders, not real secrets.
   Action:   replace the offending values with placeholders (your_*, <key>, changeme, xxx, etc.)
             and re-stage. Real secrets go in your local .env which is already gitignored.
   Override: if a value is a genuine non-secret (e.g. a public anon key) and the heuristic is wrong,
             commit manually with --no-verify after the operator confirms.
MSG
          log_decision "$HOOK_NAME" "Bash" ".env-template-secret" "block" "blocked template $matched_path with $(printf '%s\n' "$findings" | wc -l | tr -d ' ') finding(s)"
          exit 2
        fi
      fi
      matched_path=""
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
