#!/usr/bin/env bash
#
# Regression test for #544 — hooks/block-operator-gh-identity.sh must block
# review-like GitHub writes (gh pr review / gh pr comment / gh api review and
# comment endpoints / graphql review mutations) whose effective identity is
# not the atelier author/reviewer config, any GH_TOKEN-style override, and the
# credential-grab shapes (gh auth token, ~/.config/gh reads, keychain, authed
# curl, osascript on Chrome). It must NOT over-block the legitimate shapes:
# atelier identities, symlinks resolving to them, reads, board mutations,
# non-gh commands and commit messages that merely mention gh.
#
# Hermetic: temporary HOME and ATELIER_CONFIG_DIR, pinned CLAUDE_PROJECT_DIR
# (log_decision lands in the temp dir), GH_* / XDG vars unset before each case
# unless the case sets them, a failing fake `gh` first on PATH (the hook must
# never call gh), no network. Requires jq.
#
# Run:  hooks/tests/block-operator-gh-identity.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2016  # single quotes are intentional: the hook must see the literal $HOME / $(...) text
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-operator-gh-identity.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

T_HOME="$TMP/home"
ACD="$TMP/acd"
BIN="$TMP/bin"
mkdir -p "$T_HOME/.config/gh" "$ACD/gh/author" "$ACD/gh/reviewer" "$BIN" "$TMP/logs" "$TMP/work"
ln -s "$T_HOME/.config/gh" "$TMP/link-personal"
ln -s "$ACD/gh/author" "$TMP/link-author"
printf '#!/bin/sh\necho "fake gh must never be called" >&2\nexit 97\n' >"$BIN/gh"
chmod +x "$BIN/gh"

fails=0
blocked_n=0
allowed_n=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# run_hook <command> [VAR=value ...] -> echoes exit code. Extra assignments are
# applied to the hook's environment (inherited GH_CONFIG_DIR, tokens, ...).
run_hook() {
  local command_str="$1"; shift
  local payload
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$TMP/work" || exit 99
    env -u GH_CONFIG_DIR -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u XDG_CONFIG_HOME \
      HOME="$T_HOME" ATELIER_CONFIG_DIR="$ACD" \
      CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" \
      PATH="$BIN:$PATH" "$@" \
      bash "$HOOK" <<<"$payload" >/dev/null 2>"$TMP/stderr"
  )
  echo "$?"
}

assert_block() {
  local name="$1" cmd="$2"; shift 2
  blocked_n=$((blocked_n + 1))
  local rc; rc="$(run_hook "$cmd" "$@")"
  if [ "$rc" = "2" ] && grep -q 'atelier:block-operator-gh-identity BLOCKED' "$TMP/stderr"; then
    pass "block: $name"
  else
    fail "block: $name (exit=$rc, cmd: $cmd)"
  fi
}

assert_allow() {
  local name="$1" cmd="$2"; shift 2
  allowed_n=$((allowed_n + 1))
  local rc; rc="$(run_hook "$cmd" "$@")"
  if [ "$rc" = "0" ]; then
    pass "allow: $name"
  else
    fail "allow: $name (exit=$rc, cmd: $cmd)"
  fi
}

AUTHOR="$ACD/gh/author"
REVIEWER="$ACD/gh/reviewer"
PERSONAL="$T_HOME/.config/gh"

