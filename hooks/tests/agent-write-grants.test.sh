#!/usr/bin/env bash
#
# Regression test for #398 — file-producing agents hold a scoped `Write`
# so PR / review / issue bodies and commit messages go through
# `--body-file` / `git commit -F` on a scratch file under
# `<worktree>/.task-log/tmp/`, never through a prose heredoc on the
# command line (which the auto-mode classifier and the push hooks read as
# if the prose were the command).
#
# Groups:
#   G1 grants      — roster {pr-author, reviewer, unblocker, pr-opener,
#                    e2e-runner} has "Write" in tools:; pr-author and
#                    reviewer have no "Edit"; any agents/*.md whose fenced
#                    code uses `--body-file <file>` or `commit -F` has "Write".
#   G2 scope       — each roster agent states the `.task-log/tmp/` rule;
#                    every --body-file / commit -F path in the roster agents
#                    and in skills/pr-flow starts with a worktree-family
#                    placeholder (never /tmp, $TMPDIR, mktemp, ~/, <main-wt>).
#   G3 no heredocs — no `--body "$(cat <<`, no `cat > … <<`, no
#                    `-m "$(cat <<` in the roster agents or pr-flow;
#                    pr-opener no longer says "HEREDOC-written".
#   G4 bootstrap   — a `gh pr create --body-file <wt>/.task-log/tmp/pr-body.md`
#                    whose file text describes a push to main exits 0 through
#                    EVERY Bash PreToolUse hook listed in hooks/hooks.json,
#                    and the Write of that file exits 0 in scan-edit-write.sh.
#                    Nothing is asserted about other .task-log contents.
#
# Hermetic: no network (CLAUDE_PROJECT_DIR points at a temp dir with no
# .atelier.json, so semantic-risk-judge stays disabled). Requires jq.
#
# Run:  hooks/tests/agent-write-grants.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2016  # single quotes are deliberate: literal $TMPDIR / $( patterns
set -uo pipefail


REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/agents"
PR_FLOW="$REPO_ROOT/skills/pr-flow/SKILL.md"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

ROSTER="pr-author reviewer unblocker pr-opener e2e-runner"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available" >&2
  exit 0
fi

# tools: line of an agent's frontmatter.
tools_line() { grep -m1 '^tools:' "$AGENTS_DIR/$1.md"; }

# Fenced code content of a markdown file (lines between ``` fences).
fenced() {
  awk '/^[[:space:]]*```/ { f = !f; next } f { print }' "$1"
}

# Every path argument following `--body-file ` or `commit -F ` in a file.
body_paths() {
  grep -Eo -- '(--body-file|commit -F) +[^ ]+' "$1" | sed -E 's/^(--body-file|commit -F) +//'
}

# ---------------------------------------------------------------------------
# G1: grants
# ---------------------------------------------------------------------------
echo "G1: Write grants"

for a in $ROSTER; do
  if [ -f "$AGENTS_DIR/$a.md" ] && tools_line "$a" | grep -q '"Write"'; then
    pass "G1: $a has \"Write\" in tools:"
  else
    fail "G1: $a is missing \"Write\" in tools:"
  fi
done

for a in pr-author reviewer pr-opener; do
  if tools_line "$a" | grep -q '"Edit"'; then
    fail "G1: $a must NOT have \"Edit\" in tools:"
  else
    pass "G1: $a has no \"Edit\" in tools:"
  fi
done

