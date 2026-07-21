#!/usr/bin/env bash
#
# Regression test for #194 / #195 — block-protected-push.sh must
# categorically block any `git push` that resolves to a protected
# branch (main/master/develop/staging) or carries a hard force, in any
# refspec/flag form the static Bash permission globs cannot express.
# It must also NOT over-block: sanctioned task/* pushes,
# --force-with-lease to task/*, tag pushes, commit messages that merely
# mention "git push origin main", and any non-git-push command must all
# be allowed through.
#
# Hermetic: drives hooks/block-protected-push.sh directly with crafted
# stdin JSON. No network, no real git remote — the hook is pure string
# parsing over tool_input.command, so no throwaway git repo is needed
# (contrast with block-env-commit-worktree.test.sh, which does need one
# because that hook introspects the actual working tree). Requires jq
# (the hook's own dependency).
#
# Run:  hooks/tests/block-protected-push.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-protected-push.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- helpers ----------------------------------------------------------------

# Run the hook as Claude Code would: payload = a Bash command. Echoes
# the exit code. CLAUDE_PROJECT_DIR is pinned to an isolated temp dir so
# log_decision() never touches real repo state.
run_hook() {
  local command_str="$1"
  local payload
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$HOOK" <<<"$payload" >/dev/null 2>&1
  )
  echo "$?"
}

assert_block() {
  local desc="$1" cmd="$2"
  local code
  code="$(run_hook "$cmd")"
  [ "$code" = "2" ] && pass "$desc → blocked (exit 2)" \
                     || fail "$desc expected exit 2, got $code — cmd: $cmd"
}

assert_allow() {
  local desc="$1" cmd="$2"
  local code
  code="$(run_hook "$cmd")"
  [ "$code" = "0" ] && pass "$desc → allowed (exit 0)" \
                     || fail "$desc expected exit 0, got $code — cmd: $cmd"
}

echo "#194/#195 regression — block-protected-push categorical push guard"

# === BLOCK: protected-branch destinations, every refspec/flag shape ========
assert_block "git push origin main"                  "git push origin main"
assert_block "git push origin HEAD:main"              "git push origin HEAD:main"
assert_block "git push origin +HEAD:main"             "git push origin +HEAD:main"
assert_block "git push origin main --force"           "git push origin main --force"
assert_block "git push origin refs/heads/main"        "git push origin refs/heads/main"
assert_block "git push origin master"                 "git push origin master"
assert_block "git push origin develop"                "git push origin develop"
assert_block "git push origin staging"                "git push origin staging"

# === BLOCK: hard force to a non-protected (task/*) branch ==================
assert_block "git push --force origin task/1-x"       "git push --force origin task/1-x"
assert_block "git push -f origin task/1-x"             "git push -f origin task/1-x"

# === ALLOW: sanctioned task/* pushes and force-with-lease ==================
assert_allow "git push origin task/12-foo"                       "git push origin task/12-foo"
assert_allow "git push -u origin task/12-foo"                     "git push -u origin task/12-foo"
assert_allow "git push --force-with-lease origin task/12-foo"     "git push --force-with-lease origin task/12-foo"

# === ALLOW: tag push =========================================================
assert_allow "git push origin v0.38.0" "git push origin v0.38.0"

# === ALLOW: commit message merely mentioning "git push origin main" ========
assert_allow 'git commit -m "..." mentioning git push origin main' \
  'git commit -m "explain that git push origin main is denied by the hook"'

# === ALLOW: any non-git-push command ========================================
assert_allow "ls -la" "ls -la"

echo
if [ "$fails" -eq 0 ]; then
  echo "All #194/#195 block-protected-push regression checks passed."
  exit 0
else
  echo "$fails #194/#195 block-protected-push regression check(s) FAILED."
  exit 1
fi
