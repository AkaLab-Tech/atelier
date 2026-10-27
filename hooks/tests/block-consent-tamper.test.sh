#!/usr/bin/env bash
#
# Regression test for #638/#639/#651 — hooks/block-consent-tamper.sh blocks tool calls that
# address the consent state as a PATH (file-tool path fields, Bash path arguments and
# redirections, incl. symlinks and substitutions), allows free-text mentions (content,
# messages, bodies, heredocs, search patterns) and other tools, and logs every block
# to hook-decisions.jsonl.
#
# Hermetic: temp ATELIER_CONFIG_DIR / CLAUDE_PROJECT_DIR. Requires jq.
#
# Run:  hooks/tests/block-consent-tamper.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2016,SC2088
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-consent-tamper.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export ATELIER_CONFIG_DIR="$TMP/custom-cfg" CLAUDE_PROJECT_DIR="$TMP/wt"
mkdir -p "$ATELIER_CONFIG_DIR" "$CLAUDE_PROJECT_DIR"
DLOG="$CLAUDE_PROJECT_DIR/.task-log/hook-decisions.jsonl"
RESOLVED="$ATELIER_CONFIG_DIR/state/consent"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

run_hook() { # tool input_json -> rc
  jq -cn --arg t "$1" --argjson i "$2" '{tool_name:$t, tool_input:$i}' \
    | CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash "$HOOK" >/dev/null 2>"$TMP/stderr"
  echo "$?"
}
nlines() { if [ -f "$DLOG" ]; then wc -l < "$DLOG"; else echo 0; fi; }
blocks() { # name tool input_json
  local before after rc
  before="$(nlines)"
  rc="$(run_hook "$2" "$3")"
  after="$(nlines)"
  if [ "$rc" = 2 ] && grep -q 'atelier:block-consent-tamper BLOCKED' "$TMP/stderr" && [ "$after" -gt "$before" ] \
     && tail -1 "$DLOG" | jq -e --arg t "$2" '.hook=="block-consent-tamper" and .action=="block" and .tool==$t' >/dev/null; then
    pass "block+log: $1"
  else
    fail "block+log: $1 (exit=$rc, log lines $before->$after)"
  fi
}
allows() {
  local rc; rc="$(run_hook "$2" "$3")"
  if [ "$rc" = 0 ]; then pass "allow: $1"; else fail "allow: $1 (exit=$rc)"; fi
}

bash_in() { jq -cn --arg c "$1" '{command:$c}'; }
C='~/.claude-work/state/consent'

echo "== blocked: file tools, path fields only =="
blocks "Edit literal" Edit '{"file_path":"/x/state/consent/ledger.jsonl","old_string":"a","new_string":"b"}'
blocks "Write literal" Write '{"file_path":"/x/state/consent/grants/f.json","content":"{}"}'
blocks "MultiEdit literal" MultiEdit '{"file_path":"/x/state/consent/ledger.jsonl","edits":[{"old_string":"a","new_string":"b"}]}'
blocks "NotebookEdit literal" NotebookEdit '{"notebook_path":"/x/state/consent/n.ipynb","new_source":"x"}'
blocks "Read literal" Read '{"file_path":"/x/state/consent/ledger.jsonl"}'
blocks "Read path field" Read '{"path":"/x/state/consent"}'
blocks "Write uppercase" Write '{"file_path":"/x/STATE/Consent/f","content":"x"}'
blocks "Write // variant" Write '{"file_path":"/x//state//consent/f","content":"x"}'
blocks "Write /./ variant" Write '{"file_path":"/x/state/./consent/f","content":"x"}'
blocks "Write tilde" Write '{"file_path":"~/.claude-work/state/consent/f","content":"x"}'
blocks "Write resolved" Write "$(jq -cn --arg p "$RESOLVED/grants/f.json" '{file_path:$p,content:"{}"}')"
blocks "Read resolved" Read "$(jq -cn --arg p "$RESOLVED/ledger.jsonl" '{file_path:$p}')"
mkdir -p "$RESOLVED" "$TMP/inno"
ln -s "$RESOLVED" "$TMP/inno/link"
blocks "Write via symlink into root" Write "$(jq -cn --arg p "$TMP/inno/link/new.json" '{file_path:$p,content:"{}"}')"

