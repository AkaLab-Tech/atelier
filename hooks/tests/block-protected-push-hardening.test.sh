#!/usr/bin/env bash
#
# Regression test for #808 — hardening of hooks/block-protected-push.sh.
#
# Companion to block-protected-push.test.sh (which keeps the original #194 /
# #195 / #35 matrix). This file pins the classes of shape that the pre-#808 hook
# let through, plus an over-blocking guard for the shapes that must stay
# allowed:
#
#   destination normalisation   a ref spelling git resolves to a protected branch
#   lexing / invocation form    the push is hidden behind shell syntax
#   unresolved expansion        a variable / substitution / brace in a push
#   alias / config / plumbing   the command word `push` never appears
#   option prefix               long options abbreviated the way git accepts
#   large payload               analysis time stays bounded (never times out open)
#   allow guard                 sanctioned and unrelated commands are not blocked
#
# Ground-truth oracle. Every case marked "oracle" first runs the REAL git
# command against a scratch bare remote (a clone under mktemp -d, HOME /
# GIT_CONFIG_GLOBAL / GIT_CONFIG_NOSYSTEM isolated, local file transport only,
# no network) and asserts that a protected ref really moved there; only then is
# the hook asserted to exit 2 for the same command with cwd set to the clone. So
# a case can never silently stop being dangerous. Allow-guard cases run the real
# command too and assert that no protected ref moved and the command succeeded.
#
# Cases without an oracle (marked hook-only) are shapes that cannot run
# end-to-end here (no http server, an ambiguous option git itself rejects,
# case-folding, a refspec git refuses) — the hook is conservative on them.
#
# Run:  hooks/tests/block-protected-push-hardening.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.
# Optional: BPP_HOOK=<path> runs a different hook script (e.g. the previous
# revision saved to a scratch file) over the same cases; every "block" case it
# lets through is then reported as FAIL, which gives the allowed-by-old count.

# shellcheck disable=SC2016
# (the case shapes are literal text: $ and backticks must NOT expand here)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${BPP_HOOK:-$REPO_ROOT/hooks/block-protected-push.sh}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate git completely: no real HOME, no global/system config, no prompts.
mkdir -p "$TMP/home" "$TMP/logs"
cat > "$TMP/gitconfig" <<'CFG'
[user]
	name = Test User
	email = test@example.invalid
[init]
	defaultBranch = main
[protocol "file"]
	allow = always
CFG
export HOME="$TMP/home"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
unset GIT_DIR GIT_WORK_TREE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS

fails=0
CASES=0
BLOCK_CASES=0
BLOCK_FAILS=0
CLASS_NAME=""
CLASS_START=0
CLASS_SUMMARY=""

pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

cls() { # class name
  CLASS_NAME="$1"; CLASS_START=$CASES
  printf '\n  -- %s --\n' "$1"
}
cls_end() {
  CLASS_SUMMARY="$CLASS_SUMMARY$(printf '  %-34s %s' "$CLASS_NAME" "$((CASES - CLASS_START))")"$'\n'
}

# --- scratch repositories ------------------------------------------------------
GITBIN="$(command -v git)"
GITGLOB="${GITBIN%/git}/g?t"
RP="$TMP/rp.sh"   # receive-pack stand-in used by the oracle: deletes main, then receives
cat > "$RP" <<'SH'
#!/bin/sh
git --git-dir="$1" update-ref -d refs/heads/main
exec git receive-pack "$1"
SH
chmod +x "$RP"

# Template: bare remote with main at c1; clone whose local main is one commit
# ahead (c2) and that sits on task/1-x (c3, one more commit), tag v1.2.3 local.
TPL="$TMP/tpl"
mkdir -p "$TPL"
git init -q --bare --template= "$TPL/remote.git"
git clone -q --template= "$TPL/remote.git" "$TPL/work" 2>/dev/null
(
  cd "$TPL/work" || exit 1
  git symbolic-ref HEAD refs/heads/main
  git commit -q --allow-empty -m c1
  git push -q -u origin main
  git commit -q --allow-empty -m c2
  git checkout -q -b task/1-x
  git commit -q --allow-empty -m c3
  git tag v1.2.3
) >/dev/null 2>&1

ENV_N=0
REMOTE=""; WORK=""
mk_env() { # fresh copy of the template → REMOTE / WORK
  ENV_N=$((ENV_N + 1))
  local d="$TMP/env$ENV_N"
  mkdir -p "$d"
  cp -R "$TPL/remote.git" "$d/remote.git"
  cp -R "$TPL/work" "$d/work"
  REMOTE="$d/remote.git"; WORK="$d/work"
  git -C "$WORK" remote set-url origin "$REMOTE"
}