for f in "$AGENTS_DIR"/*.md; do
  a="$(basename "$f" .md)"
  if fenced "$f" | grep -Eq -- '--body-file +[^ ]+|commit -F'; then
    if tools_line "$a" | grep -q '"Write"'; then
      pass "G1: $a uses --body-file / commit -F in fenced code and has \"Write\""
    else
      fail "G1: $a uses --body-file / commit -F in fenced code but lacks \"Write\""
    fi
  fi
done

# ---------------------------------------------------------------------------
# G2: scope prose and path scoping
# ---------------------------------------------------------------------------
echo "G2: Write scope"

for a in $ROSTER; do
  if grep -q '\.task-log/tmp/' "$AGENTS_DIR/$a.md"; then
    pass "G2: $a states the .task-log/tmp/ rule"
  else
    fail "G2: $a does not mention .task-log/tmp/"
  fi
done

check_paths() {
  local label="$1" file="$2" n=0 p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n=$((n + 1))
    p="${p%%[\`.,;]}"
    case "$p" in
      "<worktree>/"*|"<task-worktree>/"*|"<worktree-path>/"*)
        case "$p" in
          *'$TMPDIR'*|*mktemp*|*'~/'*|*'<main-wt>'*)
            fail "$label: path escapes the worktree: $p" ;;
          *"/.task-log/tmp/"*) pass "$label: path scoped to worktree scratch dir: $p" ;;
          *) fail "$label: path not under .task-log/tmp/: $p" ;;
        esac ;;
      *) fail "$label: path not under a worktree placeholder: $p" ;;
    esac
  done < <(body_paths "$file")
  if [ "$n" -eq 0 ]; then
    # Agents with no --body-file / -F path (e.g. e2e-runner) are fine.
    pass "$label: no --body-file / commit -F paths to scope (n=0)"
  fi
}

for a in $ROSTER; do
  check_paths "G2 $a" "$AGENTS_DIR/$a.md"
done
check_paths "G2 pr-flow" "$PR_FLOW"

# Forbidden roots must never appear as the path itself.
for a in $ROSTER; do
  if body_paths "$AGENTS_DIR/$a.md" | grep -Eq '^(/tmp/|\$TMPDIR|\$\(mktemp|~/|<main-wt>)'; then
    fail "G2: $a points a body/commit file at a forbidden root"
  else
    pass "G2: $a has no body/commit file under /tmp, \$TMPDIR, mktemp, ~/ or <main-wt>"
  fi
done
if body_paths "$PR_FLOW" | grep -Eq '^(/tmp/|\$TMPDIR|\$\(mktemp|~/|<main-wt>)'; then
  fail "G2: pr-flow points a body/commit file at a forbidden root"
else
  pass "G2: pr-flow has no body/commit file under a forbidden root"
fi

# ---------------------------------------------------------------------------
# G3: no prose heredocs
# ---------------------------------------------------------------------------
echo "G3: no prose heredocs"

heredoc_files=""
for a in $ROSTER; do heredoc_files="$heredoc_files $AGENTS_DIR/$a.md"; done
heredoc_files="$heredoc_files $PR_FLOW"

for f in $heredoc_files; do
  name="${f#"$REPO_ROOT"/}"
  if grep -Eq -- '--body +"\$\(cat <<' "$f"; then
    fail "G3: $name has --body \"\$(cat <<"
  else
    pass "G3: $name has no --body \"\$(cat <<"
  fi
  if grep -Eq -- 'cat +> *[^ ]+ *<<' "$f"; then
    fail "G3: $name has cat > file <<"
  else
    pass "G3: $name has no cat > file <<"
  fi
  if grep -Eq -- '-m +"\$\(cat <<' "$f"; then
    fail "G3: $name has -m \"\$(cat <<"
  else
    pass "G3: $name has no -m \"\$(cat <<"
  fi
done

if grep -q 'HEREDOC-written' "$AGENTS_DIR/pr-opener.md"; then
  fail "G3: pr-opener still says \"HEREDOC-written\""
else
  pass "G3: pr-opener no longer says \"HEREDOC-written\""
fi

# ---------------------------------------------------------------------------
# G4: bootstrap matrix
# ---------------------------------------------------------------------------
echo "G4: bootstrap matrix"

WT="$TMP/wt"
PROJ="$TMP/project"   # no .atelier.json: semantic-risk-judge stays disabled
mkdir -p "$WT/.task-log/tmp" "$PROJ" "$TMP/cwd"
BODY="$WT/.task-log/tmp/pr-body.md"
BODY_TEXT='## Summary

This PR documents that `git push origin main` and `git push --force` are
refused by the protected-push hook.

## Test plan

- never run git push origin main
- never run git push --force origin task/398-x
'
printf '%s\n' "$BODY_TEXT" > "$BODY"

CMD="gh pr create --base main --head task/398-x --title t --body-file $BODY"
BASH_PAYLOAD="$(jq -cn --arg c "$CMD" '{tool_name:"Bash", tool_input:{command:$c}}')"
WRITE_PAYLOAD="$(jq -cn --arg p "$BODY" --arg c "$BODY_TEXT" \
  '{tool_name:"Write", tool_input:{file_path:$p, content:$c}}')"

run_hook_script() {
  local script="$1" payload="$2"
  (
    cd "$TMP/cwd" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$PROJ" \
      bash "$script" <<<"$payload" >/dev/null 2>&1
  )
  echo "$?"
}

bash_hooks="$(jq -r '.hooks.PreToolUse[] | select(.matcher | test("Bash")) | .hooks[].command' "$HOOKS_JSON")"
n_hooks=0
seen=""
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  script="${cmd//\$\{CLAUDE_PLUGIN_ROOT\}/$REPO_ROOT}"
  script="${script//\"/}"
  n_hooks=$((n_hooks + 1))
  seen="$seen $(basename "$script")"
  if [ ! -f "$script" ]; then
    fail "G4: hook script not found for hooks.json entry: $cmd"
    continue
  fi
  code="$(run_hook_script "$script" "$BASH_PAYLOAD")"
  if [ "$code" = "0" ]; then
    pass "G4: $(basename "$script") exits 0 on gh pr create --body-file <wt>/.task-log/tmp/pr-body.md"
  else
    fail "G4: $(basename "$script") expected exit 0, got $code"
  fi
done <<<"$bash_hooks"

for expected in block-env-commit.sh block-protected-push.sh safe-commit.sh \
                scan-git-add.sh safe-package-change.sh semantic-risk-judge.sh; do
  case " $seen " in
    *" $expected "*) pass "G4: hooks.json still lists Bash hook $expected" ;;
    *) fail "G4: hooks.json no longer lists Bash hook $expected" ;;
  esac
done
if [ "$n_hooks" -ge 6 ]; then
  pass "G4: $n_hooks Bash PreToolUse hooks exercised"
else
  fail "G4: only $n_hooks Bash PreToolUse hooks found"
fi

code="$(run_hook_script "$REPO_ROOT/hooks/scan-edit-write.sh" "$WRITE_PAYLOAD")"
if [ "$code" = "0" ]; then
  pass "G4: scan-edit-write.sh exits 0 on the Write of pr-body.md"
else
  fail "G4: scan-edit-write.sh expected exit 0 on Write of pr-body.md, got $code"
fi

# Control case, information only (H-2 / #409 may change segment parsing).
CTRL_CMD="gh pr create --base main --head task/398-x --title t --body \"\$(cat <<'EOF'
git push origin main
EOF
)\""
CTRL_PAYLOAD="$(jq -cn --arg c "$CTRL_CMD" '{tool_name:"Bash", tool_input:{command:$c}}')"
ctrl_code="$(run_hook_script "$REPO_ROOT/hooks/block-protected-push.sh" "$CTRL_PAYLOAD")"
echo "  INFO: heredoc control case through block-protected-push.sh exited $ctrl_code (not asserted)"

# ---------------------------------------------------------------------------
echo
if [ "$fails" -eq 0 ]; then
  echo "agent-write-grants: all assertions passed"
  exit 0
fi
echo "agent-write-grants: $fails assertion(s) failed"
exit 1
