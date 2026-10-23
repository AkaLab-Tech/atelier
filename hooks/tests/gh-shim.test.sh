#!/usr/bin/env bash
#
# Regression test for the atelier `gh` shim (#582): scripts/shims/gh enforces
# the GitHub identity at exec time. Review-like / credential-exfiltrating calls
# are refused unless the identity is an atelier one (GH_CONFIG_DIR pointing at
# $ATELIER_CONFIG_DIR/gh/{author,reviewer}, no token env); everything else is
# exec'd unchanged on the real gh.
#
# Hermetic: temp HOME / ATELIER_CONFIG_DIR / ~/.config/gh, a stub "real" gh that
# echoes its argv, no network, no real credentials. Every case runs under
# `bash -c` and (when present) `zsh -c`, with the environment built by `env -i`.
#
# Run:  hooks/tests/gh-shim.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIM_SRC="$REPO_ROOT/scripts/shims"

TMP="$(cd -P "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
ACD="$TMP/acd"
STUB="$TMP/stub"       # holds the stub "real" gh
WRAP="$TMP/wrap"       # stub timeout / sudo
SHIM2="$TMP/shim2"     # second copy of the shim
mkdir -p "$HOME_DIR/.config/gh" "$ACD/gh/author" "$ACD/gh/reviewer" "$STUB" "$WRAP" "$SHIM2" "$TMP/other"

PERSONAL="$HOME_DIR/.config/gh"
AUTHOR="$ACD/gh/author"
REVIEWER="$ACD/gh/reviewer"

cat > "$STUB/gh" <<'E'
#!/bin/sh
echo "REAL-GH"
for a in "$@"; do echo "ARG[$a]"; done
echo "CFG=${GH_CONFIG_DIR-unset}"
echo "TOK=${GH_TOKEN-unset}"
echo "IN=$(cat)"
exit "${STUB_EXIT:-0}"
E
chmod +x "$STUB/gh"

# Stub timeout: skips `-s SIG`, then DURATION, then execs the command.
cat > "$WRAP/timeout" <<'E'
#!/bin/sh
while [ "$1" != "${1#-}" ]; do case "$1" in -s|-k) shift 2 ;; *) shift ;; esac; done
shift
exec "$@"
E
# Stub sudo: skips `-u USER`, then execs the command.
cat > "$WRAP/sudo" <<'E'
#!/bin/sh
while [ "$1" != "${1#-}" ]; do case "$1" in -u|-g) shift 2 ;; *) shift ;; esac; done
exec "$@"
E
chmod +x "$WRAP/timeout" "$WRAP/sudo"

cp "$SHIM_SRC/gh" "$SHIM2/gh"; chmod +x "$SHIM2/gh"

# Hermetic tool dir: symlinks to every executable of /usr/bin and /bin EXCEPT any
# system `gh` (CI runners ship /usr/bin/gh), so no real gh is reachable except $STUB.
TOOLS="$TMP/tools"; mkdir -p "$TOOLS"
for d in /usr/bin /bin; do
  for f in "$d"/*; do
    b="${f##*/}"
    [ "$b" = gh ] && continue
    [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$TOOLS/$b" ] && ln -s "$f" "$TOOLS/$b"
  done
done
BASEPATH="$SHIM_SRC:$WRAP:$STUB:$TOOLS"

SHELLS=(bash)
command -v zsh >/dev/null 2>&1 && SHELLS+=(zsh)

fails=0; total=0
pass() { total=$((total + 1)); printf '  PASS: %s\n' "$1"; }
fail() { total=$((total + 1)); printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

OUT=""; RC=0
# run SHELL IDENT CMD [KEY=VAL ...]  — IDENT: author|reviewer|personal|none
run() {
  local sh="$1" ident="$2" cmd="$3"; shift 3
  local envs=(HOME="$HOME_DIR" PATH="$BASEPATH" ATELIER_CONFIG_DIR="$ACD")
  case "$ident" in
    author) envs+=(GH_CONFIG_DIR="$AUTHOR") ;;
    reviewer) envs+=(GH_CONFIG_DIR="$REVIEWER") ;;
    personal) envs+=(GH_CONFIG_DIR="$PERSONAL") ;;
    none) ;;
  esac
  OUT="$(env -i "${envs[@]}" "$@" "$sh" -c "$cmd" </dev/null 2>&1)"; RC=$?
}