# Shared environment for the hook-only cases.
mk_env
BASE_REMOTE="$REMOTE"; BASE_WORK="$WORK"

expand() { # replace the placeholders in a command / setup string
  local s="$1"
  s="${s//@REMOTE@/$REMOTE}"
  s="${s//@WORK@/$WORK}"
  s="${s//@RP@/$RP}"
  s="${s//@GITBIN@/$GITBIN}"
  s="${s//@GITGLOB@/$GITGLOB}"
  printf '%s' "$s"
}

snap() { # state of the four protected refs in the scratch remote
  git --git-dir="$REMOTE" for-each-ref refs/heads/main refs/heads/master refs/heads/develop refs/heads/staging
}

# --- hook driver ---------------------------------------------------------------
# Run the hook as Claude Code would (stdin JSON built with jq), with cwd = $1.
hook_rc() {
  local cwd="$1" cmd="$2" payload
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$cwd" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$HOOK" <<<"$payload" >/dev/null 2>&1
    echo "$?"
  )
}

expect_block() { # desc cwd cmd
  local code
  CASES=$((CASES + 1)); BLOCK_CASES=$((BLOCK_CASES + 1))
  code="$(hook_rc "$2" "$3")"
  if [ "$code" = "2" ]; then pass "$1 → blocked (exit 2)"
  else BLOCK_FAILS=$((BLOCK_FAILS + 1)); fail "$1 expected exit 2, got $code — cmd: $3"; fi
}

expect_allow() { # desc cwd cmd
  local code
  CASES=$((CASES + 1))
  code="$(hook_rc "$2" "$3")"
  if [ "$code" = "0" ]; then pass "$1 → allowed (exit 0)"
  else fail "$1 expected exit 0, got $code — cmd: $3"; fi
}

# hook-only block / allow, run in the shared clone (on task/1-x)
hb() { REMOTE="$BASE_REMOTE"; WORK="$BASE_WORK"; expect_block "$1 [hook-only]" "$BASE_WORK" "$(expand "$2")"; }
ha() { REMOTE="$BASE_REMOTE"; WORK="$BASE_WORK"; expect_allow "$1 [hook-only]" "$BASE_WORK" "$(expand "$2")"; }

# oracle block: the real command moves a protected ref, then the hook blocks it
ob() { # desc cmd [setup]
  local cmd before after
  mk_env
  cmd="$(expand "$2")"
  if [ -n "${3:-}" ]; then (cd "$WORK" && eval "$(expand "$3")") >/dev/null 2>&1; fi
  expect_block "$1 [oracle]" "$WORK" "$cmd"
  before="$(snap)"
  (cd "$WORK" && bash -c "$cmd") >/dev/null 2>&1
  after="$(snap)"
  if [ "$before" != "$after" ]; then pass "oracle: real git moved a protected ref — $1"
  else fail "oracle: real git did NOT move a protected ref (case is not dangerous) — $1: $cmd"; fi
}

# oracle allow: the real command succeeds, moves no protected ref, hook allows it
oa() { # desc cmd [setup]
  local cmd before after rc
  mk_env
  cmd="$(expand "$2")"
  if [ -n "${3:-}" ]; then (cd "$WORK" && eval "$(expand "$3")") >/dev/null 2>&1; fi
  expect_allow "$1 [oracle]" "$WORK" "$cmd"
  before="$(snap)"
  (cd "$WORK" && bash -c "$cmd") >/dev/null 2>&1
  rc=$?
  after="$(snap)"
  if [ "$rc" -ne 0 ]; then fail "oracle: real command failed (rc=$rc), so the allow case proves nothing — $1: $cmd"
  elif [ "$before" != "$after" ]; then fail "oracle: a protected ref moved on an allow case — $1: $cmd"
  else pass "oracle: real command ran, no protected ref moved — $1"; fi
}

echo "#808 regression — block-protected-push hardening"

