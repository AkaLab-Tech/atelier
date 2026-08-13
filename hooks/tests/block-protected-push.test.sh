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
# Extended for #35 (push refspec hardening) with three regression classes
# that were each ALLOWED (exit 0) by the pre-#35 hook:
#   (b) quoted refspecs — word-splitting leaves the shell quoting inside
#       the token, so `git push origin "task/x:main"` resolved its
#       destination to `main"` (trailing quote) and sailed past the
#       protected-name check. Same for `'main'` and `"+HEAD:main"`.
#   (c) bulk pushes — `--all` / `--mirror` update (and for --mirror,
#       delete) every remote ref including protected ones without ever
#       naming a refspec, so the destination check had nothing to catch.
#       `--tags` is deliberately NOT in this class: tag pushes are
#       sanctioned and cannot move a branch ref.
#   (d) the empty-args crash — an arg-less `git push` produced an empty
#       array slice which, under `set -u` on bash 3.2, aborted the hook
#       with `args[@]: unbound variable` (exit 1). Claude Code reads a
#       non-0/2 exit as a hook *error*, not a verdict.
# Plus a static matrix asserting templates/settings.template.json's
# deny[] still carries the Layer-1 globs backing all of the above.
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
TEMPLATE="$REPO_ROOT/templates/settings.template.json"

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

# === BLOCK: trailing --force / -f against every protected branch (#94) =====
# The static deny globs in templates/settings.template.json only cover
# `git push * <branch> --force` / `-f` literally; this pins the categorical
# hook-level guarantee those globs are defense-in-depth for, across both
# flag spellings and all four protected branches.
assert_block "git push origin main -f"                 "git push origin main -f"
assert_block "git push origin master --force"          "git push origin master --force"
assert_block "git push origin master -f"                "git push origin master -f"
assert_block "git push origin develop --force"         "git push origin develop --force"
assert_block "git push origin develop -f"               "git push origin develop -f"
assert_block "git push origin staging --force"         "git push origin staging --force"
assert_block "git push origin staging -f"               "git push origin staging -f"

# === BLOCK: hard force to a non-protected (task/*) branch ==================
assert_block "git push --force origin task/1-x"       "git push --force origin task/1-x"
assert_block "git push -f origin task/1-x"             "git push -f origin task/1-x"

# === BLOCK: global options separate `git` and `push` (#194 review) =========
# `git -C <path> push …` / `git -c key=val push …` split the two tokens the
# hook used to require contiguous — this is exactly how atelier agents
# invoke git against a worktree, so it must not bypass the block.
assert_block "git -C /repo push origin main"           "git -C /repo push origin main"
assert_block "git -c key=val push origin main"         "git -c key=val push origin main"

# === BLOCK (#35a): canonical src:dst refspec shapes ========================
# The destination side of a `<src>:<dst>` refspec is what actually moves, so
# every one of these lands on a protected branch even though the *source*
# side names a sanctioned task/* branch. `refs/heads/` on either side must
# be normalised away before the protected-name comparison.
assert_block "git push origin task/x:main" \
  "git push origin task/x:main"
assert_block "git push origin +HEAD:main (hard-force refspec to protected)" \
  "git push origin +HEAD:main"
assert_block "git push origin +task/x:main (hard-force refspec to protected)" \
  "git push origin +task/x:main"
assert_block "git push origin refs/heads/task/x:refs/heads/main (fully-qualified both sides)" \
  "git push origin refs/heads/task/x:refs/heads/main"

# === BLOCK (#35b): QUOTED refspecs — pre-#35 bypass ========================
# Regression pin. The hook tokenizes by word-splitting, which leaves shell
# quoting *inside* the token: pre-#35, `git push origin "task/x:main"`
# resolved its destination to `main"` (trailing double quote), which is not
# equal to `main`, so is_protected_name() returned false and the push was
# ALLOWED (exit 0). The fix strips `"`, `'` and a leading `\` from every
# token before classification. All three of these exited 0 before #35.
assert_block 'git push origin "task/x:main" (double-quoted refspec)' \
  'git push origin "task/x:main"'
assert_block "git push origin 'main' (single-quoted protected branch)" \
  "git push origin 'main'"
assert_block 'git push origin "+HEAD:main" (quoted hard-force refspec)' \
  'git push origin "+HEAD:main"'

# === BLOCK (#35c): BULK pushes (--all / --mirror) — pre-#35 bypass =========
# Regression pin. These update every remote ref — including main/master/
# develop/staging — without ever naming one, so the positional-refspec
# destination check had nothing to inspect and all three were ALLOWED
# (exit 0) pre-#35. `--mirror` additionally DELETES remote refs that are
# absent locally, which is strictly worse than a force push. Flag position
# is irrelevant: it must be caught before *and* after the remote name.
assert_block "git push --all origin (bulk, flag before remote)" \
  "git push --all origin"
assert_block "git push origin --all (bulk, flag after remote)" \
  "git push origin --all"
assert_block "git push --mirror origin (bulk + remote-ref deletion)" \
  "git push --mirror origin"