# blocked NAME IDENT CMD [KEY=VAL ...]: refused (stderr BLOCKED, stub never ran) in every shell.
blocked() {
  local name="$1" ident="$2" cmd="$3"; shift 3
  local sh
  for sh in "${SHELLS[@]}"; do
    run "$sh" "$ident" "$cmd" "$@"
    if printf '%s' "$OUT" | grep -q 'atelier-gh-shim: BLOCKED' && ! printf '%s' "$OUT" | grep -q 'REAL-GH'; then
      pass "$name [$sh]"
    else
      fail "$name [$sh]: expected BLOCKED w/o stub run, got rc=$RC out=$(printf '%s' "$OUT" | head -c 300)"
    fi
  done
}

# passes NAME IDENT CMD EXPECTED_ARGS_TEXT [KEY=VAL ...]: stub ran with exactly those ARG lines.
passes() {
  local name="$1" ident="$2" cmd="$3" want="$4"; shift 4
  local sh got
  for sh in "${SHELLS[@]}"; do
    run "$sh" "$ident" "$cmd" "$@"
    got="$(printf '%s\n' "$OUT" | grep '^ARG\[' )"
    if printf '%s' "$OUT" | grep -q '^REAL-GH$' && [ "$got" = "$want" ] && ! printf '%s' "$OUT" | grep -q BLOCKED; then
      pass "$name [$sh]"
    else
      fail "$name [$sh]: want args <$want>, got rc=$RC out=$(printf '%s' "$OUT" | head -c 300)"
    fi
  done
}

echo "== static =="
bash -n "$SHIM_SRC/gh" && pass "bash -n scripts/shims/gh" || fail "bash -n scripts/shims/gh"
[ -x "$SHIM_SRC/gh" ] && pass "shim is executable" || fail "shim not executable"
[ "$(sed -n '2p' "$SHIM_SRC/gh")" = "# atelier-gh-shim" ] && pass "shim carries the marker line" || fail "marker line missing"

echo "== refused under a personal identity =="
blocked "pr review"                personal 'gh pr review 1 --approve'
blocked "pr comment"               personal 'gh pr comment 1 -b hi'
blocked "pr -R o/r review"         personal 'gh pr -R o/r review 1'
blocked "issue comment"            personal 'gh issue comment 3 -b hi'
blocked "auth token"               personal 'gh auth token'
blocked "auth status --show-token" personal 'gh auth status --show-token'
blocked "auth status -t"           personal 'gh auth status -t'
blocked "auth status --show-token=true" personal 'gh auth status --show-token=true'
blocked "auth status -at"          personal 'gh auth status -at'
blocked "auth status -ta"          personal 'gh auth status -ta'
blocked "api graphql URL with # fragment" personal "gh api 'https://api.github.com/graphql#' -f query='mutation{addPullRequestReview(input:{})}'"
blocked "api graphql URL with port" personal "gh api https://api.github.com:443/graphql -f query='mutation{addComment(input:{})}'"
blocked "api graphql GHE /api/graphql" personal "gh api https://ghe.example/api/graphql -f query='mutation{addComment(input:{})}'"
blocked "api reviews path with # fragment" personal "gh api 'repos/o/r/pulls/1/reviews#x' -X POST"
blocked "api reviews URL with port" personal 'gh api https://api.github.com:443/repos/o/r/pulls/1/reviews -f body=x'
blocked "api -XPOST pulls/1/reviews" personal 'gh api -XPOST repos/o/r/pulls/1/reviews'
blocked "api -X POST issues/1/comments" personal 'gh api -X POST repos/o/r/issues/1/comments'
blocked "api --method=PATCH pulls/comments/9" personal 'gh api --method=PATCH repos/o/r/pulls/comments/9'
blocked "api -f body implies write" personal 'gh api repos/o/r/issues/1/comments -f body=x'
blocked "api URL + query normalised" personal 'gh api "https://api.github.com/repos/O/R/Pulls/1/Reviews?x=1" -X POST'
blocked "graphql addPullRequestReview" personal "gh api graphql -f query='mutation{addPullRequestReview(input:{pullRequestId:\"x\"}){clientMutationId}}'"
blocked "graphql addComment"       personal "gh api graphql -f query='mutation{addComment(input:{})}'"
blocked "graphql --input fails closed" personal 'gh api graphql --input q.json'
blocked "graphql query=@file fails closed" personal 'gh api graphql -F query=@q.graphql'
blocked "gh alias (non built-in)"  personal 'gh myalias foo'
blocked "gh extension"             personal 'gh someext run'