# =============================================================================
cls "destination normalisation"
# =============================================================================
ob "unqualified heads/ destination after a task refspec"  'git push origin task/1-x HEAD:heads/main'
ob "heads/ destination"                                   'git push origin HEAD:heads/main'
ob "refs/heads/ destination"                              'git push origin HEAD:refs/heads/main'
ob "heads/ on both sides"                                 'git push origin heads/task/1-x:heads/main'
ob "develop spelled refs/heads/"                          'git push origin HEAD:refs/heads/develop'
ob "master via bare name"                                 'git push origin HEAD:master'
ob "protected name as a later refspec"                    'git push origin task/1-x:task/1-x HEAD:main'
ob "wildcard destination that matches every branch"      "git push origin 'refs/heads/*:refs/heads/*'"
ob "wildcard push that also prunes"                       "git push --prune origin 'refs/heads/*:refs/heads/*'" 'git push -q origin HEAD:refs/heads/staging'
hb "wildcard destination with a protected prefix"         "git push origin 'refs/heads/*:refs/heads/ma*'"
hb "wildcard destination, single-char wildcard"           'git push origin HEAD:ma?n'
hb "wildcard destination, bracket class"                  "git push origin 'HEAD:refs/heads/[m]ain'"
hb "wildcard destination that is only a star"             "git push origin 'refs/heads/task/*:refs/heads/*'"
hb "review-namespace destination ending in a protected name" 'git push origin HEAD:refs/for/main'
hb "nested destination ending in a protected name"        'git push origin HEAD:task/main'
hb "team-namespaced destination ending in staging"        'git push origin HEAD:refs/heads/team/staging'
hb "repeated refs/ prefix"                                'git push origin HEAD:refs/refs/heads/main'
hb "repeated heads/ prefix"                               'git push origin HEAD:heads/heads/main'
hb "leading slash"                                        'git push origin HEAD:/refs/heads/main'
hb "doubled slash"                                        'git push origin HEAD:refs/heads//main'
hb "trailing slash"                                       'git push origin HEAD:refs/heads/main/'
hb "upper-case spelling (case-folding filesystems)"       'git push origin HEAD:MAIN'
hb "mixed-case spelling behind refs/heads/"               'git push origin HEAD:refs/heads/Develop'
hb "source-only HEAD pushed from a protected branch name" 'git push origin HEAD:refs/heads/master'
oa "tags namespace (refs/tags/)"                          'git push origin HEAD:refs/tags/v2.0.0'
oa "tags namespace, existing local tag"                   'git push origin refs/tags/v1.2.3'
oa "tag named like a protected branch stays in tags/"     'git push origin HEAD:refs/tags/main'
oa "bare tag name"                                        'git push origin v1.2.3'
oa "'tag <name>' form"                                    'git push origin tag v1.2.3'
oa "--tags before the remote"                             'git push --tags origin'
oa "--tags after the remote"                              'git push origin --tags'
ha "unqualified tags/ destination"                        'git push origin HEAD:tags/v2.0.0'
oa "task branch"                                          'git push origin task/1-x'
oa "task branch with explicit src:dst"                    'git push origin task/1-x:task/1-x'
oa "task branch fully qualified"                          'git push origin HEAD:refs/heads/task/1-x'
oa "task branch name that merely contains 'main'"         'git push origin HEAD:refs/heads/task/12-main-fix'
oa "task branch name that merely contains 'staging'"      'git push origin HEAD:task/12-staging-page'
oa "wildcard task namespace maps to itself"               "git push origin 'refs/heads/task/*:refs/heads/task/*'"
cls_end