# === ALLOW: sanctioned task/* pushes and force-with-lease ==================
assert_allow "git push origin task/12-foo"                       "git push origin task/12-foo"
assert_allow "git push -u origin task/12-foo"                     "git push -u origin task/12-foo"
assert_allow "git push --set-upstream origin task/12-foo"         "git push --set-upstream origin task/12-foo"
assert_allow "git push --force-with-lease origin task/12-foo"     "git push --force-with-lease origin task/12-foo"

# === ALLOW: tag push =========================================================
# `--tags` is deliberately NOT treated as a bulk push by #35c: it can only
# create/update tag refs, never move a branch ref, and the PLAN.md §3
# release flow depends on it. If a future change lumps it in with
# --all/--mirror, this assertion is the tripwire.
assert_allow "git push origin v0.38.0" "git push origin v0.38.0"
assert_allow "git push --tags origin"  "git push --tags origin"

# === ALLOW (#35d): arg-less `git push` must exit 0, not crash ==============
# Regression pin for the `args[@]: unbound variable` abort. Pre-#35 the
# empty slice `${tokens[@]:$((push_idx + 1))}` expanded under `set -u` on
# bash 3.2 (macOS ships 3.2.57) and killed the hook with exit 1 — which
# Claude Code surfaces as a hook ERROR, not as an allow/deny verdict. The
# assertion below pins exit 0 specifically; a status of 1 here is the
# crash, a status of 2 would be an over-block.
assert_allow "git push (no arguments)" "git push"

# === ALLOW: commit message merely mentioning "git push origin main" ========
assert_allow 'git commit -m "..." mentioning git push origin main' \
  'git commit -m "explain that git push origin main is denied by the hook"'

# === ALLOW: any non-git-push command ========================================
assert_allow "ls -la" "ls -la"

# =============================================================================
# STATIC MATRIX — Layer 1 (templates/settings.template.json deny globs)
# =============================================================================
# The hook above is Layer 2, the categorical mechanism. The static globs in
# the shipped permission template are Layer 1 (PLAN.md §3 defense-in-depth):
# they stop the common literal shapes before the tool call is even
# dispatched, so a hook that fails open (jq missing) still leaves the
# obvious cases denied. Deleting a glob here silently downgrades that layer
# with no runtime symptom, so pin every entry the two layers share.
#
# Modeled on the template-assertion pattern in
# hooks/tests/deny-gh-identity-tokens.test.sh: a path-parameterized
# jq predicate, exact-string equality (not substring/regex), run over the
# real shipped template.
echo
echo "  -- static matrix: templates/settings.template.json permissions.deny[] --"

# --- helper: does <file>'s permissions.deny array literally contain <entry>?
deny_has_entry() {
  local file="$1" entry="$2"
  jq -e --arg want "$entry" \
    '(.permissions.deny // []) | any(. == $want)' \
    "$file" >/dev/null 2>&1
}

if [ ! -f "$TEMPLATE" ]; then
  fail "templates/settings.template.json not found at $TEMPLATE — cannot verify Layer 1 deny globs"
elif ! jq . "$TEMPLATE" >/dev/null 2>&1; then
  fail "templates/settings.template.json is not valid JSON — cannot verify Layer 1 deny globs"
else
  # Required Layer 1 deny entries. Grouped by the hook behavior each backs:
  #   *:main .. *:staging  → protected-branch destination of a src:dst refspec
  #   origin +*            → hard-force '+' refspec
  #   --all / --mirror     → bulk push (#35c), both flag positions
  #   * :*                 → remote-ref deletion via an empty source side
  REQUIRED_DENY_ENTRIES=(
    'Bash(git push *:main)'
    'Bash(git push *:master)'
    'Bash(git push *:develop)'
    'Bash(git push *:staging)'
    'Bash(git push origin +*)'
    'Bash(git push --all*)'
    'Bash(git push * --all*)'
    'Bash(git push --mirror*)'
    'Bash(git push * --mirror*)'
    'Bash(git push * :*)'
  )

  for entry in "${REQUIRED_DENY_ENTRIES[@]}"; do
    if deny_has_entry "$TEMPLATE" "$entry"; then
      pass "template deny[] carries $entry"
    else
      fail "template deny[] is MISSING $entry — Layer 1 permission glob regressed/removed"
    fi
  done

  # Negative control: the predicate must actually discriminate. An entry
  # that was never in the template must not report as present, otherwise
  # every PASS above is vacuous.
  if deny_has_entry "$TEMPLATE" 'Bash(git push --this-entry-does-not-exist)'; then
    fail "negative control is broken: deny_has_entry matched an entry that is not in the template"
  else
    pass "negative control: deny_has_entry correctly rejects an absent entry"
  fi

  # `--tags` must NOT be denied at Layer 1 either — same sanctioned-release
  # rationale as the allow assertion above, pinned on both layers.
  if deny_has_entry "$TEMPLATE" 'Bash(git push --tags*)'; then
    fail "template deny[] denies Bash(git push --tags*) — tag pushes are sanctioned (PLAN.md §3 release flow)"
  else
    pass "template deny[] does not deny tag pushes (--tags stays allowed)"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "All #194/#195 block-protected-push regression checks passed."
  exit 0
else
  echo "$fails #194/#195 block-protected-push regression check(s) FAILED."
  exit 1
fi