echo "== allowed: content is not a path =="
allows "Write content mentions path" Write '{"file_path":"/x/notes.md","content":"see state/consent/ledger.jsonl"}'
allows "Edit new_string mentions path" Edit '{"file_path":"/x/a.md","old_string":"a","new_string":"cp x state/consent/grants/y"}'
allows "MultiEdit edits[] mentions path" MultiEdit '{"file_path":"/ok.txt","edits":[{"old_string":"a","new_string":"cp x state/consent/grants/y"}]}'
allows "NotebookEdit new_source mentions path" NotebookEdit '{"notebook_path":"/x/n.ipynb","new_source":"state/consent"}'
allows "Edit unrelated" Edit '{"file_path":"/x/src/a.ts","old_string":"a","new_string":"b"}'
allows "Read unrelated" Read '{"file_path":"/x/README.md"}'
allows "non-covered tool (Grep)" Grep '{"pattern":"state/consent"}'
allows "non-covered tool (WebFetch)" WebFetch '{"url":"https://example.com/state/consent"}'
allows "non-covered tool (Glob)" Glob '{"pattern":"*.json","path":"/x/notes"}'
allows "MultiEdit multiple edits mention path" MultiEdit '{"file_path":"/ok.txt","edits":[{"old_string":"state/consent","new_string":"a"},{"old_string":"b","new_string":"rm state/consent/x"}]}'
allows "empty tool_input" Bash '{}'