# =============================================================================
cls "lexing / invocation form"
# =============================================================================
ob "subshell"                                             '(git push origin HEAD:main)'
ob "subshell after another command"                       'echo hi; (git push origin task/1-x HEAD:main)'
ob "command substitution"                                 'echo $(git push origin HEAD:main)'
ob "backtick substitution"                                'echo `git push origin HEAD:main`'
ob "substitution as an argument of another command"       'true "$(git push origin HEAD:main)"'
ob "nested substitution"                                  'echo "$(echo $(git push origin HEAD:main))"'
ob "line continuation inside the refspec"                 $'git push origin HEAD:ma\\\nin'
ob "line continuation between words"                      $'git push \\\n origin HEAD:main'
ob "escaped character in the branch name"                 'git push origin HEAD:m\ain'
ob "empty quotes in the branch name"                      "git push origin HEAD:ma''in"
ob "quote closed mid-name"                                'git push origin "HEAD:ma"in'
ob "escaped character in the git word"                    'g\it push origin HEAD:main'
ob "double-quoted git word"                               '"git" push origin HEAD:main'
ob "single-quoted git word"                               "'git' push origin HEAD:main"
ob "leading backslash on the git word"                    '\git push origin HEAD:main'
ob "path-qualified git binary"                            '@GITBIN@ push origin HEAD:main'
ob "brace expansion in the refspec"                       'git push origin HEAD:{main,x}'
ob "brace expansion in the branch name"                   'git push origin HEAD:ma{in,xx}'
ob "variable in the refspec"                              'b=main; git push origin HEAD:$b'
ob "variable with default in the refspec"                 'git push origin "HEAD:${b:-main}"'
ob "substitution producing the refspec"                   'git push origin "$(echo HEAD:main)"'
ob "bash -c body"                                         "bash -c 'git push origin HEAD:main'"
ob "bash -ec body"                                        "bash -ec 'git push origin HEAD:main'"
ob "sh -c body"                                           'sh -c "git push origin HEAD:main"'
ob "eval with one argument"                               "eval 'git push origin HEAD:main'"
ob "eval with several arguments"                          'eval git push origin HEAD:main'
ob "bash -c nested in bash -c"                            "bash -c \"bash -c 'git push origin HEAD:main'\""
ob "eval nested in bash -c"                               "bash -c \"eval 'git push origin HEAD:main'\""
ob "substitution inside a bash -c body"                   "bash -c 'echo \$(git push origin HEAD:main)'"
ob "substitution inside an unquoted heredoc body"         $'cat <<EOF\n$(git push origin HEAD:main)\nEOF'
ha "same text inside a quoted heredoc is inert prose"     $'cat <<\'EOF\'\n$(git push origin HEAD:main)\nEOF'
ob "find -exec"                                          'find . -maxdepth 0 -exec git push origin HEAD:main \;'
ob "env wrapper"                                          'env GIT_X=1 git push origin HEAD:main'
ob "command wrapper"                                      'command git push origin HEAD:main'
ob "time keyword"                                         'time git push origin HEAD:main'
ob "exec wrapper"                                         'exec git push origin HEAD:main'
ob "leading assignment"                                   'X=1 git push origin HEAD:main'
ob "if body"                                              'if true; then git push origin HEAD:main; fi'
ob "&& chain"                                             'true && git push origin HEAD:main'
ob "|| chain"                                             'false || git push origin HEAD:main'
ob "brace group"                                          '{ git push origin HEAD:main; }'
ob "for loop body"                                        'for i in 1; do git push origin HEAD:main; done'
ob "after a pipe"                                         'echo x | git push origin HEAD:main'
ob "-C selecting the repository"                          'git -C @WORK@ push origin HEAD:main'
ob "-c before the subcommand"                             'git -c core.pager=cat push origin HEAD:main'
ob "two -c options"                                       'git -c user.name=x -c user.email=y@z push origin HEAD:main'
ob "--no-pager"                                           'git --no-pager push origin HEAD:main'
ob "--git-dir"                                            'git --git-dir=@WORK@/.git push origin HEAD:main'
ob "GIT_DIR assignment"                                   'GIT_DIR=@WORK@/.git git push origin HEAD:main'
hb "--repo=<remote> (git reads HEAD:main as a remote; hook is conservative)" 'git push --repo=origin HEAD:main'
hb "--repo <remote> (same, separate value)"               'git push --repo origin HEAD:main'
ob "-v verbosity flag"                                    'git push -v origin HEAD:main'
ob "-q -u flags"                                          'git push -q -u origin HEAD:main'
ob "--porcelain"                                          'git push --porcelain origin HEAD:main'
ob "--recurse-submodules=no"                              'git push --recurse-submodules=no origin HEAD:main'
ob "-- before the positionals"                            'git push -- origin HEAD:main'
ob "-- between remote and refspec"                        'git push origin -- HEAD:main'
hb "-o takes a value then the refspec"                    'git push -o ci.skip origin HEAD:main'
hb "--push-option=<v> then a protected refspec"           'git push --push-option=x origin task/1-x HEAD:main'
hb "force flag clustered with another"                    'git push -fu origin task/1-x'
hb "force flag clustered after another"                   'git push -uf origin task/1-x'
oa "-C selecting the repository, task branch"             'git -C @WORK@ push origin task/1-x'
oa "-u flag"                                              'git push -u origin task/1-x'
oa "--set-upstream flag"                                  'git push --set-upstream origin task/1-x'
oa "--force-with-lease"                                   'git push --force-with-lease origin task/1-x'
oa "--force-with-lease=<ref>"                             'git push --force-with-lease=task/1-x origin task/1-x'
oa "--force-if-includes with lease"                       'git push --force-with-lease --force-if-includes origin task/1-x'
oa "bare HEAD on a task branch"                           'git push origin HEAD'
oa "-u with HEAD on a task branch"                        'git push -u origin HEAD'
oa "bash -c body, task branch"                            "bash -c 'git push origin task/1-x'"
oa "wrapper chain, task branch"                           'env GIT_X=1 command git push origin task/1-x'
ha "--force-with-lease prefix"                            'git push --force-with origin task/1-x'
ha "--delete a task branch"                               'git push --delete origin task/1-x'
ha "push with only a remote on a task branch"             'git push origin'
ha "no arguments at all"                                  'git push'
cls_end