echo "== personal config in every form =="
assert_block "GH_CONFIG_DIR=~/.config/gh"        'GH_CONFIG_DIR=~/.config/gh gh pr review 1 --approve'
assert_block 'GH_CONFIG_DIR=$HOME/.config/gh'    'GH_CONFIG_DIR=$HOME/.config/gh gh pr review 1 --approve'
assert_block 'GH_CONFIG_DIR="$HOME/.config/gh"'  'GH_CONFIG_DIR="$HOME/.config/gh" gh pr comment 1 -b hi'
assert_block "GH_CONFIG_DIR absolute personal"   "GH_CONFIG_DIR=$PERSONAL gh pr review 1 --approve"
assert_block "env prefix personal"               'env GH_CONFIG_DIR=~/.config/gh gh pr review 1 --approve'
assert_block "earlier export personal"           'export GH_CONFIG_DIR=$HOME/.config/gh; gh pr review 1 --approve'
assert_block "earlier export && personal"        'export GH_CONFIG_DIR=~/.config/gh && gh pr comment 1 -b hi'
assert_block "symlink pointing at personal"      "GH_CONFIG_DIR=$TMP/link-personal gh pr review 1 --approve"
assert_block 'dynamic $(...)'                    'GH_CONFIG_DIR=$(echo ~/.config/gh) gh pr review 1 --approve'
assert_block "dynamic backticks"                 'GH_CONFIG_DIR=`echo x` gh pr review 1 --approve'
assert_block 'unknown $VAR'                      'GH_CONFIG_DIR=$SOMEWHERE gh pr review 1 --approve'
assert_block "inherited personal config"         'gh pr review 1 --approve' GH_CONFIG_DIR="$PERSONAL"
assert_block "XDG personal config"               'gh pr comment 1 -b hi' XDG_CONFIG_HOME="$T_HOME/.config"
assert_block "unset GH_CONFIG_DIR, none inherited" 'gh pr review 1 --approve'
assert_block "unset GH_CONFIG_DIR, comment"      'gh pr comment 1 -b hi'
assert_block "in-command unset of inherited atelier dir" 'unset GH_CONFIG_DIR; gh pr review 1 --approve' GH_CONFIG_DIR="$AUTHOR"

echo "== token overrides =="
for tok in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN; do
  assert_block "inline $tok"                     "$tok=abc123 gh pr review 1 --approve"
  assert_block "inline $tok under author dir"    "$tok=abc123 GH_CONFIG_DIR=$AUTHOR gh pr comment 1 -b hi"
  assert_block "exported $tok in-command"        "export $tok=abc123; gh pr review 1 --approve"
  assert_block "inherited $tok"                  'gh pr review 1 --approve' GH_CONFIG_DIR="$AUTHOR" "$tok=abc123"
done

echo "== gh pr review / comment under non-atelier identity =="
assert_block "gh pr review --comment personal"   'gh pr review 1 --comment --body x'
assert_block "gh pr review --request-changes"    'gh pr review 1 --request-changes --body x'

echo "== gh api REST review/comment endpoints =="
export_author="GH_CONFIG_DIR=$PERSONAL"
for ep in repos/o/r/pulls/5/reviews repos/o/r/pulls/5/reviews/9/events repos/o/r/pulls/5/comments \
          repos/o/r/pulls/comments/9 repos/o/r/issues/5/comments repos/o/r/issues/comments/9; do
  assert_block "-X POST $ep"       "$export_author gh api -X POST $ep -f body=x"
  assert_block "--method POST $ep" "$export_author gh api --method POST $ep -f body=x"
  assert_block "implicit -f $ep"   "$export_author gh api $ep -f body=x"
  assert_block "implicit -F $ep"   "$export_author gh api $ep -F body=x"
  assert_block "implicit --input $ep" "$export_author gh api $ep --input body.json"
  assert_block "unset config POST $ep" "gh api -X POST $ep -f body=x"
done
assert_block "PATCH comment endpoint"            "$export_author gh api -X PATCH repos/o/r/pulls/comments/9 -f body=x"

echo "== gh api graphql review/comment mutations =="
for m in addPullRequestReview submitPullRequestReview updatePullRequestReview addPullRequestReviewComment \
         addPullRequestReviewThread addComment dismissPullRequestReview; do
  assert_block "graphql $m personal" "GH_CONFIG_DIR=$PERSONAL gh api graphql -f query='mutation { $m(input: {}) { clientMutationId } }'"
  assert_block "graphql $m unset"    "gh api graphql -f query='mutation { $m(input: {}) { clientMutationId } }'"
done

echo "== wrapped in bash -c / sh -c / eval =="
assert_block "bash -c personal"                  "bash -c 'GH_CONFIG_DIR=$PERSONAL gh pr review 1 --approve'"
assert_block "bash -c unset config"              "bash -c 'gh pr review 1 --approve'"
assert_block "sh -c unset config"                "sh -c 'gh pr comment 1 -b hi'"
assert_block "eval personal"                     "eval 'GH_CONFIG_DIR=$PERSONAL gh pr review 1 --approve'"
assert_block "eval unset config"                 "eval \"gh pr review 1 --approve\""
assert_block "bash -c token"                     "bash -c 'GH_TOKEN=abc gh pr review 1 --approve'"
assert_block "bash -c graphql"                   "bash -c \"gh api graphql -f query='mutation { addPullRequestReview(input:{}) { clientMutationId } }'\""