echo "== shell-level evasions are refused at exec time =="
blocked "reserved word time"       personal 'time gh pr review 1'
blocked "negation !"               personal '! gh pr review 1'
blocked "brace group"              personal '{ gh pr review 1; }'
blocked "subshell"                 personal '(gh pr review 1)'
blocked "command substitution"     personal 'echo $(gh pr review 1)'
blocked 'argument $(pwd) suffix'   personal 'gh pr review 1 -b "x$(pwd)"'
blocked "backtick substitution"    personal 'echo `gh pr review 1`'
blocked "command builtin"          personal 'command gh pr review 1'
blocked "exec builtin"             personal 'exec gh pr review 1'
blocked "env wrapper"              personal 'env gh pr review 1'
blocked "nice wrapper"             personal 'nice gh pr review 1'
blocked "nohup wrapper"            personal 'nohup gh pr review 1'
blocked "function wrapping gh"     personal 'w() { gh "$@"; }; w pr review 1'
blocked "function named gh"        personal 'gh() { command gh "$@"; }; gh pr review 1'
blocked "alias (expand_aliases)"   personal $'shopt -s expand_aliases 2>/dev/null\nalias g="gh pr review"\neval "g 1"'
blocked "pipeline"                 personal 'echo x | gh pr review 1'
blocked "background + wait"        personal 'gh pr review 1 & wait'
blocked "bash -c nested"           personal 'bash -c "gh pr review 1"'
blocked "xargs option with separate value" personal 'echo 1 | xargs -I {} gh pr review {} -b x'
blocked "timeout -s KILL 5 gh"     personal 'timeout -s KILL 5 gh pr review 1'
blocked "sudo -u X gh"             personal 'sudo -u someone gh pr review 1'
case "$(uname -s)" in
  Darwin) blocked "arch wrapper" personal "arch -$(uname -m) gh pr review 1" ;;
esac
# coproc only exists in bash/zsh -c; run it on its own so a missing keyword cannot mask the rest.
# bash 3.2 (macOS /bin/bash) has no coproc keyword: run it only where the keyword exists.
if [ "$(env -i PATH="$TOOLS" bash -c 'type coproc 2>&1' </dev/null)" = "coproc is a shell keyword" ]; then
  blocked "coproc" personal 'coproc gh pr review 1; wait'
else
  SHELLS_SAVE=("${SHELLS[@]}"); SHELLS=(zsh)
  command -v zsh >/dev/null 2>&1 && blocked "coproc (zsh only; bash lacks the keyword)" personal 'coproc gh pr review 1; wait'
  SHELLS=("${SHELLS_SAVE[@]}")
fi

echo "== identity is read from the real environment =="
blocked "unexported assignment (no GH_CONFIG_DIR in env)" none "GH_CONFIG_DIR='$AUTHOR'; gh pr review 1"
blocked "env -i drops GH_CONFIG_DIR" author "env -i PATH='$BASEPATH' gh pr review 1"
blocked "env -u GH_CONFIG_DIR" author 'env -u GH_CONFIG_DIR gh pr review 1'
if env --unset=ATELIER_X true >/dev/null 2>&1; then
  blocked "env --unset=GH_CONFIG_DIR" author 'env --unset=GH_CONFIG_DIR gh pr review 1'
else
  echo "  SKIP: env --unset= unsupported by this env (BSD); -u form covered above"