# =============================================================================
cls "unresolved expansion fails closed"
# =============================================================================
hb "variable as the command word"                         'g=git; $g push origin task/1-x'
hb "quoted variable as the command word"                  'g=git; "$g" push origin task/1-x'
hb "braced variable as the command word"                  'g=git; ${g} push origin task/1-x'
hb "substitution as the command word"                     '$(echo git) push origin task/1-x'
hb "backtick substitution as the command word"            '`echo git` push origin task/1-x'
ob "glob character in a path-qualified command word"      '@GITGLOB@ push origin HEAD:main'
hb "dashed git-push form"                                 'git-push origin HEAD:main'
hb "variable inside the refspec"                          'git push origin task/$ID-x'
hb "braced variable inside the refspec"                   'git push origin "task/${ID}-x"'
hb "variable as the whole refspec"                        'git push origin "$REF"'
hb "variable as options"                                  'git push $OPTS origin task/1-x'
hb "variable as a long option"                            'git push --$O origin task/1-x'
hb "variable as a short option"                           'git push -$F origin task/1-x'
hb "brace expansion in the refspec"                       'git push origin task/{1,2}-x'
hb "substitution as the refspec"                          'git push origin $(git rev-parse --abbrev-ref HEAD)'
hb "substitution as the remote"                           'git push "$(echo origin)" task/1-x'
ob "nesting beyond the recursion bound"                   "$(c='git push origin HEAD:main'; for _ in 1 2 3 4 5 6; do c="$(printf 'bash -c %q' "$c")"; done; printf '%s' "$c")"
ob "nesting within the recursion bound"                   "$(c='git push origin HEAD:main'; for _ in 1 2 3; do c="$(printf 'bash -c %q' "$c")"; done; printf '%s' "$c")"
ha "variable in a non-push command"                       'echo $HOME'
ha "variable argument to a builtin git subcommand"        'git status $X'
ha "substitution argument to a builtin git subcommand"    'git log "$(git rev-parse HEAD)" --oneline'
ha "variable in a branch name for checkout"               'git checkout -b task/$ID-x'
ha "variable commit message"                              'git commit -m "$MSG"'
ha "variable file list for add"                           'git add $FILES'
ha "variable in a diff range"                             'git diff ${BASE}...HEAD'
ha "variable command word without any push text"          '$EDITOR notes.md'
ha "loop with a variable around git add"                  'for f in *.md; do git add "$f"; done'
ha "date substitution in a commit message"                'git commit -m "$(date)"'
cls_end