echo "== blocked: Bash path arguments and redirections =="
blocks "cat" Bash "$(bash_in "cat $C/pending/x.json")"
blocks "ls relative" Bash "$(bash_in "ls state/consent")"
blocks "ls uppercase" Bash "$(bash_in "ls STATE/Consent")"
blocks "rm" Bash "$(bash_in "rm -rf $C")"
blocks "mv" Bash "$(bash_in "mv $C/ledger.jsonl /tmp/x")"
blocks "cp" Bash "$(bash_in "cp /tmp/x $C/grants/y")"
blocks "tee" Bash "$(bash_in "echo x | tee $C/ledger.jsonl")"
blocks "ln" Bash "$(bash_in "ln -s /tmp/x $C/grants/y")"
blocks "sed -i" Bash "$(bash_in "sed -i s/a/b/ $C/ledger.jsonl")"
blocks "jq" Bash "$(bash_in "jq . $C/ledger.jsonl")"
blocks "redirect >" Bash "$(bash_in "echo '{}' > $C/grants/x")"
blocks "redirect attached" Bash "$(bash_in "echo '{}' >$C/grants/x")"
blocks "redirect >>" Bash "$(bash_in "echo x >> $C/ledger.jsonl")"
blocks "redirect 2>" Bash "$(bash_in "ls 2> $C/err")"
blocks "redirect <" Bash "$(bash_in "cat < $C/ledger.jsonl")"
blocks "grep on consent file" Bash "$(bash_in "grep x $C/ledger.jsonl")"
blocks "grep -f consent file" Bash "$(bash_in "grep -f $C/ledger.jsonl hooks/x")"
blocks "git add" Bash "$(bash_in "git add $C/x")"
blocks "git commit -F" Bash "$(bash_in "git commit -F $C/x")"
blocks "gh --body-file" Bash "$(bash_in "gh pr create --body-file $C/x")"
blocks "gh api --input" Bash "$(bash_in "gh api x --input $C/x")"
blocks "gh api -F key=@file" Bash "$(bash_in "gh api repos/o/r/issues -F body=@state/consent/ledger.jsonl")"
blocks "gh api -F attached" Bash "$(bash_in "gh api repos/o/r/issues -Fbody=@$C/ledger.jsonl")"
blocks "gh api --field key=@file" Bash "$(bash_in "gh api x --field body=@$C/ledger.jsonl")"
blocks "gh api --field=key=@file" Bash "$(bash_in "gh api x --field=body=@$RESOLVED/ledger.jsonl")"
blocks "gh api graphql query=@" Bash "$(bash_in "gh api graphql -F query=@\$HOME/.claude-work/state/consent/ledger.jsonl")"
blocks "gh --input=" Bash "$(bash_in "gh api x --input=$C/x")"
blocks "gh issue create -F body file" Bash "$(bash_in "gh issue create --title x -F $C/p.json")"
blocks "gh pr comment -F var path" Bash "$(bash_in "gh pr comment 1 -F \$ATELIER_CONFIG_DIR/state/consent/ledger.jsonl")"
blocks "gh release create -F" Bash "$(bash_in "gh release create v1 -F $C/p")"
blocks "gh release create --notes-file" Bash "$(bash_in "gh release create v1 --notes-file $C/p")"
blocks "gh release create --notes-file=" Bash "$(bash_in "gh release create v1 --notes-file=$C/p")"
blocks "gh pr review -F attached" Bash "$(bash_in "gh pr review 1 -F$C/p")"
blocks "gh gist create operand" Bash "$(bash_in "gh gist create $C/ledger.jsonl")"
blocks "gh release upload operand" Bash "$(bash_in "gh release upload v1 $C/ledger.jsonl#label")"
blocks "gh issue create --template path" Bash "$(bash_in "gh issue create -T $C/p")"
blocks "grep -r -f pats consent dir" Bash "$(bash_in "grep -r -f p.txt $C")"
blocks "grep -r --file= consent dir" Bash "$(bash_in "grep -r --file=p.txt \$ATELIER_CONFIG_DIR/state/consent")"
blocks "grep -rf pats consent dir" Bash "$(bash_in "grep -rf p.txt $C")"
blocks "grep -fp.txt consent dir" Bash "$(bash_in "grep -fp.txt $C")"
blocks "grep -e pat -f pats consent dir" Bash "$(bash_in "grep -e x -f p.txt $C")"
blocks "rg --ignore-file consent" Bash "$(bash_in "rg --ignore-file $C/x pat .")"
blocks "rg --pre consent" Bash "$(bash_in "rg --pre $C/x pat .")"
blocks "grep --exclude-from consent" Bash "$(bash_in "grep --exclude-from $C/x pat .")"
blocks "git diff --output consent" Bash "$(bash_in "git diff --output $C/x")"
blocks "git diff --output= consent" Bash "$(bash_in "git diff --output=$C/x")"
blocks "git format-patch -o consent" Bash "$(bash_in "git format-patch -o $C HEAD~1")"
blocks "git apply consent" Bash "$(bash_in "git apply $C/x.patch")"
blocks "git am consent" Bash "$(bash_in "git am $C/x.mbox")"
blocks "git bundle create consent" Bash "$(bash_in "git bundle create $C/b.bundle HEAD")"
blocks "git --work-tree=" Bash "$(bash_in "git --work-tree=state/consent checkout -- .")"
blocks "git --work-tree sep" Bash "$(bash_in "git --work-tree state/consent clean -fdx")"
blocks "git --git-dir=" Bash "$(bash_in "git --git-dir=$C/.git status")"
blocks "git --git-dir sep" Bash "$(bash_in "git --git-dir $C/.git log")"
blocks "git --namespace sep" Bash "$(bash_in "git --namespace $C status")"
blocks "git -c value path" Bash "$(bash_in "git -c core.worktree=$C checkout -- .")"
blocks "bash -c" Bash "$(bash_in "bash -c \"rm $C/ledger.jsonl\"")"
blocks "python -c" Bash "$(bash_in "python3 -c \"open('state/consent/x','w')\"")"
blocks "resolved absolute" Bash "$(bash_in "cat $RESOLVED/ledger.jsonl")"
blocks "env wrapper + assignment" Bash "$(bash_in "FOO=1 env X=2 cat $C/x")"
blocks "\$HOME form" Bash "$(bash_in 'cat $HOME/.claude-work/state/consent/x')"
blocks "ATELIER_CONFIG_DIR form" Bash "$(bash_in 'cat ${ATELIER_CONFIG_DIR}/state/consent/x')"
blocks "quote-split literal" Bash "$(bash_in "cat state/cons''ent/x")"
blocks "second segment" Bash "$(bash_in "echo hi; rm $C/x")"
blocks "subst in git commit -m" Bash "$(bash_in "git commit -m \"\$(cat $C/x)\"")"
blocks "subst in echo" Bash "$(bash_in "echo \"\$(cat $C/x)\"")"
blocks "backtick in gh body" Bash "$(bash_in "gh pr create --body \"\`cat $C/x\`\"")"
blocks "nested subst" Bash "$(bash_in "echo \$(echo \$(cat $C/x))")"
blocks "heredoc into shell" Bash "$(bash_in "bash <<EOF
rm $C/x
EOF")"