fi
blocked "GH_TOKEN inherited"       author 'gh pr review 1' GH_TOKEN=tok
blocked "GITHUB_TOKEN inherited"   author 'gh pr review 1' GITHUB_TOKEN=tok
blocked "GH_ENTERPRISE_TOKEN inherited" author 'gh pr review 1' GH_ENTERPRISE_TOKEN=tok
blocked "inline GH_TOKEN="         author 'GH_TOKEN=tok gh pr review 1'
blocked "inline GITHUB_TOKEN="     author 'GITHUB_TOKEN=tok gh pr review 1'
blocked "reviewer + token"         reviewer 'gh pr review 1' GH_TOKEN=tok
blocked "empty GH_CONFIG_DIR"      none 'gh pr review 1' GH_CONFIG_DIR=
blocked "nonexistent GH_CONFIG_DIR" none 'gh pr review 1' GH_CONFIG_DIR="$TMP/nope"
blocked "GH_CONFIG_DIR = other dir" none 'gh pr review 1' GH_CONFIG_DIR="$TMP/other"
blocked "XDG gh dir is personal"   none 'gh pr review 1' GH_CONFIG_DIR="$TMP/xdg/gh" XDG_CONFIG_HOME="$TMP/xdg"
blocked "auth token with token env under author" author 'gh auth token' GH_TOKEN=tok

echo "== exit code and message of a refusal =="
for sh in "${SHELLS[@]}"; do
  run "$sh" personal 'gh pr review 1'
  [ "$RC" = 1 ] && pass "refusal exits 1 [$sh]" || fail "refusal rc=$RC [$sh]"
  printf '%s' "$OUT" | grep -q 'Fix:' && pass "refusal names a Fix [$sh]" || fail "refusal lacks Fix [$sh]"
done

echo "== pass-through =="
for sh in "${SHELLS[@]}"; do
  run "$sh" author 'gh pr review 1 --approve'
  if printf '%s' "$OUT" | grep -q '^REAL-GH$' && printf '%s' "$OUT" | grep -q "^CFG=$AUTHOR\$"; then
    pass "author call passes with GH_CONFIG_DIR preserved [$sh]"
  else fail "author call [$sh]: $OUT"; fi
  run "$sh" reviewer 'gh pr review 1 --approve'
  if printf '%s' "$OUT" | grep -q '^REAL-GH$' && printf '%s' "$OUT" | grep -q "^CFG=$REVIEWER\$"; then
    pass "reviewer call passes with GH_CONFIG_DIR preserved [$sh]"
  else fail "reviewer call [$sh]: $OUT"; fi
done
passes "author: pr comment"  author   'gh pr comment 1 -b hi' $'ARG[pr]\nARG[comment]\nARG[1]\nARG[-b]\nARG[hi]'
passes "author: graphql review" author "gh api graphql -f query='mutation{addPullRequestReview(input:{})}'" $'ARG[api]\nARG[graphql]\nARG[-f]\nARG[query=mutation{addPullRequestReview(input:{})}]'
passes "personal: pr view"   personal 'gh pr view 1'   $'ARG[pr]\nARG[view]\nARG[1]'
passes "personal: issue list" personal 'gh issue list'  $'ARG[issue]\nARG[list]'
passes "none: pr view"       none     'gh pr view 1'   $'ARG[pr]\nARG[view]\nARG[1]'
passes "personal: project item-edit" personal 'gh project item-edit --id X' $'ARG[project]\nARG[item-edit]\nARG[--id]\nARG[X]'
passes "token env: project item-edit" none 'gh project item-edit --id X' $'ARG[project]\nARG[item-edit]\nARG[--id]\nARG[X]' GH_TOKEN=tok
passes "personal: GET on reviews (implicit)" personal 'gh api repos/o/r/pulls/1/reviews' $'ARG[api]\nARG[repos/o/r/pulls/1/reviews]'
passes "personal: explicit GET on reviews" personal 'gh api -X GET repos/o/r/pulls/1/reviews' $'ARG[api]\nARG[-X]\nARG[GET]\nARG[repos/o/r/pulls/1/reviews]'
passes "personal: POST to a non-review endpoint" personal 'gh api -X POST repos/o/r/issues' $'ARG[api]\nARG[-X]\nARG[POST]\nARG[repos/o/r/issues]'
passes "personal: graphql query without mutation" personal "gh api graphql -f query='{viewer{login}}'" $'ARG[api]\nARG[graphql]\nARG[-f]\nARG[query={viewer{login}}]'
passes "personal: auth status (no token)" personal 'gh auth status' $'ARG[auth]\nARG[status]'
passes "personal: auth status -h host" personal 'gh auth status -h github.com' $'ARG[auth]\nARG[status]\nARG[-h]\nARG[github.com]'
passes "personal: auth status -ah host" personal 'gh auth status -ah github.com' $'ARG[auth]\nARG[status]\nARG[-ah]\nARG[github.com]'
passes "personal: GET pulls/1" personal 'gh api repos/o/r/pulls/1' $'ARG[api]\nARG[repos/o/r/pulls/1]'
passes "personal: graphql viewer query" personal "gh api graphql -f query='{viewer{login}}'" $'ARG[api]\nARG[graphql]\nARG[-f]\nARG[query={viewer{login}}]'
passes "argv with spaces and empty arg preserved" personal 'gh pr view "a b" ""' $'ARG[pr]\nARG[view]\nARG[a b]\nARG[]'