# =============================================================================
cls "alias / config / plumbing"
# =============================================================================
ob "in-command alias for push"                            'git -c alias.zz=push zz origin HEAD:main'
ob "in-command alias carrying the remote"                 "git -c alias.zz='push origin' zz HEAD:main"
ob "in-command shell alias"                               "git -c 'alias.zz=!git push origin HEAD:main' zz"
ob "in-command shell alias with a function and \"\$@\""   "git -c 'alias.zz=!f() { git push origin \"\$@\"; }; f' zz HEAD:main"
ob "persistent alias for push"                            'git zz origin HEAD:main' 'git config alias.zz push'
ob "persistent alias carrying the remote"                 'git zz HEAD:main' 'git config alias.zz "push origin"'
ob "persistent shell alias"                               'git zz' 'git config alias.zz "!git push origin HEAD:main"'
ob "persistent alias chain"                               'git zz origin HEAD:main' 'git config alias.yy push; git config alias.zz yy'
ob "persistent alias resolved through -C"                 'git -C @WORK@ zz origin HEAD:main' 'git config alias.zz push'
ob "alias written and used in one command"                'git config alias.zz push && git zz origin HEAD:main'
ob "persistent alias for push plumbing"                   'git zz @REMOTE@ HEAD:refs/heads/main' 'git config alias.zz send-pack'
ob "alias injected through numbered environment config"   'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.zz GIT_CONFIG_VALUE_0=push git zz origin HEAD:main'
ob "alias injected through the parameters variable"       "GIT_CONFIG_PARAMETERS=\"'alias.zz=push'\" git zz origin HEAD:main"
ob "alias injected through --config-env=…"                'ALIASV=push git --config-env=alias.zz=ALIASV zz origin HEAD:main'
ob "alias injected through --config-env …"                'ALIASV=push git --config-env alias.zz=ALIASV zz origin HEAD:main'
ob "in-command remote push refspec"                       'git -c remote.origin.push=HEAD:main push'
ob "in-command remote push refspec with a remote"         'git -c remote.origin.push=HEAD:main push origin'
ob "persistent remote push refspec"                       'git push' 'git config remote.origin.push HEAD:main'
ob "persistent remote push refspec with a remote"         'git push origin' 'git config remote.origin.push HEAD:main'
ob "persistent remote push wildcard"                      'git push' "git config remote.origin.push 'refs/heads/*:refs/heads/*'"
ob "remote push refspec injected through the environment" 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=HEAD:main git push'
ob "persistent push.default=matching"                     'git push' 'git config push.default matching'
ob "in-command push.default=matching with a remote"       'git -c push.default=matching push origin'
ob "persistent push.default=upstream tracking a protected branch" 'git push' 'git config push.default upstream; git branch -q --set-upstream-to=origin/main'
ob "bare push while a protected branch is checked out"    'git push' 'git checkout -q main'
ob "remote-only push while a protected branch is checked out" 'git push origin' 'git checkout -q main'
ob "HEAD refspec while a protected branch is checked out" 'git push origin HEAD' 'git checkout -q main'
ob "HEAD with -u while a protected branch is checked out" 'git push -u origin HEAD' 'git checkout -q main'
ob "@ refspec while a protected branch is checked out"    'git push origin @' 'git checkout -q main'
ob "plumbing: send-pack to a protected ref"               'git send-pack @REMOTE@ HEAD:refs/heads/main'
ob "plumbing: send-pack through -C"                       'git -C @WORK@ send-pack @REMOTE@ HEAD:refs/heads/main'
ob "plumbing: path-qualified send-pack"                   '@GITBIN@ send-pack @REMOTE@ HEAD:refs/heads/main'
hb "plumbing: send-pack to a task ref (blocked categorically)" 'git send-pack origin task/1-x'
hb "plumbing: http-push to a protected ref"               'git http-push http://example.invalid/r.git HEAD:main'
hb "plumbing: http-push to a task ref (blocked categorically)" 'git http-push http://example.invalid/r.git task/1-x'
hb "plumbing: dashed send-pack"                           'git-send-pack origin task/1-x'
hb "plumbing: dashed http-push"                           'git-http-push http://example.invalid/r.git task/1-x'
hb "config write: alias"                                  'git config alias.zz push'
hb "config write: alias, --local"                         'git config --local alias.zz push'
hb "config write: alias, --global"                        'git config --global alias.zz push'
hb "config write: shell alias value"                      'git -C /x config alias.zz "!git push origin HEAD:main"'
hb "config write: alias through --file"                   'git config --file .git/config alias.zz push'
hb "config write: alias key in mixed case"                'git config Alias.ZZ push'
hb "config write: remote push refspec"                    'git config remote.origin.push HEAD:main'
hb "config write: remote push refspec, --local"           'git config --local remote.origin.push HEAD:main'
hb "config write: remote push refspec, --add"             'git config --add remote.origin.push HEAD:main'
hb "config write: remote push refspec, --replace-all"     'git config --replace-all remote.origin.push HEAD:main'
hb "config write: remote pushurl"                         'git config remote.origin.pushurl /x/y'
hb "config write: push.default"                           'git config --global push.default matching'
hb "config write behind a -c option"                      'git -c core.x=y config alias.zz push'
ha "config read: --get alias"                             'git config --get alias.zz'
ha "config read: single key"                              'git config alias.zz'
ha "config read: regexp"                                  'git config --get-regexp "^alias\."'
ha "config read: list"                                    'git config --list'
ha "config read: push.default"                            'git config --global --get push.default'
ha "config write: unrelated key"                          'git config user.name "Atelier"'
ha "config write: unrelated key, --local"                 'git config --local user.email a@b.example'
ha "config write: pull.rebase"                            'git config pull.rebase true'
ha "config write: remote url"                             'git config remote.origin.url https://github.com/o/r.git'
ha "config removal: unset alias"                          'git config --unset alias.zz'
oa "persistent alias for status"                          'git st' 'git config alias.st status'
oa "in-command alias for status"                          'git -c alias.st=status st'
oa "persistent shell alias that is not a push"            'git hi' 'git config alias.hi "!echo hi"'
oa "persistent alias chain that is not a push"            'git co2' 'git config alias.co checkout; git config alias.co2 "co task/1-x"'
cls_end

