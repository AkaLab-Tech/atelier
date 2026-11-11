#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Blocks any `git add` or `git commit`
# that would put a `.env*` file under version control.
#
# Committed templates (`.env.example`, `.env.sample`, `.env.template`,
# `.env.dist`, `.env.catalog.example`: final suffix from the shared list in
# hooks/lib/env-names.sh) are allowed when their content is placeholder-only.
# Staged deletions of env files are never blocked.
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
# shellcheck source=lib/env-names.sh
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/env-names.sh"

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
  *"git add"*)          is_git_add=1 ;;
  *"git -C "*"add"*)    is_git_add=1 ;;
esac
case "$command_str" in
  *"git commit"*)          is_git_commit=1 ;;
  *"git -C "*"commit"*)    is_git_commit=1 ;;
esac

if [ "$is_git_add" -eq 0 ] && [ "$is_git_commit" -eq 0 ]; then
  exit 0
fi

# M7.1.F57 — resolve the directory the add/commit actually targets.
#
# Atelier's cwd-vs-worktree rule (operator-rules.md) means an agent keeps
# its cwd at the main repo / home and addresses the task worktree through
# `git -C <worktree>` (or, less often, a `cd <worktree> &&` prefix). The
# hook inherits that cwd, so `$PWD` is the WRONG tree: scanning it inspects
# the main repo, not the worktree being staged/committed. Derive the
# target directory from the command itself, falling back to `$PWD` only
# for a plain `git add`/`git commit` with no `-C` / `cd`. Ported verbatim
# from safe-commit.sh's `-C` and `cd` resolution arms (M7.1.F57).
target_dir="$PWD"
if printf '%s' "$command_str" | grep -qE 'git[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-C[[:space:]]'; then
  # `git -C <path> ... add/commit` — the atelier convention.
  c_path="$(printf '%s' "$command_str" | sed -nE "s/.*git[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-C[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\3\4\5/p")"
  [ -n "$c_path" ] && target_dir="$c_path"
elif printf '%s' "$command_str" | grep -qE '^[[:space:]]*cd[[:space:]]'; then
  # `cd <path> && git add/commit …` prefix.
  cd_path="$(printf '%s' "$command_str" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]&;|]+)).*/\2\3\4/p")"
  [ -n "$cd_path" ] && target_dir="$cd_path"
fi
# Canonicalise relative paths against $PWD and validate the directory
# exists; fall back to $PWD if it doesn't (fail-open: a resolution miss
# must never become an exit 2 here).
if [ -d "$target_dir" ]; then
  target_dir="$(cd "$target_dir" 2>/dev/null && pwd)" || target_dir="$PWD"
else
  target_dir="$PWD"
fi

# Candidate `.env*` paths this command would add or commit. Templates
# (`.env.example`, `.env.catalog.example`, ...) are allowed through the
# secret-scan below; every other env name blocks. Names come from:
#   - the pathspec tokens of each `git add` (text inside a commit message is
#     never a path: only `git add` args and unquoted `git commit` args count);
#   - wildcard adds (`git add .`, `-A`, `--all`, `:/`, `*`): what git itself
#     would pick up (untracked + modified, NEVER deleted paths);
#   - `git commit`: the index (additions/modifications only), plus tracked
#     modifications for `-a`/`--all`.
# Staged or about-to-be-staged DELETIONS of env files are never blocked: removing
# a secret from version control is the fix, not the problem.
cands=""
env_path_re='(^|/)\.env([^/]*)?$'
wildcard_add=0
commit_all=0
commit_seen=0

# Quote-aware word split of one simple command, one word per line, quotes removed.
cmd_words() {
  printf '%s\n' "$1" | awk '{
    n = length($0); w = ""; inw = 0; q = ""
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (q != "") { if (c == q) { q = "" } else { w = w c }; continue }
      if (c == "\"" || c == "\047") { q = c; inw = 1; continue }
      if (c == " " || c == "\t") { if (inw) { print w; w = ""; inw = 0 }; continue }
      w = w c; inw = 1
    }
    if (inw) print w
  }'
}