for sh in "${SHELLS[@]}"; do
  run "$sh" personal 'echo piped-in | gh pr view 1'
  printf '%s' "$OUT" | grep -q '^IN=piped-in$' && pass "stdin preserved [$sh]" || fail "stdin lost [$sh]: $OUT"
  run "$sh" personal 'gh pr view 1' STUB_EXIT=7
  [ "$RC" = 7 ] && pass "exit code 7 preserved [$sh]" || fail "exit code: rc=$RC [$sh]"
  run "$sh" author 'gh pr review 1' STUB_EXIT=3
  [ "$RC" = 3 ] && pass "exit code 3 preserved under author [$sh]" || fail "exit code: rc=$RC [$sh]"
done

echo "== documented residual: absolute path to the real gh bypasses the shim =="
for sh in "${SHELLS[@]}"; do
  run "$sh" personal "$STUB/gh pr review 1"
  if printf '%s' "$OUT" | grep -q '^REAL-GH$' && ! printf '%s' "$OUT" | grep -q BLOCKED; then
    pass "absolute path bypasses the shim (residual, covered by the #544 hook) [$sh]"
  else fail "absolute-path residual changed [$sh]: $OUT"; fi
done

echo "== PATH resolution =="
# Two shim copies on PATH: both skipped (marker / own dir), no recursion, stub reached.
for sh in "${SHELLS[@]}"; do
  BP="$BASEPATH"; BASEPATH="$SHIM_SRC:$SHIM2:$STUB:$TOOLS"
  run "$sh" author 'gh pr view 1'
  BASEPATH="$BP"
  if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '^REAL-GH$'; then pass "two shim copies: no recursion, real gh reached [$sh]"
  else fail "two shims [$sh]: rc=$RC $OUT"; fi
  # Second copy first on PATH: still skips itself and the canonical one.
  BP="$BASEPATH"; BASEPATH="$SHIM2:$SHIM_SRC:$STUB:$TOOLS"
  run "$sh" personal 'gh pr review 1'
  BASEPATH="$BP"
  if printf '%s' "$OUT" | grep -q 'BLOCKED' && ! printf '%s' "$OUT" | grep -q REAL-GH; then pass "copy-first PATH still enforces [$sh]"
  else fail "copy-first [$sh]: rc=$RC $OUT"; fi
  # No real gh anywhere.
  BP="$BASEPATH"; BASEPATH="$SHIM_SRC:$SHIM2:$TOOLS"
  run "$sh" author 'gh pr view 1'
  BASEPATH="$BP"
  if [ "$RC" = 127 ] && printf '%s' "$OUT" | grep -q 'atelier-gh-shim: real gh not found on PATH'; then pass "no real gh: exit 127 with message [$sh]"
  else fail "no real gh [$sh]: rc=$RC $OUT"; fi
done

echo ""
if [ "$fails" -eq 0 ]; then echo "gh-shim: all $total assertions passed."; exit 0
else echo "gh-shim: $fails of $total assertion(s) failed."; exit 1; fi