# =============================================================================
cls "option prefix / receive-pack / prune"
# =============================================================================
ob "--mirror abbreviated to --mirr"                       'git push --mirr origin'
ob "--mirror abbreviated to --mir"                        'git push --mir origin'
ob "--mirror abbreviated to --mirro, after the remote"    'git push origin --mirro'
ob "--all abbreviated to --al"                            'git push --al origin'
ob "--branches (alias of --all)"                          'git push --branches origin'
ob "--branches abbreviated to --br"                       'git push --br origin'
hb "--all abbreviated to --a (ambiguous for git, conservative)" 'git push --a origin'
hb "--force abbreviated to --forc"                        'git push --forc origin task/1-x'
hb "--force abbreviated to --for"                         'git push --for origin task/1-x'
hb "--force abbreviated to --fo"                          'git push --fo origin task/1-x'
ob "--receive-pack=<prog>"                                'git push --receive-pack=@RP@ origin task/1-x'
ob "--receive-pack <prog>"                                'git push --receive-pack @RP@ origin task/1-x'
ob "--exec=<prog>"                                        'git push --exec=@RP@ origin task/1-x'
ob "--receive-pack abbreviated"                           'git push --receive-pa=@RP@ origin task/1-x'
ob "--exec abbreviated"                                   'git push --exe=@RP@ origin task/1-x'
hb "--receive-pack with a harmless program"               'git push --receive-pack=/bin/true origin task/1-x'
hb "--prune without a refspec"                            'git push --prune origin'
hb "--prune abbreviated to --prun, without a refspec"     'git push --prun origin'
hb "--prune abbreviated to --pru, without a refspec"      'git push --pru origin'
ha "--prune scoped to one task refspec"                   'git push --prune origin task/1-x'
oa "--dry-run on a task branch"                           'git push --dry-run origin task/1-x'
cls_end

# =============================================================================
cls "allow guard (no over-blocking)"
# =============================================================================
ha "task/<id>-<slug> push"                                'git push origin task/12-foo'
ha "-u form"                                              'git push -u origin task/12-foo'
ha "--set-upstream form"                                  'git push --set-upstream origin task/12-foo'
ha "--force-with-lease form"                              'git push --force-with-lease origin task/12-foo'
ha "semver tag push"                                      'git push origin v0.38.0'
ha "--tags push"                                          'git push --tags origin'
ha "git -C <path> push to a task branch"                  'git -C /some/other/path push origin task/12-foo'
ha "git -C <path> push -u to a task branch"               'git -C /some/other/path push -u origin task/12-foo'
oa "ordinary commit with -c identity"                     'git -c user.name=Foo -c user.email=foo@example.invalid commit --allow-empty -q -m "chore: x"'
oa "commit message mentioning a protected push"           'git commit --allow-empty -q -m "explain that git push origin main is denied"'
ha "commit message mentioning a force push"               'git commit -m "Document why git push --force origin main is denied"'
ha "commit message with backticks in single quotes"       "git commit -m 'mention \`git push origin main\` in backticks'"
ha "commit message with a quoted refspec"                 'git commit -m "docs: git push origin HEAD:main is blocked by the hook"'
ha "commit message through -F - and a quoted heredoc"     $'git commit -q --allow-empty -F - <<\'EOF\'\nnote: run git push origin HEAD:main manually\nEOF'
ha "commit message through \$(cat <<'EOF')"               $'git commit -m "$(cat <<\'EOF\'\nfix: docs about git push --force origin main\nEOF\n)"'
ha "PR body through \$(cat <<'EOF') with backticks"       $'gh pr create --title t --body "$(cat <<\'EOF\'\n## Summary\nNever run `git push origin main`\nEOF\n)"'
ha "PR body mentioning a protected push"                  'gh pr create --title "t" --body "Do not git push origin main or git push --force"'
ha "heredoc prose written to a file"                      $'cat > notes.md <<\'EOF\'\ngit push origin main\nEOF'
ha "unquoted heredoc prose without substitutions"         $'cat <<EOF\ngit push --force origin main\nEOF'
ha "echo of a push, double-quoted"                        'echo "git push origin main"'
ha "echo of a push, single-quoted"                        "echo 'git push origin HEAD:main'"
ha "echo of a push, unquoted"                             'echo git push origin main'
ha "git log --grep for a push"                            'git log --grep="git push origin main" --oneline'
ha "ripgrep for a push"                                   'rg -n "git push" docs'
ha "cat .gitignore"                                       'cat .gitignore'
ha "ls .github"                                           'ls .github'
ha "word containing git"                                  'echo digit'
ha "word containing push"                                 'echo pushing'
ha "pushd builtin"                                        'pushd /tmp'
ha "git stash push"                                       'git stash push -m wip'
ha "git status"                                           'git status --short'
ha "git fetch of a protected branch"                      'git fetch origin main'
ha "git pull of a protected branch"                       'git pull --ff-only origin main'
ha "git merge of a protected branch"                      'git merge origin/main'
ha "git checkout of a protected branch"                   'git checkout main'
ha "git remote prune"                                     'git remote prune origin'
ha "git fetch --prune"                                    'git fetch --prune origin'
ha "git branch --set-upstream-to a protected branch"      'git branch --set-upstream-to=origin/main'
ha "grep over a log that mentions push"                   'cat git.log | grep push'
ha "script name containing push"                          'github-push-notes.sh --dry'
ha "non-git command (ls)"                                 'ls -la'
cls_end