echo "== exported vs shell-local GH_CONFIG_DIR assignments =="
assert_block "local plain assign, nothing inherited"  "GH_CONFIG_DIR=$AUTHOR; gh pr review 1 --approve"
assert_block "local declare, nothing inherited"       "declare GH_CONFIG_DIR=$AUTHOR; gh pr review 1 --approve"
assert_block "local readonly, nothing inherited"      "readonly GH_CONFIG_DIR=$AUTHOR; gh pr review 1 --approve"
assert_block "inherited author, plain assign personal" "GH_CONFIG_DIR=$PERSONAL; gh pr review 1 --approve" GH_CONFIG_DIR="$AUTHOR"
assert_block "export, unset, plain reviewer"          "export GH_CONFIG_DIR=$AUTHOR; unset GH_CONFIG_DIR; GH_CONFIG_DIR=$REVIEWER; gh pr review 1 --approve"
assert_block "plain, unset, bare export"              "GH_CONFIG_DIR=$AUTHOR; unset GH_CONFIG_DIR; export GH_CONFIG_DIR; gh pr review 1 --approve"
assert_block "local value not carried into bash -c"   "GH_CONFIG_DIR=$AUTHOR; bash -c 'export GH_CONFIG_DIR; gh pr review 1 --approve'"
assert_allow "inherited author, plain assign reviewer" "GH_CONFIG_DIR=$REVIEWER; gh pr review 1 --approve" GH_CONFIG_DIR="$AUTHOR"
assert_allow "export author"                          "export GH_CONFIG_DIR=$AUTHOR; gh pr review 1 --approve"
assert_allow "declare -x author"                      "declare -x GH_CONFIG_DIR=$AUTHOR; gh pr review 1 --approve"
assert_allow "typeset -x author"                      "typeset -x GH_CONFIG_DIR=$AUTHOR; gh pr review 1 --approve"
assert_allow "plain assign then bare export"          "GH_CONFIG_DIR=$AUTHOR; export GH_CONFIG_DIR; gh pr review 1 --approve"
assert_allow "export author then plain reviewer"      "export GH_CONFIG_DIR=$AUTHOR; GH_CONFIG_DIR=$REVIEWER; gh pr review 1 --approve"
assert_allow "inline author prefix"                   "GH_CONFIG_DIR=$AUTHOR gh pr review 1 --approve"

echo "== credential grabs =="
assert_block "gh auth token under personal"      "GH_CONFIG_DIR=$PERSONAL gh auth token"
assert_block "gh auth token unset config"        'gh auth token'
assert_block "gh auth status --show-token"       'gh auth status --show-token'
assert_block "gh auth status -t personal"        "GH_CONFIG_DIR=$PERSONAL gh auth status --show-token"
assert_block "cat ~/.config/gh/hosts.yml"        'cat ~/.config/gh/hosts.yml'
assert_block 'cat $HOME/.config/gh/hosts.yml'    'cat $HOME/.config/gh/hosts.yml'
assert_block "grep oauth_token hosts.yml"        "grep oauth_token $PERSONAL/hosts.yml"
assert_block "keychain find-generic-password gh" 'security find-generic-password -s gh:github.com -w'
assert_block "keychain find-internet-password"   'security find-internet-password -s github.com -w'
assert_block "authed curl review endpoint"       'curl -H "Authorization: Bearer abc" https://api.github.com/repos/o/r/pulls/1/reviews'
assert_block "authed curl POST"                  'curl -X POST -H "Authorization: token abc" https://api.github.com/repos/o/r/issues/1/labels'
assert_block "authed wget comment endpoint"      'wget --header="Authorization: token abc" https://api.github.com/repos/o/r/issues/1/comments'
assert_block "osascript Chrome javascript"       "osascript -e 'tell application \"Google Chrome\" to execute front window'\''s active tab javascript \"fetch(1)\"'"
assert_block "osascript Chrome github.com"       "osascript -e 'tell application \"Google Chrome\" to open location \"https://github.com\"'"
assert_block "osascript Safari"                  "osascript -e 'tell application \"Safari\" to do JavaScript \"1\" in document 1'"