blocks "unquoted subst in echo" Bash "$(bash_in "echo \$(cat $C/x)")"
blocks "Bash // variant" Bash "$(bash_in "cat /x//state//consent/f")"
blocks "Bash /./ variant" Bash "$(bash_in "cat /x/state/./consent/f")"
blocks "subst in gh body" Bash "$(bash_in "gh pr create --body \"\$(cat $C/x)\"")"
blocks "bash -c with substitution" Bash "$(bash_in "bash -c \"echo \$(cat $C/x)\"")"

echo "== allowed: free-text mentions =="
allows "Bash unrelated" Bash '{"command":"ls -la && git status"}'
allows "echo consent state" Bash '{"command":"echo consent state"}'
allows "echo state/consent" Bash '{"command":"echo state/consent"}'
allows "printf mention" Bash '{"command":"printf \"%s\\n\" \"state/consent is guarded\""}'
allows "git commit -m" Bash '{"command":"git commit -m \"fix: narrow guard for state/consent mentions\""}'
allows "git commit -am" Bash '{"command":"git commit -am \"docs: state/consent\""}'
allows "git log --grep" Bash '{"command":"git log --grep=state/consent"}'
allows "gh pr create --body" Bash '{"command":"gh pr create --title \"x state/consent\" --body \"touches state/consent docs\""}'
allows "gh api -f raw field" Bash '{"command":"gh api x -f body=@state/consent/x -F title=\"state/consent\""}'
allows "git -c free text" Bash '{"command":"git -c user.name=consent commit -m \"state/consent\""}'
allows "gh pr create --body-file -" Bash '{"command":"gh pr create --body-file - < /tmp/body.md"}'
allows "heredoc body to file" Bash "$(bash_in "cat <<'EOF' > docs/x.md
the guard protects state/consent
EOF")"
allows "grep -rn pattern" Bash '{"command":"grep -rn '"'"'state/consent'"'"' hooks/"}'
allows "grep -e pattern" Bash '{"command":"grep -e state/consent hooks/lib/consent.sh"}'
allows "rg pattern" Bash '{"command":"rg state/consent"}'
allows "git grep pattern" Bash '{"command":"git grep state/consent -- hooks"}'
allows "echo with quoted mention" Bash '{"command":"echo \"see state/consent for details\""}'
allows "heredoc body with command-looking text" Bash "$(bash_in "cat <<'EOF' > docs/y.md
rm -rf state/consent/grants
EOF")"
allows "git commit -m multi-line" Bash "$(bash_in "git commit -m \"fix: x

touches state/consent\"")"
allows "echo into doc" Bash '{"command":"echo state/consent >> notes.md"}'

echo
if [ "$fails" -eq 0 ]; then echo "block-consent-tamper: all assertions passed"; exit 0; fi
echo "block-consent-tamper: $fails assertion(s) FAILED"; exit 1