# =============================================================================
cls "large payload"
# =============================================================================
# The hooks.json entry for this hook sets no timeout, so the platform default
# applies (PLAN.md assumes a 10 s ceiling). A run past the bound is treated by
# Claude Code as a non-blocking error, i.e. it would allow: the hook must either
# finish well inside the bound or fail closed — never run long and allow.
LARGE_BOUND=10
rawfile_rc() { # file → rc (stdin JSON built from the file with jq --rawfile)
  local f="$1"
  jq -cn --rawfile c "$f" '{tool_name:"Bash", tool_input:{command:$c}}' > "$f.json"
  (
    cd "$BASE_WORK" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$HOOK" < "$f.json" >/dev/null 2>&1
    echo "$?"
  )
}
large_case() { # desc file expected-rc
  local desc="$1" f="$2" want="$3" t0 t1 code
  CASES=$((CASES + 1))
  [ "$want" = "2" ] && BLOCK_CASES=$((BLOCK_CASES + 1))
  t0=$SECONDS
  code="$(rawfile_rc "$f")"
  t1=$SECONDS
  if [ "$((t1 - t0))" -ge "$LARGE_BOUND" ]; then
    [ "$want" = "2" ] && BLOCK_FAILS=$((BLOCK_FAILS + 1))
    fail "$desc took $((t1 - t0))s (bound ${LARGE_BOUND}s): a hook timeout fails open"
  elif [ "$code" = "$want" ]; then
    pass "$desc → exit $code in $((t1 - t0))s (bound ${LARGE_BOUND}s)"
  else
    [ "$want" = "2" ] && BLOCK_FAILS=$((BLOCK_FAILS + 1))
    fail "$desc expected exit $want, got $code"
  fi
}

# ~60 KB, 2500 git segments, no push: allowed, quickly
{ yes 'git log --oneline -1 -- file.txt' | head -n 2500; } > "$TMP/large1" 2>/dev/null
# the same followed by a real push to a protected branch: blocked, quickly
{ cat "$TMP/large1"; printf 'git push origin HEAD:main\n'; } > "$TMP/large2"
# tens of KB of prose in one commit message that mentions git: allowed, quickly
{ printf 'git commit -m "'; yes 'git push origin main is documented here with some more prose.' | head -n 900; printf '"\n'; } > "$TMP/large3" 2>/dev/null
# more segments than the analysis bound that names git: fails closed (blocked)
{ yes 'git status;' | head -n 6000; } > "$TMP/large4" 2>/dev/null
# larger than the size bound that names git: fails closed (blocked)
{ printf 'git status; echo '; head -c 200000 /dev/zero | tr '\0' 'a'; printf '\n'; } > "$TMP/large5"
large1_bytes="$(wc -c < "$TMP/large1" | tr -d ' ')"
if [ "$large1_bytes" -ge 50000 ]; then pass "generated payload 1 is tens of KB ($large1_bytes bytes)"
else fail "payload 1 too small ($large1_bytes bytes)"; fi
large_case "60 KB of git commands with no push"           "$TMP/large1" 0
large_case "60 KB of git commands ending in a protected push" "$TMP/large2" 2
large_case "60 KB commit message prose mentioning a push" "$TMP/large3" 0
large_case "6000 segments naming git"                     "$TMP/large4" 2
large_case "200 KB command naming git"                    "$TMP/large5" 2
cls_end

# =============================================================================
echo
echo "  -- case count by class --"
printf '%s' "$CLASS_SUMMARY"
printf '  %-34s %s\n' "total cases" "$CASES"
printf '  block assertions: total=%s not-blocked=%s\n' "$BLOCK_CASES" "$BLOCK_FAILS"

echo
if [ "$fails" -eq 0 ]; then
  echo "All #808 block-protected-push hardening checks passed."
  exit 0
else
  echo "$fails #808 block-protected-push hardening check(s) FAILED."
  exit 1
fi