echo "== legitimate shapes pass =="
assert_allow "author gh pr comment"              'gh pr comment 1 -b hi' GH_CONFIG_DIR="$AUTHOR"
assert_allow "author gh pr review --comment"     'gh pr review 1 --comment --body x' GH_CONFIG_DIR="$AUTHOR"
assert_allow "author via \$ATELIER_CONFIG_DIR"   'GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" gh pr comment 1 -b hi'
for flag in --approve --request-changes --comment; do
  assert_allow "reviewer $flag"                  "GH_CONFIG_DIR=\"\$ATELIER_CONFIG_DIR/gh/reviewer\" gh pr review 12 $flag --body-file f"
  assert_allow "reviewer abs $flag"              "GH_CONFIG_DIR=$REVIEWER gh pr review 12 $flag --body-file f"
done
assert_allow "env reviewer"                      "env GH_CONFIG_DIR=$REVIEWER gh pr review 12 --approve --body-file f"
assert_allow "earlier export reviewer"           "export GH_CONFIG_DIR=$REVIEWER; gh pr review 12 --approve --body-file f"
assert_allow "inline reviewer overrides inherited personal" "GH_CONFIG_DIR=$REVIEWER gh pr review 12 --approve" GH_CONFIG_DIR="$PERSONAL"
assert_allow "symlink resolving to author"       "GH_CONFIG_DIR=$TMP/link-author gh pr review 1 --comment --body x"
assert_allow "author REST POST review"           'gh api -X POST repos/o/r/pulls/1/reviews -f body=x' GH_CONFIG_DIR="$AUTHOR"
assert_allow "reviewer graphql review mutation"  "GH_CONFIG_DIR=$REVIEWER gh api graphql -f query='mutation { addPullRequestReview(input:{}) { clientMutationId } }'"
assert_allow "reads: gh pr view personal"        'gh pr view 1'
assert_allow "reads: gh pr view author"          'gh pr view 1' GH_CONFIG_DIR="$AUTHOR"
assert_allow "reads: gh pr view reviewer"        "GH_CONFIG_DIR=$REVIEWER gh pr view 1"
assert_allow "reads: gh pr list token"           'GH_TOKEN=abc gh pr list'
assert_allow "reads: api reviews no write"       'gh api repos/o/r/pulls/1/reviews'
assert_allow "reads: api reviews author"        'gh api repos/o/r/pulls/1/reviews' GH_CONFIG_DIR="$AUTHOR"
assert_allow "reads: api reviews reviewer"       "GH_CONFIG_DIR=$REVIEWER gh api repos/o/r/pulls/1/reviews"
assert_allow "reads: api -X GET personal"        'gh api -X GET repos/o/r/pulls/1/reviews'
assert_allow "reads: api --method GET comments"  'gh api --method GET repos/o/r/issues/1/comments'
assert_allow "reads: api comments personal"      "GH_CONFIG_DIR=$PERSONAL gh api repos/o/r/issues/1/comments"
assert_allow "board mutation (project item)"     "gh api graphql -f query='mutation { updateProjectV2ItemFieldValue(input:{}) { projectV2Item { id } } }'"
assert_allow "board mutation env author"         "env GH_CONFIG_DIR=$AUTHOR gh api graphql -f query='mutation { updateProjectV2ItemFieldValue(input:{}) { projectV2Item { id } } }'"
assert_allow "graphql read query"                "gh api graphql -f query='query { viewer { login } }'"
assert_allow "fast path: ls"                     'ls -la'
assert_allow "fast path: git status"             'git status'
assert_allow "commit message mentions gh pr review" 'git commit -m "docs: explain gh pr review --approve and gh auth token"'
assert_allow "echo mentions gh pr review"        'echo "run gh pr review later"'

echo
echo "blocked cases: $blocked_n, allowed cases: $allowed_n"
total=$((blocked_n + allowed_n))
if [ "$fails" -eq 0 ]; then
  echo "block-operator-gh-identity: all $total assertions passed"
  exit 0
fi
echo "block-operator-gh-identity: $fails of $total assertions FAILED"
exit 1
