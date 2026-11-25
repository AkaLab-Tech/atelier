#!/usr/bin/env bash
#
# Regression test for #812 — hooks/block-gh-api-write.sh must let a `gh api`
# call through only when it can prove the call is a read, or a GraphQL mutation
# confined to the board-item operations the github-project backend uses
# (addProjectV2DraftIssue, addProjectV2ItemById, updateProjectV2ItemFieldValue,
# clearProjectV2ItemFieldValue, updateProjectV2DraftIssue) plus updateIssue and
# addComment. Everything the hook cannot read with certainty is a block.
#
# This file is the ONLY place in the repo that holds concrete bypass command
# shapes; the hook, PLAN.md and the docs describe the grammar, not the shapes.
#
# Groups:
#   A  writes that must block (implicit POST, method spellings, GraphQL
#      mutations outside the allowlist, wrappers/prefixes/quoting/nesting)
#   B  fail-closed controls (unknown flag/wrapper, expansion in a load-bearing
#      word, bodies the hook cannot inspect, headers, aliases, size caps)
#   C  positive controls: recipes shipped in the repo, read from the shipped
#      files at test time (never re-typed here), plus the read allow entries of
#      templates/settings.template.json converted to commands
#   D  board mutations: allowlisted shapes allow; a non-allowlisted mutation
#      next to an allowlisted one, and multiple operations, block
#   E  inert text, helper invocations, plain reads, jq-missing fail-open
#   F  lexer default-output invariance (origin/main lex vs the working copy)
#
# The roadmap-tracking-flow skill (claude-roadmap-tools plugin) ships outside
# this repo and describes its board writes as role-level steps
# (item-field-update, ...) with no literal `gh api` command to read at test
# time. Group D therefore embeds the minimal ProjectV2 mutation shapes the
# board backend uses.
#
# Hermetic: temporary HOME / CLAUDE_PROJECT_DIR (log_decision lands in the temp
# dir), a failing fake `gh` first on PATH (the hook must never call gh), no
# network. Requires jq (and git for group F, which skips without a repo).
#
# Run:  hooks/tests/block-gh-api-write.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2016,SC1003  # single quotes are intentional: the hook must see literal $VAR / $(...) text
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-gh-api-write.sh"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"
REAL_BASH="$(command -v bash)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/home" "$TMP/logs" "$TMP/work"
printf '#!/bin/sh\necho "fake gh must never be called" >&2\nexit 97\n' >"$BIN/gh"
chmod +x "$BIN/gh"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required for this suite"
  exit 0
fi

fails=0
CAT_NAMES=()
CAT_N=()
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