# Separators inside quoted text (a commit message) must not split the command.
masked_cmd="$(env_mask_quoted_separators "$command_str")"
amp='&'
while IFS= read -r seg; do
  seg="${seg//$'\001'/;}"
  seg="${seg//$'\002'/|}"
  seg="${seg//$'\003'/"$amp"}"
  words=()
  while IFS= read -r w; do words+=("$w"); done < <(cmd_words "$seg")
  n=${#words[@]}
  i=0
  while [ "$i" -lt "$n" ] && [ "${words[i]##*/}" != git ]; do i=$((i + 1)); done
  [ "$i" -lt "$n" ] || continue
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    case "${words[i]}" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || continue
  sub_cmd="${words[i]}"
  i=$((i + 1))
  case "$sub_cmd" in
    add)
      for (( ; i < n; i++ )); do
        tok="${words[i]}"
        case "$tok" in
          .|./|-A|--all|:/|"*") wildcard_add=1; continue ;;
          -*|'') continue ;;
        esac
        env_is_env_name "$tok" || continue
        case "$tok" in
          *[\*\?\[]*) ;;
          *)
            # Explicit path already gone from the worktree but known to git
            # (index or HEAD): `git add <path>` records a deletion.
            case "$tok" in /*) full_tok="$tok" ;; *) full_tok="$target_dir/$tok" ;; esac
            if [ ! -e "$full_tok" ] && [ ! -L "$full_tok" ] \
               && { [ -n "$(git -C "$target_dir" ls-files --deleted -- "$tok" 2>/dev/null)" ] \
                    || [ -n "$(git -C "$target_dir" ls-tree -r --name-only HEAD -- "$tok" 2>/dev/null)" ]; }; then
              continue
            fi ;;
        esac
        cands+="$tok"$'\n'
      done
      ;;
    commit)
      commit_seen=1
      for (( ; i < n; i++ )); do
        tok="${words[i]}"
        case "$tok" in
          --all|-a*|-[!-mFCctSu]*a*) commit_all=1 ;;
        esac
        case "$tok" in
          # The argument of -m/--message is text, never a path.
          --message|-m|-[!-]*m) i=$((i + 1)); continue ;;
          --message=*|-m*) continue ;;
        esac
        env_is_env_name "$tok" && cands+="$tok"$'\n'
      done
      ;;
  esac
done < <(printf '%s\n' "$masked_cmd" | awk '{ gsub(/&&|\|\||[;|&]/, "\n"); print }')

if [ "$wildcard_add" -eq 1 ]; then
  cands+="$(
    {
      git -C "$target_dir" ls-files --others --exclude-standard 2>/dev/null || true
      git -C "$target_dir" diff --name-only --diff-filter=d 2>/dev/null || true
    } | grep -E "$env_path_re" || true
  )"$'\n'
fi

if [ "$commit_seen" -eq 1 ]; then
  cands+="$(git -C "$target_dir" diff --cached --name-only --diff-filter=d 2>/dev/null | grep -E "$env_path_re" || true)"$'\n'
  if [ "$commit_all" -eq 1 ]; then
    cands+="$(git -C "$target_dir" diff --name-only --diff-filter=d 2>/dev/null | grep -E "$env_path_re" || true)"$'\n'
  fi
fi

matched_path=""

# Allowlist + secret-scan: template names (see hooks/lib/env-names.sh) are
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

# Resolve each candidate: a template is blocked only when its content carries a
# real-looking secret; any other env name blocks outright.
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  if env_is_template_name "$cand"; then
    template_path=""
    for try in "$cand" "$target_dir/$cand" "$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null)/$cand"; do
      if [ -f "$try" ]; then template_path="$try"; break; fi
    done
    [ -n "$template_path" ] || continue
    findings="$(scan_env_template "$template_path")"
    if [ -n "$findings" ]; then
      cat >&2 <<MSG
🚫 atelier:block-env-commit BLOCKED (template carries what looks like a real secret)
   Tool:     Bash(git add/commit)
   Template: $cand
   Findings (first 5):
$(printf '%s\n' "$findings" | sed 's/^/     - /')
   Rule:     templates ($(basename "$cand")) must hold placeholders, not real secrets.
   Action:   replace the offending values with placeholders (your_*, <key>, changeme, xxx, etc.)
             and re-stage. Real secrets go in your local .env which is already gitignored.
   Override: if a value is a genuine non-secret (e.g. a public anon key) and the heuristic is wrong,
             commit manually with --no-verify after the operator confirms.
MSG
      log_decision "$HOOK_NAME" "Bash" ".env-template-secret" "block" "blocked template $cand with $(printf '%s\n' "$findings" | wc -l | tr -d ' ') finding(s)"
      exit 2
    fi
  else
    matched_path="$cand"
    break
  fi
done <<< "$cands"

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