group() {
  CAT_NAMES+=("$1")
  CAT_N+=(0)
  printf '\n  -- %s --\n' "$1"
}
count_case() {
  local last=$((${#CAT_N[@]} - 1))
  CAT_N[last]=$((CAT_N[last] + 1))
}

# run_hook <command> -> rc in RC, stderr in $TMP/stderr
RC=""
run_hook() {
  local payload
  payload="$(jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$TMP/work" || exit 99
    HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" \
      PATH="$BIN:$PATH" bash "$HOOK" <<<"$payload" >/dev/null 2>"$TMP/stderr"
  )
  RC=$?
}

block() { # name command
  count_case
  run_hook "$2"
  if [ "$RC" = 2 ] && grep -q 'atelier:block-gh-api-write' "$TMP/stderr"; then
    pass "block: $1"
  else
    fail "block: $1 (exit=$RC, cmd: $2)"
  fi
}
allow() { # name command
  count_case
  run_hook "$2"
  if [ "$RC" = 0 ]; then
    pass "allow: $1"
  else
    fail "allow: $1 (exit=$RC, cmd: $2; stderr: $(head -c 300 "$TMP/stderr"))"
  fi
}

if [ ! -f "$HOOK" ]; then
  echo "FATAL: $HOOK not found"
  exit 1
fi

echo "#812 — hooks/block-gh-api-write.sh"

# A tiny valid mutation body used to build many shapes.
MUT_OK='mutation($i:ID!,$b:String!){addComment(input:{subjectId:$i,body:$b}){clientMutationId}}'

# =============================================================================
group "A1: implicit POST (fields / input without a method)"
# =============================================================================
block "-f field"               'gh api repos/o/r/issues -f title=x'
block "-F field"               'gh api repos/o/r/issues -F title=x'
block "--field"                'gh api repos/o/r/issues --field title=x'
block "--raw-field"            'gh api repos/o/r/issues --raw-field title=x'
block "--field=value form"     'gh api repos/o/r/issues --field=title=x'
block "-f clustered value"     'gh api repos/o/r/issues -ftitle=x'
block "-f before endpoint"     'gh api -f title=x repos/o/r/issues'
block "--input file"           'gh api repos/o/r/issues --input body.json'
block "--input stdin"          'gh api repos/o/r/issues --input -'
block "--input piped"          'printf "{}" | gh api repos/o/r/issues --input -'
block "--input=file"           'gh api repos/o/r/issues --input=body.json'
block "-f on merge endpoint"   'gh api repos/o/r/pulls/1/merge -f merge_method=squash'
block "-f on label endpoint"   'gh api repos/o/r/issues/1/labels -f labels[]=x'

# =============================================================================
group "A2: method flag spellings"
# =============================================================================
block "-X POST"                'gh api repos/o/r/issues -X POST'
block "-XPOST"                 'gh api repos/o/r/issues -XPOST'
block "-X=PATCH"               'gh api repos/o/r/issues/1 -X=PATCH'
block "-X=POST flags-first"    'gh api -X=POST repos/o/r/issues'
block "-X=PUT"                 'gh api -X=PUT repos/o/r/subscription'
block "-X=DELETE"              'gh api repos/o/r/issues/1/labels/x -X=DELETE'
block "--method POST"          'gh api --method POST repos/o/r/issues'
block "--method=PUT"           'gh api repos/o/r/x --method=PUT'
block "--method delete lower"  'gh api repos/o/r/git/refs/heads/x --method delete'
block "-Xpost lower"           'gh api repos/o/r/issues -Xpost'
block "-X PoSt mixed"          'gh api repos/o/r/issues -X PoSt'
block "quoted method value"    'gh api repos/o/r/issues -X "POST"'
block "single-quoted value"    "gh api repos/o/r/issues -X 'DELETE'"
block "quoted flag name"       'gh api repos/o/r/issues "-X" POST'
block "split-quoted long flag" 'gh api repos/o/r/issues --meth"od" POST'
block "-i cluster before X"    'gh api repos/o/r/issues -iXPOST'
block "GET then POST"          'gh api repos/o/r/issues -X GET -X POST'
block "POST then GET"          'gh api repos/o/r/issues -X POST -X GET'
block "--method GET then DEL"  'gh api repos/o/r/issues --method GET --method DELETE'
block "arbitrary verb"         'gh api repos/o/r/issues -X TRACE'
block "-X empty value"         'gh api repos/o/r/issues -X ""'
block "-X GET with --input"    'gh api repos/o/r/issues -X GET --input body.json graphql'
block "-X POST on graphql"     'gh api graphql -X POST -f query="query{viewer{login}}"'

# =============================================================================
group "A3: GraphQL mutations outside the allowlist"
# =============================================================================
block "mergePullRequest" \
  "gh api graphql -f query='mutation(\$id:ID!){mergePullRequest(input:{pullRequestId:\$id}){clientMutationId}}' -f id=x"
block "updateRef" \
  "gh api graphql -f query='mutation{updateRef(input:{refId:\"x\",oid:\"y\",force:true}){clientMutationId}}'"
block "createCommitOnBranch" \
  "gh api graphql -f query='mutation(\$i:CreateCommitOnBranchInput!){createCommitOnBranch(input:\$i){commit{oid}}}'"
block "deleteRef" \
  "gh api graphql -f query='mutation{deleteRef(input:{refId:\"x\"}){clientMutationId}}'"
block "enablePullRequestAutoMerge" \
  "gh api graphql -f query='mutation{enablePullRequestAutoMerge(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "addPullRequestReview" \
  "gh api graphql -f query='mutation{addPullRequestReview(input:{pullRequestId:\"x\",event:APPROVE}){clientMutationId}}'"
block "deleteProjectV2 (project-shaped but not listed)" \
  "gh api graphql -f query='mutation{deleteProjectV2(input:{projectId:\"x\"}){clientMutationId}}'"
block "alias reusing an allowed name" \
  "gh api graphql -f query='mutation{updateIssue: mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "named operation + variables" \
  "gh api graphql -f query='mutation Merge(\$id:ID!){ mergePullRequest(input:{pullRequestId:\$id}){clientMutationId} }'"
block "-F instead of -f" \
  "gh api graphql -F query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "--field query" \
  "gh api graphql --field query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "--raw-field=query" \
  "gh api graphql --raw-field=query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "endpoint /graphql" \
  "gh api /graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "endpoint GraphQL mixed case" \
  "gh api GraphQL -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "endpoint graphql with query string" \
  "gh api 'graphql?x=1' -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "endpoint graphql trailing slash" \
  "gh api graphql/ -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "endpoint absolute URL" \
  "gh api https://api.github.com/graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "--hostname with graphql" \
  "gh api --hostname ghe.example.com graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "mutation after a comment line" \
  "gh api graphql -f query=\$'# note\nmutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "mutation in the second query flag" \
  "gh api graphql -f query='query{viewer{login}}' -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "mutation with an unparseable body" \
  "gh api graphql -f query='mutation{updateIssue(input:{id:\"x\"}'"
block "mutation with an empty selection" \
  "gh api graphql -f query='mutation{}'"
block "mutation with a stray character" \
  "gh api graphql -f query='mutation{updateIssue(input:{id:\"x\"}){clientMutationId}} ~'"
block "subscription then mutation" \
  "gh api graphql -f query='subscription{a} mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "mutation as a bare shorthand-looking document" \
  "gh api graphql -f query='{ viewer { login } } mutation { updateRef(input:{refId:\"x\"}){clientMutationId} }'"

# =============================================================================
group "A4: gh reached through prefixes, wrappers, quoting, nesting"
# =============================================================================
block "env assignment prefix"      'GH_CONFIG_DIR=/x gh api repos/o/r/issues -X POST'
block "several assignments"        'A=1 B=2 gh api repos/o/r/issues -f t=x'
block "env wrapper"                'env FOO=1 gh api repos/o/r/issues -X POST'
block "env -i wrapper"             'env -i gh api repos/o/r/issues -X POST'
block "env -u wrapper"             'env -u FOO gh api repos/o/r/issues -X POST'
block "command wrapper"            'command gh api repos/o/r/issues -X POST'
block "command -- wrapper"         'command -- gh api repos/o/r/issues -X POST'
block "exec wrapper"               'exec gh api repos/o/r/issues -X POST'
block "time wrapper"               'time gh api repos/o/r/issues -X POST'
block "nohup wrapper"              'nohup gh api repos/o/r/issues -X POST'
block "nice wrapper"               'nice -n 5 gh api repos/o/r/issues -X POST'
block "timeout wrapper"            'timeout 30 gh api repos/o/r/issues -X POST'
block "timeout -s wrapper"         'timeout -s KILL 30 gh api repos/o/r/issues -X POST'
block "stacked wrappers"           'env A=1 nice -n 1 timeout 5 command gh api repos/o/r/issues -X POST'
block "absolute path"              '/usr/bin/gh api repos/o/r/issues -X POST'
block "relative path"              './bin/gh api repos/o/r/issues -X POST'
block "double-quoted gh"           '"gh" api repos/o/r/issues -X POST'
block "single-quoted gh"           "'gh' api repos/o/r/issues -X POST"
block "backslash inside gh"        'g\h api repos/o/r/issues -X POST'
block "quote inside gh"            'g"h" api repos/o/r/issues -X POST'
block "quoted api word"            'gh "api" repos/o/r/issues -X POST'
block "backslash inside api"       'gh ap\i repos/o/r/issues -X POST'
block "uppercase gh"               'GH api repos/o/r/issues -X POST'
block "gh.exe"                     'gh.exe api repos/o/r/issues -X POST'
block "gh -R before api"           'gh -R o/r api repos/o/r/issues -X POST'
block "gh --repo= before api"      'gh --repo=o/r api repos/o/r/issues -X POST'
block "after &&"                   'true && gh api repos/o/r/issues -X POST'
block "after ||"                   'false || gh api repos/o/r/issues -X POST'
block "after ;"                    'echo hi; gh api repos/o/r/issues -X POST'
block "after a pipe"               'echo hi | gh api repos/o/r/issues -X POST'
block "after newline"              $'echo hi\ngh api repos/o/r/issues -X POST'
block "subshell"                   '(gh api repos/o/r/issues -X POST)'
block "brace group"                '{ gh api repos/o/r/issues -X POST; }'
block "if body"                    'if true; then gh api repos/o/r/issues -X POST; fi'
block "while body"                 'while true; do gh api repos/o/r/issues -X POST; done'
block "negated"                    '! gh api repos/o/r/issues -X POST'
block "redirect before args"       'gh api repos/o/r/issues >/dev/null -X POST'
block "redirect on the command"    'gh api repos/o/r/issues -X POST 2>&1'
block "command substitution"       'x=$(gh api repos/o/r/issues -X POST)'
block "substitution as argument"   'echo $(gh api repos/o/r/issues -X POST)'
block "substitution in a string"   'echo "$(gh api repos/o/r/issues -f t=x)"'
block "backtick substitution"      'echo `gh api repos/o/r/issues -X POST`'
block "nested substitutions"       'echo $(echo $(gh api repos/o/r/issues -X POST))'
block "bash -c"                    "bash -c 'gh api repos/o/r/issues -X POST'"
block "bash -lc"                   "bash -lc 'gh api repos/o/r/issues -X POST'"
block "sh -c double-quoted"        'sh -c "gh api repos/o/r/issues -f t=x"'
block "zsh -c"                     "zsh -c 'gh api repos/o/r/issues -X POST'"
block "eval string"                "eval 'gh api repos/o/r/issues -X POST'"
block "eval words"                 'eval gh api repos/o/r/issues -X POST'
block "env bash -c"                "env X=1 bash -c 'gh api repos/o/r/issues -X POST'"
block "bash -c nested bash -c"     "bash -c \"bash -c 'gh api repos/o/r/issues -X POST'\""
block "source process substitution" 'source <(echo gh api repos/o/r/issues -X POST)'
block "echo piped into bash"       'echo "gh api repos/o/r/issues -X POST" | bash'
block "printf piped into sh"       "printf 'gh api repos/o/r/issues -f t=x' | sh"
block "echo piped into xargs"      'echo x | xargs gh api repos/o/r/issues -X POST'
block "heredoc piped into bash"    $'cat <<EOF | bash\ngh api repos/o/r/issues -X POST\nEOF'
block "python -c"                  "python3 -c 'import os; os.system(\"gh api repos/o/r/issues -X POST\")'"
block "find -exec"                 'find . -name x -exec gh api repos/o/r/issues -X POST ";"'
block "ssh remote command"         "ssh host 'gh api repos/o/r/issues -X POST'"
block "deep nesting past the cap"  'echo $(echo $(echo $(echo $(echo gh api x))))'

# =============================================================================
group "A5: gh launched by a program that forwards arguments (no api word in view)"
# =============================================================================
block "stdin-fed xargs"            $'printf \'api\\nrepos/o/r/issues\\n-f\\ntitle=x\\n\' | xargs gh'
block "echo-fed xargs"             'echo api repos/o/r/issues -f title=x | xargs gh'
block "xargs replacement string"   "printf 'x\\n' | xargs -I{} gh {} repos/o/r/issues -f title=x"
block "find -exec gh no api word"  "find . -maxdepth 0 -exec gh pr list ';'"
block "parallel-style program"     "printf 'x\\n' | parallel gh {}"
block "xargs with input redirect"  'xargs gh < list.txt'
block "xargs count-limited"        "printf 'pr\\nlist\\n' | xargs -L10 gh"
block "privilege wrapper off-list" 'sudo gh pr list'
block "command gh api write"       'command gh api repos/o/r/issues -X POST'
block "role config dir prefix write" 'GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" gh api repos/o/r/issues -X POST'
block "abs-path gh basename write" 'nice /usr/local/bin/gh api repos/o/r/issues -X POST'
block "lookup then gh api write"   'command -v gh; gh api repos/o/r/issues -X POST'
block "exec -v gh api write"       'exec -v gh api repos/o/r/issues -X POST'
block "then + xargs gh"          $'if true; then printf \'x\\n\' | xargs gh; fi'
block "then + xargs gh, one line"  'if true; then xargs gh < list.txt; fi'

allow "command -v gh"              'command -v gh'
allow "command -V gh"              'command -V gh'
allow "type gh"                    'type gh'
allow "which gh"                   'which gh'
allow "mkdir under gh dir"         'mkdir -p "$ATELIER_CONFIG_DIR/gh/author"'
allow "ls file under gh dir"       'ls "$ATELIER_CONFIG_DIR/gh/author/hosts.yml"'
allow "gh pr list"                 'gh pr list'
allow "absolute-path gh"           '/usr/local/bin/gh pr list'
allow "env GH_CONFIG_DIR prefix"   'env GH_CONFIG_DIR=/x gh pr view 1'
allow "reviewer role config dir"   'GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/reviewer" gh pr review 5 --approve --body-file x.md'
allow "author role config dir"     'GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" gh pr create --repo o/r --base main --head h --title t --body-file b.md'
allow "gh pr checks --watch"       'gh pr checks 5 --watch --interval 30 --fail-fast'
allow "bash -c gh pr list"         "bash -c 'gh pr list'"
allow "brace group gh pr list"     '{ gh pr list; }'
allow "echo naming gh"             'echo gh api repos/o/r/issues -f title=x'
allow "echo naming gh in bash -c"  "bash -c 'echo gh'"
allow "git commit message"         'git commit -m "fix gh thing"'
allow "rg pattern naming gh"       'rg gh hooks'
allow "cd then gh issue list"      'cd /x && gh issue list'

# =============================================================================
group "B1: fail-closed — unknown flag / wrapper / shape"
# =============================================================================
block "unknown long flag"          'gh api repos/o/r/issues --frobnicate'
block "unknown long flag with ="   'gh api repos/o/r/issues --frobnicate=1'
block "unknown short flag"         'gh api repos/o/r/issues -Z'
block "unknown flag in a cluster"  'gh api repos/o/r/issues -iZ'
block "switch given a value"       'gh api repos/o/r/issues --paginate=yes'
block "flag missing its value"     'gh api repos/o/r/issues --method'
block "-X missing its value"       'gh api repos/o/r/issues -X'
block "repeated endpoint"          'gh api repos/o/r/issues repos/o/r/pulls'
block "endpoint after --"          'gh api -- repos/o/r/issues -X POST'
block "unknown global flag"        'gh --hostname x api repos/o/r/issues'
block "sudo wrapper"               'sudo gh api repos/o/r/issues'
block "strace wrapper"             'strace gh api repos/o/r/issues'
block "xargs wrapper"              'xargs gh api repos/o/r/issues'
block "busybox wrapper"            'busybox gh api repos/o/r/issues'
block "watch wrapper"              'watch gh api repos/o/r/issues'
block "env -S wrapper"             "env -S 'gh api repos/o/r/issues'"
block "env unknown flag"           'env --bogus gh api repos/o/r/issues'
block "command -v odd flag"        'command -z gh api repos/o/r/issues'
block "nice unknown flag"          'nice --bogus gh api repos/o/r/issues'
block "timeout unknown flag"       'timeout --bogus 5 gh api repos/o/r/issues'
block "script runner"              'script -c "gh api repos/o/r/issues" /dev/null'

# =============================================================================
group "B2: fail-closed — expansion in a load-bearing word"
# =============================================================================
block "endpoint variable"          'gh api "$EP"'
block "endpoint bare variable"     'gh api $EP'
block "endpoint inside a string"   'gh api "repos/$R/issues"'
block "endpoint braced variable"   'gh api repos/${R}/issues'
block "endpoint substitution"      'gh api repos/$(echo o)/r/issues'
block "endpoint backtick"          'gh api repos/`echo o`/r/issues'
block "endpoint ANSI-C quote"      "gh api \$'repos/o/r/issues'"
block "endpoint brace expansion"   'gh api repos/o/r/{issues,pulls}'
block "command word variable"      '$GH api repos/o/r/issues'
block "command word braced"        '"${GH}" api repos/o/r/issues'
block "command word default"       '${GH:-gh} api repos/o/r/issues'
block "command word substitution"  '$(command -v gh) api repos/o/r/issues'
block "command word backtick"      '`command -v gh` api repos/o/r/issues'
block "command after assignment"   'A=1 $GH api repos/o/r/issues'
block "command after wrapper"      'env $GH api repos/o/r/issues'
block "command after env assignment" 'env A=1 $GH api repos/o/r/issues'
block "command after nice"         'nice -n 1 $GH api repos/o/r/issues'
block "command after timeout"      'timeout 5 $GH api repos/o/r/issues'
block "subcommand variable"        'gh $SUB repos/o/r/issues'
block "word before subcommand"     'gh $OPT api repos/o/r/issues'
block "method variable"            'gh api repos/o/r/issues -X "$M"'
block "method bare variable"       'gh api repos/o/r/issues -X $M'
block "method = variable"          'gh api repos/o/r/issues --method="$M"'
block "method brace expansion"     'gh api repos/o/r/issues -X {GET,POST}'
block "method substitution"        'gh api repos/o/r/issues -X "$(echo POST)"'
block "flag word variable"         'gh api repos/o/r/issues "-$F"'
block "flag word brace"            'gh api repos/o/r/issues --{method,x} POST'
block "extra positional variable"  'gh api repos/o/r/issues $X'
block "graphql query variable"     'gh api graphql -f query="$Q"'
block "graphql query bare var"     'gh api graphql -f query=$Q'
block "graphql query in a string"  'gh api graphql -f query="query { viewer { login } } $X"'
block "graphql query substitution" 'gh api graphql -f query="$(cat q.graphql)"'
block "graphql query backtick"     'gh api graphql -f query=`cat q.graphql`'
block "graphql query ANSI-C"       "gh api graphql -f query=\$'query{viewer{login}}'"
block "graphql key variable"       "gh api graphql -f \"\$K=query{viewer{login}}\""
block "interpreter body variable"  'bash -c "gh api repos/o/r/issues $FLAGS"'
block "interpreter body command"   'bash -c "$(printf "gh api repos/o/r/issues -X POST")"'
block "eval body variable"         'eval "gh api repos/o/r/issues $FLAGS"'
block "eval substitution"          'eval "$(echo gh api repos/o/r/issues -X POST)"'
block "header value variable"      'gh api repos/o/r/issues -H "Accept: $A"'
block "header variable"            'gh api repos/o/r/issues -H "$H"'

# =============================================================================
group "B3: fail-closed — bodies the hook cannot inspect"
# =============================================================================
block "graphql query from file"    'gh api graphql -F query=@q.graphql'
block "graphql query from file -f" 'gh api graphql -f query=@q.graphql'
block "graphql query from stdin"   'gh api graphql -F query=@-'
block "graphql --input file"       'gh api graphql --input q.json'
block "graphql --input stdin"      'cat q.json | gh api graphql --input -'
block "graphql with no query"      'gh api graphql'
block "graphql without query key"  'gh api graphql -f owner=x'
block "graphql other field only"   "gh api graphql -f other='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "graphql with a variable doc" 'gh api graphql -f query=$QUERY'
block "-c body that cannot relex"  'bash -c "gh api repos/o/r/issues $(cat flags)"'
block "text piped to interpreter"  'echo "gh api repos/o/r/issues" | zsh'
block "query over the size cap" \
  "gh api graphql -f query='query{viewer{login}}$(printf '%9000s' '')'"
block "command over the size cap" \
  "gh api repos/o/r/issues --jq '.$(head -c 41000 /dev/zero | tr '\0' a)'"

# =============================================================================
group "B4: fail-closed — headers outside Accept / X-GitHub-Api-Version"
# =============================================================================
block "method override header"     'gh api repos/o/r/issues -H "X-HTTP-Method-Override: DELETE"'
block "authorization header"       'gh api repos/o/r/issues -H "Authorization: Bearer x"'
block "content-type header"        'gh api repos/o/r/issues --header "Content-Type: application/json"'
block "--header= form"             'gh api repos/o/r/issues --header=X-Custom:1'
block "header without a colon"     'gh api repos/o/r/issues -H Accept'
block "header clustered value"     'gh api repos/o/r/issues -HX-Custom:1'
block "second header is foreign"   'gh api repos/o/r/issues -H "Accept: application/json" -H "X-Foo: 1"'
block "lookalike header name"      'gh api repos/o/r/issues -H "Accept-Charset: utf-8"'

# =============================================================================
group "B5: fail-closed — gh alias set / import"
# =============================================================================
block "alias set"                  "gh alias set w 'api -X POST'"
block "alias set --shell"          "gh alias set --shell w 'gh api -X POST repos/o/r/issues'"
block "alias import file"          'gh alias import aliases.yml'
block "alias import stdin"         'cat aliases.yml | gh alias import -'
block "alias set after wrapper"    "env X=1 gh alias set w 'api -X POST'"
block "alias set inside bash -c"   "bash -c \"gh alias set w 'api -X POST'\""
block "alias set after &&"         "true && gh alias set w 'api -X POST'"

# =============================================================================
group "C1: positive controls — recipes read from the shipped files"
# =============================================================================
# Reads the fenced block (or inline code span) that holds a recipe out of the
# shipped file, so the control tracks the file instead of a retyped copy.
extract_fence() { # file start-literal -> the fenced block that contains the first line with that literal
  awk -v pat="$2" '
    !on && index($0, pat) { on = 1 }
    on { print }
    on && $0 ~ /^[[:space:]]*```[[:space:]]*$/ { exit }
  ' "$1" | sed '$d'
}
fill_placeholders() {
  sed -e 's/<owner>/AkaLab-Tech/g' -e 's/<repo>/atelier/g' \
      -e 's/<issue-number>/12/g' -e 's/<sub-issue-number>/12/g'
}

q="$(extract_fence "$REPO_ROOT/skills/task-discovery/SKILL.md" "gh api graphql -f query='" | fill_placeholders)"
if [ -n "$q" ] && grep -q -- 'subIssues' <<<"$q"; then
  allow "task-discovery sub-issue GraphQL query (SKILL.md)" "$q"
else
  count_case; fail "could not extract the sub-issue query from skills/task-discovery/SKILL.md"
fi

q="$(extract_fence "$REPO_ROOT/commands/status.md" "gh api graphql -f query='" | fill_placeholders)"
if [ -n "$q" ] && grep -q -- 'parent' <<<"$q"; then
  allow "status parent GraphQL query (commands/status.md)" "$q"
else
  count_case; fail "could not extract the parent query from commands/status.md"
fi

q="$(sed -n 's/.*`\(GH_CONFIG_DIR=[^`]*gh api user[^`]*\)`.*/\1/p' "$REPO_ROOT/agents/reviewer.md" | head -1)"
if [ -n "$q" ]; then
  allow "reviewer identity read (agents/reviewer.md)" "$q"
else
  count_case; fail "could not extract the gh api user recipe from agents/reviewer.md"
fi

for ep in releases/latest tags; do
  q="$(grep -F -o "gh api repos/<repo>/$ep" "$REPO_ROOT/commands/doctor.md" | head -1 | sed 's#<repo>#AkaLab-Tech/atelier#')"
  if [ -n "$q" ]; then
    allow "doctor probe: $ep (commands/doctor.md)" "$q"
  else
    count_case; fail "could not extract the $ep probe from commands/doctor.md"
  fi
done

n_tpl=0
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  c="${entry#Bash(}"; c="${c%)}"; c="${c%\*}"; c="${c//\*/x}"
  n_tpl=$((n_tpl + 1))
  allow "template allow entry converted: $entry" "$c"
done < <(jq -r '(.permissions.allow // [])[] | select(startswith("Bash(") and contains("gh api"))' "$TEMPLATE")
if [ "$n_tpl" -lt 4 ]; then
  count_case; fail "expected at least 4 gh api allow entries in the template, found $n_tpl"
fi

# =============================================================================
group "D1: allowlisted board mutations allow (embedded minimal shapes)"
# =============================================================================
gql() { printf "gh api graphql -f query='%s' %s" "$1" "${2:--f p=PVT_x}"; }

allow "addProjectV2DraftIssue" \
  "$(gql 'mutation($p:ID!,$t:String!){addProjectV2DraftIssue(input:{projectId:$p,title:$t}){projectItem{id}}}' '-f p=PVT_x -f t=Title')"
allow "addProjectV2ItemById" \
  "$(gql 'mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id}}}' '-f p=PVT_x -f c=I_x')"
allow "updateProjectV2ItemFieldValue" \
  "$(gql 'mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' '-f p=P -f i=I -f f=F -f o=O')"
allow "clearProjectV2ItemFieldValue" \
  "$(gql 'mutation($p:ID!,$i:ID!,$f:ID!){clearProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f}){projectV2Item{id}}}' '-f p=P -f i=I -f f=F')"
allow "updateProjectV2DraftIssue" \
  "$(gql 'mutation($d:ID!,$b:String!){updateProjectV2DraftIssue(input:{draftIssueId:$d,body:$b}){draftIssue{id}}}' '-f d=D -f b=B')"
allow "updateIssue" \
  "$(gql 'mutation($i:ID!,$b:String!){updateIssue(input:{id:$i,body:$b}){issue{id}}}' '-f i=I -f b=B')"
allow "addComment" "$(gql "$MUT_OK" '-f i=I -f b=B')"
allow "raw-field query flag spelled --raw-field" \
  "gh api graphql --raw-field query='$MUT_OK' -f i=I -f b=B"
allow "-f query with typed non-query variables" \
  "gh api graphql -f query='$MUT_OK' -F i=I -F b=B"
allow "named operation" \
  "$(gql 'mutation SetStatus($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' '-f p=P -f i=I -f f=F -f o=O')"
allow "aliased field" \
  "$(gql 'mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){setStatus: updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' '-f p=P -f i=I -f f=F -f o=O')"
allow "two aliases of allowlisted fields" \
  "$(gql 'mutation($p:ID!,$a:ID!,$b:ID!,$f:ID!,$o:String!){one: updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$a,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}} two: updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$b,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}' '-f p=P -f a=A -f b=B -f f=F -f o=O')"
allow "alias named like a forbidden mutation" \
  "$(gql 'mutation{mergePullRequest: addComment(input:{subjectId:"x",body:"y"}){clientMutationId}}' '')"
allow "string argument holding braces and quotes" \
  "$(gql 'mutation{addProjectV2DraftIssue(input:{projectId:"P",title:"a } b \"mutation\" ( c"}){projectItem{id}}}' '')"
bq='mutation{addProjectV2DraftIssue(input:{projectId:"P",title:"t",body:"""line } one"""}){projectItem{id}}}'
allow "block-string argument" "$(gql "$bq" '')"
allow "directive on the field" \
  "$(gql 'mutation($s:Boolean!){addComment(input:{subjectId:"x",body:"y"}) @include(if:$s){clientMutationId}}' '-F s=true')"
allow "comment inside the document" \
  "$(gql $'# set the status\nmutation{addComment(input:{subjectId:"x",body:"y"}){clientMutationId}}' '')"
allow "word mutation inside a string of a query" \
  "$(gql 'query{search(query:"mutation",type:ISSUE,first:1){issueCount}}' '')"
allow "plain query" \
  "gh api graphql -f query='query{viewer{login}}'"
allow "shorthand query" \
  "gh api graphql -f query='{ viewer { login } }'"
allow "query with fragment" \
  "gh api graphql -f query='query{viewer{...F}} fragment F on User{login}'"
allow "endpoint /graphql" \
  "gh api /graphql -f query='query{viewer{login}}'"
allow "endpoint api.github.com/graphql" \
  "gh api https://api.github.com/graphql -f query='query{viewer{login}}'"
allow "query under the size cap" \
  "gh api graphql -f query='query{viewer{login}}$(printf '%7000s' '')'"

# =============================================================================
group "D2: non-allowlisted mutation beside an allowlisted one, multiple operations"
# =============================================================================
block "allowlisted then forbidden field" \
  "gh api graphql -f query='mutation{addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId} mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "forbidden then allowlisted field" \
  "gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId} addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}}'"
block "forbidden aliased between allowlisted" \
  "gh api graphql -f query='mutation{a: addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId} b: updateRef(input:{refId:\"x\"}){clientMutationId} c: updateIssue(input:{id:\"x\"}){issue{id}}}'"
block "two mutation operations" \
  "gh api graphql -f query='mutation A{addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}} mutation B{updateIssue(input:{id:\"x\",body:\"z\"}){issue{id}}}'"
block "allowlisted mutation, forbidden operation second" \
  "gh api graphql -f query='mutation A{addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}} mutation B{mergePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'"
block "query plus allowlisted mutation" \
  "gh api graphql -f query='query Q{viewer{login}} mutation M{addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}}'"
block "mutation plus subscription" \
  "gh api graphql -f query='mutation M{addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}} subscription S{a}'"
block "forbidden field in a second -f query" \
  "gh api graphql -f query='mutation{addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}}' -f query='mutation{deleteRef(input:{refId:\"x\"}){clientMutationId}}'"
block "forbidden field nested only in the selection is not enough" \
  "gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\"}){addComment{id}}}'"

# =============================================================================
group "D3: typed query field on the GraphQL endpoint (placeholder substitution)"
# =============================================================================
# gh substitutes {owner}/{repo}/{branch} and :owner/:repo inside typed -F/--field
# values, so a query sent typed can become a mutation the hook never saw.
RQ='query{viewer{login}}'
block "-F query holding a mutation (old allow case)" \
  "gh api graphql -F query='$MUT_OK' -f i=I -f b=B"
block "--field query holding a mutation (old allow case)" \
  "gh api graphql --field query='$MUT_OK' -f i=I -f b=B"
block "-F query, harmless read query" "gh api graphql -F query='$RQ'"
block "--field query, harmless read query" "gh api graphql --field query='$RQ'"
block "-Fquery= clustered, harmless read query" "gh api graphql -Fquery='$RQ'"
block "--field=query= joined, harmless read query" "gh api graphql --field=query='$RQ'"
block "-F query after other fields" "gh api graphql -f n=1 -F query='$RQ'"
block "-F query before the endpoint" "gh api -F query='$RQ' graphql"
block "-F query on /graphql endpoint" "gh api /graphql -F query='$RQ'"
block "-F query on api.github.com/graphql" "gh api https://api.github.com/graphql -F query='$RQ'"
block "-F query with brace {owner}" "gh api graphql -F query='query{repository(owner:\"x\",name:\"{owner}\"){id}}'"
block "-F query with brace {repo}" "gh api graphql -F query='query{repository(owner:\"x\",name:\"{repo}\"){id}}'"
block "-F query with brace {branch}" "gh api graphql -F query='query{repository(owner:\"x\",name:\"{branch}\"){id}}'"
block "-F query with colon :owner" "gh api graphql -F query='query{repository(owner:\"x\",name:\":owner\"){id}}'"
block "-F query with colon :repo" "gh api graphql -F query='query{repository(owner:\"x\",name:\":repo\"){id}}'"
block "--field query with brace {owner}" "gh api graphql --field query='query{repository(owner:\"x\",name:\"{owner}\"){id}}'"
block "--field query with colon :repo" "gh api graphql --field query='query{repository(owner:\"x\",name:\":repo\"){id}}'"
block "-Fquery with brace {branch}" "gh api graphql -Fquery='query{repository(owner:\"x\",name:\"{branch}\"){id}}'"
block "--field=query with colon :owner" "gh api graphql --field=query='query{repository(owner:\"x\",name:\":owner\"){id}}'"
block "-F query with placeholder, no mutation token, extra raw field" \
  "gh api graphql -f n=1 -F query='query{repository(owner:\"x\",name:\"{repo}\"){id}}'"
allow "-f query read plus -F n=1" "gh api graphql -f query='$RQ' -F n=1"
allow "-f query read plus -F owner=" "gh api graphql -f query='$RQ' -F owner=x"
allow "--raw-field query read" "gh api graphql --raw-field query='$RQ'"
allow "--raw-field query read plus --field n=1" "gh api graphql --raw-field query='$RQ' --field n=1"
allow "-fquery= clustered raw read" "gh api graphql -fquery='$RQ'"
allow "--raw-field=query= joined raw read" "gh api graphql --raw-field=query='$RQ'"
allow "-f query with placeholder text, raw" \
  "gh api graphql -f query='query{repository(owner:\"x\",name:\"{owner}\"){id}}'"
allow "raw-field board mutation with typed variables" \
  "gh api graphql -f query='mutation(\$p:ID!,\$i:ID!,\$f:ID!,\$o:String!){updateProjectV2ItemFieldValue(input:{projectId:\$p,itemId:\$i,fieldId:\$f,value:{singleSelectOptionId:\$o}}){projectV2Item{id}}}' -F p=P -F i=I -F f=F -F o=O"
allow "raw-field board mutation with typed owner variable" \
  "gh api graphql --raw-field query='$MUT_OK' -F owner=x -f i=I -f b=B"

# =============================================================================
group "E1: allow-listed helper invocations and unrelated commands"
# =============================================================================
allow "atelier-project-item set-status"  'atelier-project-item set-status 12 inProgress --from roadmap'
allow "atelier-project-item get"         'atelier-project-item get 12'
allow "atelier-project-cache"            'atelier-project-cache get 12 --no-refresh'
allow "atelier-task-backend"             'atelier-task-backend list roadmap'
allow "gh pr list"                       'gh pr list --state open'
allow "gh issue create"                  'gh issue create --title x --body y'
allow "gh pr merge"                      'gh pr merge 5 --squash'
allow "ls"                               'ls -la'
allow "git status"                       'git status --short'
allow "word api in prose, no gh"         'echo "the api returns a list"'
allow "gh in a path, no api"             'cat docs/gh-notes.md'

# =============================================================================
group "E2: inert text that merely names gh api"
# =============================================================================
allow "echo with a write shape"          'echo "gh api -X POST repos/o/r/issues"'
allow "echo unquoted"                    'echo gh api -X POST repos/o/r/issues'
allow "printf"                           "printf '%s\\n' 'gh api repos/o/r/issues -f t=x'"
allow "git commit -m"                    'git commit -m "docs: explain gh api -X POST handling"'
allow "git commit -m multi-line"         $'git commit -m "fix: x\n\nblocks gh api -f calls"'
allow "git commit -F - heredoc"          $'git commit -F - <<EOF\nfix: gh api -X POST note\nEOF'
allow "git log --grep"                   'git log --grep "gh api -X POST"'
allow "git -C commit"                    'git -C /tmp/x commit -m "gh api -X DELETE note"'
allow "heredoc prose into cat"           $'cat <<\'EOF\'\ngh api -X POST repos/o/r/issues\nEOF'
allow "heredoc prose into a file"        $'cat > notes.md <<EOF\nuse gh api -f title=x here\nEOF'
allow "heredoc prose into tee"           $'tee notes.md <<\'EOF\'\ngh api repos/o/r/issues -f t=x\nEOF'
allow "rg pattern"                       "rg 'gh api -X POST' hooks"
allow "rg -n pattern with flags"         'rg -n --no-heading "gh api .* -f " docs'
allow "grep pattern"                     'grep -n "gh api -X" PLAN.md'
allow "sed over a doc"                   "sed -n '1,5p' docs/gh-api-notes.md"
allow "jq with the words"                "jq -r '.a' <<< 'gh api -X POST'"
allow "echo piped to a file"             'echo "gh api -X POST x" > cmd.txt'
allow "echo piped to cat"                'echo "gh api -X POST x" | cat'
allow "echo piped to wc"                 'echo "gh api -X POST x" | wc -c'
block "rg with --pre runs a program"     "rg --pre 'gh api -X POST x' pat ."
block "git with -c runs a program"       "git -c core.pager='gh api -X POST x' log"

# =============================================================================
group "E3: plain reads"
# =============================================================================
allow "api user"                         'gh api user'
allow "api user --jq"                    'gh api user --jq .login'
allow "api user -q"                      'gh api user -q .login'
allow "explicit GET"                     'gh api repos/o/r/issues -X GET'
allow "explicit GET lower"               'gh api repos/o/r/issues --method=get'
allow "-XGET"                            'gh api repos/o/r/issues -XGET'
allow "--method GET twice"               'gh api repos/o/r/issues --method GET --method get'
allow "GET with fields"                  'gh api repos/o/r/issues -X GET -f state=open'
allow "GET with -F field"                'gh api repos/o/r/commits -X GET -F per_page=5'
allow "paginate + jq"                    'gh api --paginate repos/o/r/issues --jq ".[].number"'
allow "paginate slurp"                   'gh api --paginate --slurp repos/o/r/issues'
allow "include flag"                     'gh api -i repos/o/r/issues'
allow "--include flag"                   'gh api --include repos/o/r'
allow "cache flag"                       'gh api repos/o/r --cache 1h'
allow "template flag"                    "gh api repos/o/r/issues --template '{{.}}'"
allow "preview flag"                     'gh api repos/o/r --preview x'
allow "hostname flag"                    'gh api --hostname ghe.example.com repos/o/r'
allow "Accept header"                    'gh api repos/o/r/contents/x -H "Accept: application/vnd.github.raw"'
allow "Accept header lower-case name"    'gh api repos/o/r/contents/x -H "accept: application/vnd.github.raw"'
allow "Accept header clustered"          'gh api repos/o/r/contents/x -HAccept:application/json'
allow "Api-Version header"               'gh api repos/o/r -H "X-GitHub-Api-Version: 2022-11-28"'
allow "both neutral headers"             'gh api repos/o/r -H "Accept: application/json" --header "X-GitHub-Api-Version: 2022-11-28"'
allow "query string endpoint"            'gh api "repos/o/r/commits?per_page=5&sha=main"'
allow "endpoint with a leading slash"    'gh api /repos/o/r'
allow "wrapper + GET"                    'env X=1 gh api repos/o/r'
allow "assignment + GET"                 'GH_CONFIG_DIR=/x gh api repos/o/r'
allow "-R before api"                    'gh -R o/r api repos/o/r/issues'
allow "pipe into jq"                     'gh api repos/o/r/issues | jq length'
allow "result into a variable"           'n=$(gh api repos/o/r/issues --jq length)'
block "result in a conditional (compound construct, refused as unreadable)" 'if gh api user >/dev/null; then echo ok; fi'
allow "bash -c with a GET"               "bash -c 'gh api repos/o/r/issues'"
allow "stderr redirect"                  'gh api repos/o/r/issues 2>/dev/null'
allow "--help"                           'gh api --help'
allow "-h"                               'gh api -h'
allow "no endpoint"                      'gh api'
allow "gh alias list"                    'gh alias list'
allow "gh alias delete"                  'gh alias delete w'
allow "alias word in prose"              'echo gh alias set is blocked'
allow "-X GET before endpoint"           'gh api -X GET repos/o/r/issues'

# =============================================================================
group "J1: closed structure around a gh api call (block)"
# =============================================================================
block "help flag with a value, implicit POST"  'gh api --help=false repos/o/r/issues -f title=x'
block "help flag with a value, GraphQL mutation off the allowlist" 'gh api --help=false graphql -f query='\''mutation{mergePullRequest(input:{pullRequestId:"x"}){clientMutationId}}'\'
block "bare help then help with a value"       'gh api --help --help=false repos/o/r/issues -f title=x'
block "|& into an interpreter"                 'echo "gh api -X POST x" |& bash'
block "line-end pipe into an interpreter"      $'echo "gh api -X POST x" |\n bash'
block "pipe into an interpreter"               'echo "gh api -X POST x" | bash'
block "|& after gh"                            'gh api repos/o/r/issues |& jq .'
block "line-end pipe after gh"                 $'gh api repos/o/r/issues |\n jq .'
block "pipe at end of command"                 'gh api repos/o/r/issues | jq . |'
block "pipe into cat"                          'gh api repos/o/r/issues | cat'
block "pipe into tee"                          'gh api repos/o/r/issues | tee x'
block "filter chain ending in a shell"         'gh api repos/o/r/issues | jq . | bash'
block "& background"                           'gh api repos/o/r/issues &'
block "subshell"                               '(gh api repos/o/r/issues)'
block "brace group"                            '{ gh api repos/o/r/issues; }'
block "! negation"                             '! gh api user'
block "if with a bare condition"               'if gh api user; then echo ok; fi'
block "while loop"                             'while gh api user; do echo ok; done'
block "for loop"                               'for i in 1 2; do gh api user; done'
block "input redirect into gh"                 'gh api repos/o/r/issues < in.txt'
block "output redirect to a file"              'gh api repos/o/r/issues > out.json'
block "2>&1"                                   'gh api repos/o/r/issues 2>&1'
block "process substitution"                   'cat <(gh api repos/o/r/issues)'
block "pipe into gh"                           'echo hi | gh api repos/o/r/issues'
block "sort -o"                                'gh api repos/o/r/issues | sort -o out'
block "filter arg with an expansion"           'gh api repos/o/r/issues | jq "$(echo .)"'
block "base64 without a decode flag"           'gh api repos/o/r/contents/x --jq .content | base64'

# =============================================================================
group "J2: closed structure around a gh api call (allow)"
# =============================================================================
allow "bare --help"                            'gh api --help'
allow "bare -h"                                'gh api -h'
allow "pipe into jq ."                         'gh api repos/o/r/issues | jq .'
allow "jq | head | wc chain"                   'gh api repos/o/r/issues | jq -r '\''.[].title'\'' | head -5 | wc -l'
allow "base64 -d"                              'gh api repos/o/r/contents/x --jq .content | base64 -d'
allow "stderr to /dev/null with || true"       'gh api repos/o/r/issues --jq length 2>/dev/null || true'
allow "GH_CONFIG_DIR prefix with || true"      'GH_CONFIG_DIR=/x gh api user --jq .login 2>/dev/null || true'
allow "cd && gh api ; echo, newline sibling"   $'cd x && gh api user; echo done\ngh api user'
allow "capture with --jq"                      'n=$(gh api repos/o/r/issues --jq length)'

# =============================================================================
group "E4:payload edge cases and jq-missing fail-open"
# =============================================================================
count_case
payload="$(jq -cn '{tool_name:"Read", tool_input:{file_path:"x"}}')"
(cd "$TMP/work" && CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" PATH="$BIN:$PATH" bash "$HOOK" <<<"$payload" >/dev/null 2>&1)
rc=$?
if [ "$rc" = 0 ]; then pass "allow: non-Bash tool"; else fail "allow: non-Bash tool"; fi

count_case
(cd "$TMP/work" && CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" PATH="$BIN:$PATH" bash "$HOOK" <<<'' >/dev/null 2>&1)
rc=$?
if [ "$rc" = 0 ]; then pass "allow: empty stdin"; else fail "allow: empty stdin"; fi

count_case
(cd "$TMP/work" && CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" PATH="$BIN:$PATH" bash "$HOOK" <<<'not json {{{' >/dev/null 2>&1)
rc=$?
if [ "$rc" = 0 ]; then pass "allow: garbage stdin"; else fail "allow: garbage stdin"; fi

count_case
payload="$(jq -cn '{tool_name:"Bash", tool_input:{}}')"
(cd "$TMP/work" && CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" PATH="$BIN:$PATH" bash "$HOOK" <<<"$payload" >/dev/null 2>&1)
rc=$?
if [ "$rc" = 0 ]; then pass "allow: Bash payload without a command"; else fail "allow: Bash payload without a command"; fi

# jq missing: a PATH holding only the plain tools the hook sources need.
NOJQ="$TMP/nojq"
mkdir -p "$NOJQ"
for t in cat date mkdir dirname tr; do
  p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$NOJQ/$t"
done
count_case
payload='{"tool_name":"Bash","tool_input":{"command":"gh api repos/o/r/issues -X POST"}}'
(cd "$TMP/work" && CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" PATH="$NOJQ" "$REAL_BASH" "$HOOK" <<<"$payload" >/dev/null 2>"$TMP/stderr")
rc=$?
if [ "$rc" = 0 ] && grep -q 'jq missing' "$TMP/stderr"; then
  pass "jq missing: fails open with a warning (exit 0)"
else
  fail "jq missing: expected exit 0 and a warning (exit=$rc, stderr: $(head -c 200 "$TMP/stderr"))"
fi

# =============================================================================
group "G1: brace / glob shaped gh subcommand, gh word and -R value (block)"
# =============================================================================
block "braced subcommand {api,} REST write"   'gh {api,} -X POST repos/o/r/issues -f title=x'
block "braced subcommand {a,-}pi REST write"  'gh {a,-}pi -X POST repos/o/r/issues -f title=x'
block "braced subcommand {a,-}pi graphql"     'gh {a,-}pi graphql -f query='"'"'mutation{deleteIssue(input:{issueId:"x"}){clientMutationId}}'"'"
block "braced subcommand {alias,} set"        "gh {alias,} set x 'api -X POST repos/o/r/issues'"
block "braced subcommand {api,} plain read"   'gh {api,} repos/o/r/issues'
block "globbed subcommand ap?"                'gh ap? -X POST repos/o/r/issues -f title=x'
block "globbed subcommand a*"                 'gh a* -X POST repos/o/r/issues -f title=x'
block "globbed subcommand [a]pi"              'gh [a]pi -X POST repos/o/r/issues -f title=x'
block "globbed subcommand ap* graphql"        'gh ap* graphql -f query='"'"'mutation{deleteIssue(input:{issueId:"x"}){clientMutationId}}'"'"
block "globbed subcommand al?as set"          "gh al?as set x 'api -X POST repos/o/r/issues'"
block "globbed subcommand [a]lias set"        "gh [a]lias set x 'api -X POST repos/o/r/issues'"
block "braced -R value hiding the subcommand" 'gh -R {o/r,} {api,} -X POST repos/o/r/issues -f title=x'
block "braced -R value, plain api write"      'gh -R {o,p}/r api -X POST repos/o/r/issues -f title=x'
block "globbed -R value, plain api write"     'gh --repo o/* api -X POST repos/o/r/issues -f title=x'
block "globbed gh command word g?"            'g? api -X POST repos/o/r/issues -f title=x'
block "globbed gh command word g*"            'g* api -X POST repos/o/r/issues -f title=x'
block "globbed gh command word [g]h"          '[g]h api -X POST repos/o/r/issues -f title=x'
block "globbed gh command word after &&"      'true && g? api -X POST repos/o/r/issues -f title=x'
block "braced gh command word {gh,}"          '{gh,} api -X POST repos/o/r/issues -f title=x'
block "braced gh command word g{h,}"          'g{h,} api -X POST repos/o/r/issues -f title=x'
block "braced gh command word {g,}h"          '{g,}h api -X POST repos/o/r/issues -f title=x'
block "braced gh command word after ;"        'true; g{h,} api -X POST repos/o/r/issues -f title=x'

# =============================================================================
group "G2: brace groups, tests, globs and quoted metacharacters (no false refusals)"
# =============================================================================
allow "brace group { cmd; }"                  '{ echo hi; }'
allow "brace group { gh pr list; }"           '{ gh pr list; }'
allow "brace group with && and gh read"       'true && { gh pr list; echo done; }'
allow "brace group multi-line"                $'{\n  gh pr list\n  echo done\n}'
allow "test [ -f x ]"                         '[ -f x ]'
allow "test [ -f x ] && gh pr list"           '[ -f x ] && gh pr list'
allow "test [[ ... ]]"                        '[[ -f x && -d y ]]'
allow "if [[ ]] then gh pr list"              'if [[ -n x ]]; then gh pr list; fi'
allow "ls *.txt"                              'ls *.txt'
allow "ls with ? and [] globs"                'ls f?.txt [ab]*.log'
allow "echo with brace expansion"             'echo {a,b}.txt'
allow "gh issue view --jq object construct"  "gh issue view 1 --jq '.[] | {a:.b}'"
allow "gh pr list --search quoted"            'gh pr list --search "is:open"'
allow "gh pr list --search quoted glob"       "gh pr list --search 'is:open label:*bug*'"
allow "gh pr list --json fields"              'gh pr list --json number,title --jq '"'"'.[] | {n:.number}'"'"
allow "gh issue list --json + --jq brackets"  "gh issue list --json number --jq '.[].number'"
allow "gh api endpoint --jq '.[]'"            "gh api repos/o/r/issues --jq '.[]'"
allow "gh api endpoint --jq object"           "gh api repos/o/r/issues --jq '.[] | {n:.number}'"
allow "git log --format with braces"          "git log --format='%h {x}'"
allow "git log --format double-quoted braces" 'git log --format="%h {x} [y] *z?"'

# =============================================================================
group "F: lexer default-output invariance (origin/main vs working copy)"
# =============================================================================
OLD_LEX="$TMP/shell-lex.old.sh"
NEW_LEX="$REPO_ROOT/hooks/lib/shell-lex.sh"
if git -C "$REPO_ROOT" show origin/main:hooks/lib/shell-lex.sh >"$OLD_LEX" 2>/dev/null && [ -s "$OLD_LEX" ]; then
  CORPUS=(
    'echo hello'
    'gh api repos/o/r/issues -X POST'
    'a;b&&c||d|e'
    $'one\ntwo\nthree'
    'echo "double $HOME quoted" '"'"'single $HOME'"'"
    'echo $(date +%s) `uname` ${HOME} $((1+2))'
    'echo "$(echo "nested $(echo deep)")"'
    'x=$(cmd)/y gh api z'
    'echo $'"'"'ansi\tc'"'"' tail'
    'echo a\ b "c\"d" '"'"'e'"'"'\'"'"''
    'cmd # trailing comment ; not a segment'
    'cmd > out 2>&1 < in <<< here'
    '(subshell; again) && { group; }'
    'cat <<EOF'$'\n''body $HOME'$'\n''EOF'
    'if x; then y; elif z; then w; else v; fi'
    'echo "unterminated'
    'echo $(unterminated'
    'echo `unterminated'
    '   leading   and   trailing   '
    ''
    ';;;'
    'echo "" '"''"' empty'
    'printf %s "multi'$'\n''line string"'
    'env A=1 B="two words" cmd --flag=value arg'
    'echo "é ü ñ 日本語"'
    'echo '"$(printf '%600s' '' | tr ' ' a)"' tail'
    'echo "'"$(printf '%900s' '' | tr ' ' b)"'" $HOME '"$(printf '%450s' '' | tr ' ' c)"
    'gh api graphql -f query='"'"'query($o:String!){repository(owner:$o){id}}'"'"' -f o=x'
    'a | b | c; d & e'
    'echo \$HOME \`x\` \\'
    'echo "\$HOME \` \\ \""'
  )
  DRIVER="$TMP/lex-driver.sh"
  cat >"$DRIVER" <<'DRV'
#!/usr/bin/env bash
# usage: lex-driver.sh <lib> <mark|-> <corpus-file>; prints LEX_OUT and LEX_CONN per item (and LEX_EXP when a 4th arg is "exp")
source "$1"
[ "$2" = - ] || LEX_MARK="$2"
while IFS= read -r -d $'\x1d' item; do
  lex "$item"
  printf 'OUT=%q\nCONN=%q\n' "$LEX_OUT" "$LEX_CONN"
  if [ "${4:-}" = exp ]; then printf 'EXP=%q\n' "${LEX_EXP:-}"; fi
done <"$3"
DRV
  : >"$TMP/corpus"
  for item in "${CORPUS[@]}"; do printf '%s\x1d' "$item" >>"$TMP/corpus"; done

  bash "$DRIVER" "$OLD_LEX" - "$TMP/corpus" >"$TMP/lex.old" 2>&1
  bash "$DRIVER" "$NEW_LEX" - "$TMP/corpus" >"$TMP/lex.new.unset" 2>&1
  bash "$DRIVER" "$NEW_LEX" 1 "$TMP/corpus" >"$TMP/lex.new.mark" 2>&1
  bash "$DRIVER" "$OLD_LEX" 1 "$TMP/corpus" >"$TMP/lex.old.mark" 2>&1

  count_case
  if [ -s "$TMP/lex.old" ] && cmp -s "$TMP/lex.old" "$TMP/lex.new.unset"; then
    pass "LEX_OUT / LEX_CONN byte-identical to origin/main, LEX_MARK unset (${#CORPUS[@]} samples)"
  else
    fail "LEX_OUT / LEX_CONN differ from origin/main with LEX_MARK unset"
  fi
  count_case
  if cmp -s "$TMP/lex.old" "$TMP/lex.new.mark"; then
    pass "LEX_OUT / LEX_CONN byte-identical to origin/main, LEX_MARK=1 (${#CORPUS[@]} samples)"
  else
    fail "LEX_OUT / LEX_CONN differ from origin/main with LEX_MARK=1"
  fi
  count_case
  if cmp -s "$TMP/lex.old" "$TMP/lex.old.mark"; then
    pass "origin/main lexer ignores LEX_MARK (driver sanity)"
  else
    fail "origin/main lexer output changed with LEX_MARK=1 (driver is not a valid control)"
  fi

  # LEX_EXP: all zeros by default; marks expansions outside single quotes when opted in.
  exp_default="$(bash "$DRIVER" "$NEW_LEX" - "$TMP/corpus" exp 2>&1 | grep '^EXP=')"
  count_case
  if [ -n "$exp_default" ] && ! grep -q -- '1' <<<"$exp_default"; then
    pass "LEX_EXP holds no 1 flag when LEX_MARK is unset"
  else
    fail "LEX_EXP carries a 1 flag with LEX_MARK unset"
  fi

  check_flags() { # description command expected
    local got
    count_case
    got="$(flags "$2")"
    if [ "$got" = "$3" ]; then pass "LEX_MARK=1: $1"; else fail "LEX_MARK=1: $1 (flags=$got, want $3)"; fi
  }
  flags() { # LEX_MARK=1 flags for a command: one 0/1 per token, segments joined by /
    bash -c 'source "$1"; LEX_MARK=1; lex "$2"; printf "%s" "$LEX_EXP" | tr "\036" "/"' _ "$NEW_LEX" "$1"
  }
  check_flags "\$X is flagged" 'echo $X' "01/"
  check_flags "single-quoted \$X is not flagged" "echo '\$X'" "00/"
  check_flags "\$X inside double quotes is flagged" 'echo "a $X b"' "01/"
  check_flags "\$(...) is flagged" 'echo $(date)' "01/"
  check_flags "backticks are flagged" 'echo `date`' "01/"
  check_flags "flags reset per segment" 'a $X; b c' "01/00/"

  # LEX_NEST=1 (opt-in on top of LEX_MARK=1): a substitution with nested quoted
  # arguments stays one token and one segment (no split at the inner space or pipe).
  check_nest() { # description command expected
    local got
    count_case
    got="$(bash -c 'source "$1"; LEX_MARK=1; LEX_NEST=1; lex "$2"; printf "%s" "$LEX_EXP" | tr "\036" "/"' _ "$NEW_LEX" "$2")"
    if [ "$got" = "$3" ]; then pass "LEX_NEST=1: $1"; else fail "LEX_NEST=1: $1 (flags=$got, want $3)"; fi
  }
  check_nest "nested quoted arg with a space stays one token" 'echo "$(gh api x -X POST | jq ".a b")"' "01/"
  check_nest "backtick body with a nested quoted arg stays one token" 'echo "`gh api x -X POST | jq ".a b"`"' "01/"
  check_nest "doubly nested substitution stays one token" 'echo "$(echo "$(gh api x -X POST)")"' "01/"
  check_nest "braced expansion with a nested quote stays one token" 'echo "${x:-"a b"}"' "01/"
  check_nest "arithmetic expansion stays one token" 'echo "$((1+2))" tail' "010/"
  check_nest "ANSI-C string with an escaped quote stays one token" $'echo $\'a\\\'b c\' tail' "010/"
else
  count_case
  pass "SKIP: origin/main:hooks/lib/shell-lex.sh not available in this checkout"
fi

# =============================================================================
group "H1: GraphQL endpoint, unreadable fields and tokenizer edges (block)"
# =============================================================================
HQ='query{viewer{login}}'
BAD='mutation{mergePullRequest(input:{pullRequestId:"x"}){clientMutationId}}'
CR=$'\r'
BOM=$'\xef\xbb\xbf'
block "expansion key beside a harmless query" \
  "gh api graphql -f query='$HQ' -f \$K=v"
block "command-substitution key beside a harmless query" \
  "gh api graphql -f query='$HQ' -f \$(echo query)=v"
block "brace-group key beside a harmless query" \
  "gh api graphql -f query='$HQ' -f {query,x}=v"
block "glob key beside a harmless query" \
  "gh api graphql -f query='$HQ' -f qu?ry=v"
block "bracket key beside a harmless query" \
  "gh api graphql -f query='$HQ' -f quer[y]=v"
block "field word with no equals sign" \
  "gh api graphql -f query='$HQ' -f novalue"
block "key outside the allowed characters" \
  "gh api graphql -f query='$HQ' -f 'a b=v'"
block "unquoted brace group in the query value" \
  "gh api graphql -f query={$HQ,$BAD}"
block "unquoted brace group in the query value (-F)" \
  "gh api graphql -F query={query{a},query{b}}"
block "two plain query fields" \
  "gh api graphql -f query='$HQ' -f query='$HQ'"
block "two query fields, -f and -F" \
  "gh api graphql -f query='$HQ' -F query='$HQ'"
block "harmless query plus a field with an expansion value" \
  "gh api graphql -f query='$HQ' -f owner=\$OWNER"
block "harmless query plus a field with a substitution value" \
  "gh api graphql -f query='$HQ' -f owner=\$(whoami)"
block "mutation hidden behind a raw CR in a comment" \
  "gh api graphql -f query='query{a} # note${CR}${BAD}'"
block "mutation hidden behind a raw CR in a leading comment" \
  "gh api graphql -f query='# note${CR}${BAD}'"
# The tokenizer runs on any document holding the word `mutation`; each case
# below is an otherwise allowlisted mutation, so only the edge under test blocks.
AM='mutation{addComment(input:{subjectId:"x",body:"y"}){clientMutationId}}'
block "vertical tab in a mutation" \
  "gh api graphql -f query='mutation$(printf '\v'){addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}}'"
block "form feed in a mutation" \
  "gh api graphql -f query='mutation$(printf '\f'){addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}}'"
block "form feed in a comment before a mutation" \
  "gh api graphql -f query='# c$(printf '\f')
$AM'"
block "control character inside a string" \
  "gh api graphql -f query='mutation{addComment(input:{subjectId:\"x\",body:\"a$(printf '\001')b\"}){clientMutationId}}'"
block "other control character between tokens" \
  "gh api graphql -f query='mutation{$(printf '\002')addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}}'"
block "raw newline inside a regular string" \
  "gh api graphql -f query='mutation{addComment(input:{subjectId:\"x\",body:\"a
b\"}){clientMutationId}}'"
block "raw CR inside a regular string" \
  "gh api graphql -f query='mutation{addComment(input:{subjectId:\"x\",body:\"a${CR}b\"}){clientMutationId}}'"
block "BOM in the middle of the document" \
  "gh api graphql -f query='query{a}${BOM}${BAD}'"
block "BOM after a leading BOM" \
  "gh api graphql -f query='${BOM}${BOM}$AM'"
block "BOM in the middle of a mutation" \
  "gh api graphql -f query='mutation{${BOM}addComment(input:{subjectId:\"x\",body:\"y\"}){clientMutationId}}'"

# =============================================================================
group "H2: GraphQL endpoint, readable shapes that must still allow"
# =============================================================================
allow "quoted braces in a query" \
  "gh api graphql -f query='{ a(x:1, y:2) }'"
allow "leading BOM" \
  "gh api graphql -f query='${BOM}query{viewer{login}}'"
allow "leading BOM before an allowlisted mutation" \
  "gh api graphql -f query='${BOM}$AM'"
allow "CRLF line endings in an allowlisted mutation" \
  "gh api graphql -f query='mutation{${CR}
addComment(input:{subjectId:\"x\",body:\"y\"}){${CR}
clientMutationId${CR}
}${CR}
}'"
allow "CRLF line endings, no comments" \
  "gh api graphql -f query='query{${CR}
viewer{${CR}
login${CR}
}${CR}
}'"
allow "literal -f owner and -F number beside a read query" \
  "gh api graphql -f query='query(\$owner:String!,\$number:Int!){repository(owner:\$owner,name:\"r\"){issue(number:\$number){title}}}' -f owner=a -F number=3"
allow "comment ended by a newline, query after it" \
  "gh api graphql -f query='# note
query{viewer{login}}'"
allow "CRLF after a comment on its own line" \
  "gh api graphql -f query='# note${CR}
query{viewer{login}}'"
allow "allowlisted board mutation with literal fields" \
  "gh api graphql -f query='$MUT_OK' -f i=I -F b=B"
allow "block string holding # and newlines" \
  "gh api graphql -f query='mutation{addProjectV2DraftIssue(input:{projectId:\"P\",title:\"t\",body:\"\"\"line # one
two # }
\"\"\"}){projectItem{id}}}'"
allow "block string with # in a read query" \
  "gh api graphql -f query='query{search(query:\"\"\"a # b
c\"\"\",type:ISSUE,first:1){issueCount}}'"
allow "# inside a regular string" \
  "gh api graphql -f query='query{search(query:\"a # b\",type:ISSUE,first:1){issueCount}}'"

# =============================================================================
group "I1: nested quotes inside substitutions (block)"
# =============================================================================
block "implicit POST, nested quoted jq arg with a space after the write flag" \
  'echo "$(gh api repos/o/r/issues --jq ".[] | .a" -X POST)"'
block "implicit POST, nested quoted arg with a space before the write flags" \
  'x="$(gh api repos/o/r/issues -X POST -f a=b | jq ".a b")"'
block "explicit method, backtick capture with a nested quoted arg" \
  'x="`gh api repos/o/r/issues -X POST -f a=b | jq ".a b"`"'
block "DELETE after a nested quoted arg with a space" \
  'echo "$(echo "a b" | gh api repos/o/r/issues -X DELETE)"'
block "here-string with a substitution holding a spaced field value" \
  'cat <<< "$(gh api repos/o/r/issues -X POST -f a="b c")"'
block "doubly nested substitution with a spaced jq arg" \
  'echo "$(echo "$(gh api repos/o/r/issues -X POST | jq ".a b")")"'
block "GraphQL mutation outside the allowlist in a nested substitution" \
  "echo \"\$(echo \"a b\" | gh api graphql -f query='$BAD')\""
block "GraphQL mutation outside the allowlist in a backtick capture" \
  "x=\"\`echo \"a b\" | gh api graphql -f query='$BAD'\`\""
block "unquoted braced default with a nested substitution" \
  'echo ${x:-"$(gh api repos/o/r/issues -X POST)"}'
block "quoted braced default holding a substitution" \
  'echo "${x:-$(gh api repos/o/r/issues -X POST)}"'
block "dollar-double-quote string holding a substitution" \
  'echo $"$(gh api repos/o/r/issues -X POST)"'
block "bash -c with escaped nested quotes" \
  'bash -c "echo \"a b\"; gh api repos/o/r/issues -X POST"'
block "process substitution" \
  'cat <(gh api repos/o/r/issues -X POST)'
block "write after a quoted braced default with nested quotes" \
  'echo "${x:-"a b"}" ; gh api repos/o/r/issues -X POST'
block "write after an ANSI-C string that is a lone escaped quote" \
  $'echo $\'\\\'\' ; gh api repos/o/r/issues -X POST'
block "write after an ANSI-C string with an escaped quote inside" \
  $'echo $\'a\\\'b\' ; gh api repos/o/r/issues -X POST'
block "write after an arithmetic expansion" \
  'echo "$((1+2))" ; gh api repos/o/r/issues -X POST'
block "PATCH in a substitution after an ANSI-C string with a space" \
  $'echo $\'a b\' "$(gh api repos/o/r/issues -X PATCH)"'
block "unclosed substitution naming gh" \
  'echo "$(gh api repos/o/r/issues -X POST'
block "unclosed backtick naming gh" \
  'echo "`gh api repos/o/r/issues -X POST'
block "odd backtick count naming gh" \
  'echo `date` `gh api repos/o/r/issues -X POST'

# =============================================================================
group "I2: nested quotes inside substitutions (allow)"
# =============================================================================
allow "GET, spaced jq filter inside echo and a substitution" \
  'echo "$(gh api repos/o/r/issues --jq ".[] | .a b")"'
allow "capture with select(...) and a spaced jq -r filter" \
  'x="$(gh api repos/o/r/issues --jq ".[] | select(.a)" | jq -r ".b c")"'
allow "backtick GET capture" \
  'x=`gh api repos/o/r/issues --jq '"'"'.[]'"'"'`'
allow "gh pr create with a substitution inside the title" \
  'gh pr create --title "a $(date +%s) b" --body "x"'
allow "gh pr list with --jq inside a substitution" \
  'echo "$(gh pr list --json number --jq ".[] | .number")"'
allow "arithmetic expansion in double quotes" \
  'echo "$((1+2))"'

# =============================================================================
echo
echo "Case counts per group:"
total=0
for ((i = 0; i < ${#CAT_NAMES[@]}; i++)); do
  printf '  %3d  %s\n' "${CAT_N[i]}" "${CAT_NAMES[i]}"
  total=$((total + CAT_N[i]))
done
printf '  %3d  total\n' "$total"

echo
if [ "$fails" -eq 0 ]; then
  echo "#812 block-gh-api-write: all assertions passed."
  exit 0
else
  echo "#812 block-gh-api-write: $fails assertion(s) failed."
  exit 1
fi
