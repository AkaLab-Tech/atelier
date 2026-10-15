#!/usr/bin/env bash
#
# Tests for #452 — scripts/atelier-diff-scope-check (pre-review diff scope check).
#
# Locks: the #450 shape (one replacement eating following headings) fails; an
# in-place section edit, a plan-named removal and a moved heading pass; removed
# files fail unless named; ROADMAP.md / IN_PROGRESS.md are exempt; the plan is
# read from stdin with start/end markers; fenced "headings" are ignored;
# deletion-heavy hunks fail (unnamed) or warn (named); exit 2 on bad usage / no
# git; and the prose contract in agents/implementer.md, agents/task-orchestrator.md
# and install.sh.
#
# Hermetic: every scenario builds a throwaway fixture repo (with a local bare
# "origin" so origin/main exists) under mktemp -d. No writes outside $TMP.
#
# Run:  hooks/tests/diff-scope-check.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO_ROOT/scripts/atelier-diff-scope-check"
IMPL="$REPO_ROOT/agents/implementer.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
INSTALL="$REPO_ROOT/install.sh"

[ -x "$CHECK" ] || { echo "  FAIL: $CHECK not found or not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

n=0
WT=""
# mkfix: fresh clone of a bare origin with a committed + pushed base on main.
mkfix() {
  n=$((n + 1))
  local d="$TMP/f$n"
  mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/wt" 2>/dev/null
  WT="$d/wt"
  git -C "$WT" checkout -q -b main
  cat >"$WT/doc.md" <<'EOF'
# Title

## Alpha

alpha body

## Beta

beta body

## Gamma

gamma body

## Delta

delta body
EOF
  printf 'keep\n' >"$WT/gone.txt"
  printf '# Roadmap\n\n## Todo\n\n- [ ] one\n\n## Done\n\n- [x] zero\n' >"$WT/ROADMAP.md"
  printf '# In progress\n\n## Active\n\n- item\n' >"$WT/IN_PROGRESS.md"
  : >"$WT/big.txt"
  local i
  for i in $(seq 1 40); do echo "line $i" >>"$WT/big.txt"; done
  git -C "$WT" add -A
  git -C "$WT" commit -q -m "base"
  git -C "$WT" push -q origin main 2>/dev/null
  git -C "$WT" checkout -q -b task/452-x
}

OUT=""; RC=0
# run <plan-text> : writes plan to a file, runs the check.
run() {
  printf '%s\n' "$1" >"$TMP/plan.md"
  OUT=$("$CHECK" --worktree "$WT" --base main --plan "$TMP/plan.md" 2>"$TMP/err")
  RC=$?
}

expect() { # <name> <rc> <grep-pattern-or-empty>
  local name="$1" rc="$2" pat="${3:-}"
  if [ "$RC" -ne "$rc" ]; then
    fail "$name (exit $RC, want $rc; out: $(printf '%s' "$OUT" | tr '\n' '|'))"
    return
  fi
  if [ -n "$pat" ] && ! printf '%s\n' "$OUT" | grep -qE -- "$pat"; then
    fail "$name (missing /$pat/; out: $(printf '%s' "$OUT" | tr '\n' '|'))"
    return
  fi
  pass "$name"
}

echo "== behavior"

# 1. #450 shape: one replacement eats the following headings.
mkfix
cat >"$WT/doc.md" <<'EOF'
# Title

## Alpha

alpha rewritten, and everything after it was swallowed
EOF
run "Rewrite the Alpha section only."
expect "#450 shape fails (exit 1)" 1 '^result=fail$'
printf '%s\n' "$OUT" | grep -qx 'fail removed-heading doc.md ## Beta' \
  && printf '%s\n' "$OUT" | grep -qx 'fail removed-heading doc.md ## Gamma' \
  && printf '%s\n' "$OUT" | grep -qx 'fail removed-heading doc.md ## Delta' \
  && pass "#450 shape names Beta, Gamma and Delta" \
  || fail "#450 shape should list Beta/Gamma/Delta (out: $(printf '%s' "$OUT" | tr '\n' '|'))"
printf '%s\n' "$OUT" | grep -q 'Alpha' \
  && fail "#450 shape must not report the surviving Alpha heading" \
  || pass "#450 shape does not report Alpha"

# 2. In-place section edit passes.
mkfix
sed 's/^beta body$/beta body, edited in place/' "$WT/doc.md" >"$WT/doc.new" && mv "$WT/doc.new" "$WT/doc.md"
run "Edit the Beta section."
expect "in-place section edit passes" 0 '^result=pass$'

# 3. Removal named in the plan passes.
mkfix
awk '/^## Gamma$/{skip=1;next} /^## /{skip=0} !skip' "$WT/doc.md" >"$WT/doc.new" && mv "$WT/doc.new" "$WT/doc.md"
run "Remove the \`## Gamma\` section entirely."
expect "removal named in plan passes" 0 '^result=pass$'
mkfix
awk '/^## Gamma$/{skip=1;next} /^## /{skip=0} !skip' "$WT/doc.md" >"$WT/doc.new" && mv "$WT/doc.new" "$WT/doc.md"
run "Tidy the docs."
expect "same removal unnamed fails" 1 '^fail removed-heading doc.md ## Gamma$'

# 4. Moved heading passes.
mkfix
cat >"$WT/doc.md" <<'EOF'
# Title

## Beta

beta body

## Gamma

gamma body

## Delta

delta body

## Alpha

alpha body
EOF
run "Reorder sections."
expect "moved heading passes" 0 '^result=pass$'

# 5. Removed file fails; passes when named.
mkfix
git -C "$WT" rm -q gone.txt
run "Unrelated cleanup."
expect "removed file fails" 1 '^fail removed-file gone.txt$'
mkfix
git -C "$WT" rm -q gone.txt
run "Delete gone.txt as part of the cleanup."
expect "removed file named in plan passes" 0 '^result=pass$'

# 6. ROADMAP.md / IN_PROGRESS.md moves are exempt.
mkfix
printf '# Roadmap\n\n## Done\n\n- [x] zero\n- [x] one\n' >"$WT/ROADMAP.md"
printf '# In progress\n' >"$WT/IN_PROGRESS.md"
run "Nothing about the roadmap here."
expect "ROADMAP.md / IN_PROGRESS.md heading moves exempt" 0 '^result=pass$'
mkfix
git -C "$WT" rm -q ROADMAP.md IN_PROGRESS.md
run "Nothing about the roadmap here."
expect "ROADMAP.md / IN_PROGRESS.md deletion exempt" 0 '^result=pass$'

# 7. Plan from stdin, restricted to the marker block.
mkfix
awk '/^## Gamma$/{skip=1;next} /^## /{skip=0} !skip' "$WT/doc.md" >"$WT/doc.new" && mv "$WT/doc.new" "$WT/doc.md"
OUT=$(printf '%s\n' 'chatter ## Gamma outside the markers' '<!-- atelier:plan:start -->' 'Edit Alpha only.' '<!-- atelier:plan:end -->' 'more ## Gamma talk' \
  | "$CHECK" --worktree "$WT" --base main --plan - 2>/dev/null); RC=$?
expect "stdin plan: mention outside markers does not count" 1 '^fail removed-heading doc.md ## Gamma$'
OUT=$(printf '%s\n' 'preamble' '<!-- atelier:plan:start -->' 'Remove ## Gamma.' '<!-- atelier:plan:end -->' \
  | "$CHECK" --worktree "$WT" --base main --plan - 2>/dev/null); RC=$?
expect "stdin plan: mention inside markers passes" 0 '^result=pass$'

# 8. Fenced-code heading-like lines are not reported.
mkfix
cat >"$WT/doc.md" <<'EOF'
# Title

## Alpha

```sh
## not a heading
```
EOF
git -C "$WT" add doc.md && git -C "$WT" commit -q -m "fence base" && git -C "$WT" push -q origin task/452-x 2>/dev/null
# Move the merge base forward: origin/main must contain the fenced version.
git -C "$WT" push -q origin task/452-x:main 2>/dev/null
git -C "$WT" fetch -q origin 2>/dev/null
printf '# Title\n\n## Alpha\n\n```sh\nplain\n```\n' >"$WT/doc.md"
run "Edit the Alpha code block."
expect "fenced heading-like line removal not reported" 0 '^result=pass$'

# 9. Deletion-heavy hunk: fail when unnamed, warn + pass when named.
mkfix
{ echo "line 1"; echo "line 2"; echo "line 3"; echo "line 4"; echo "line 5"; sed -n '31,40p' "$WT/big.txt"; } >"$WT/big.new" && mv "$WT/big.new" "$WT/big.txt"
run "Unrelated."
expect "deletion-heavy unnamed fails" 1 '^fail deletion-heavy big.txt @@ -[0-9]+/\+[0-9]+$'
run "Trim big.txt down to the essentials."
expect "deletion-heavy named warns and passes" 0 '^warn deletion-heavy big.txt '
printf '%s\n' "$OUT" | grep -qx 'result=pass' && pass "deletion-heavy named ends result=pass" || fail "deletion-heavy named should end result=pass"

# 10. Errors: bad usage / no git / missing plan / no origin ref.
mkfix
OUT=$("$CHECK" --worktree "$WT" 2>/dev/null); RC=$?
expect "missing args exits 2" 2 ''
OUT=$("$CHECK" --bogus 2>/dev/null); RC=$?
expect "unknown flag exits 2" 2 ''
mkdir -p "$TMP/nogit"
printf 'x\n' >"$TMP/plan2.md"
OUT=$(GIT_CEILING_DIRECTORIES="$TMP" "$CHECK" --worktree "$TMP/nogit" --base main --plan "$TMP/plan2.md" 2>/dev/null); RC=$?
expect "non-git directory exits 2" 2 ''
OUT=$("$CHECK" --worktree "$WT" --base main --plan "$TMP/does-not-exist.md" 2>/dev/null); RC=$?
expect "unreadable plan exits 2" 2 ''
OUT=$("$CHECK" --worktree "$WT" --base nosuchbase --plan "$TMP/plan2.md" 2>/dev/null); RC=$?
expect "missing origin/<base> exits 2" 2 ''
printf '%s\n' "$OUT" | grep -q 'result=pass' && fail "error exit must never print result=pass" || pass "error exit never prints result=pass"

echo "== prose contract"

has() { # <file> <fixed phrase> <name>
  if grep -qF -- "$2" "$1"; then pass "$3"; else fail "$3 (missing: $2)"; fi
}

has "$IMPL" '**Edit discipline.**' "implementer: Edit discipline rule present"
has "$IMPL" 'Edit the smallest span that contains the change' "implementer: smallest span"
has "$IMPL" 'Never let an `Edit`/`Write` replacement run past the end of the target section' "implementer: no overrun"
has "$IMPL" 're-`Read` the file and confirm the headings outside the target are unchanged' "implementer: re-Read after big replacement"
has "$IMPL" 'needs plan amendment' "implementer: report needs plan amendment"
has "$IMPL" 'atelier-diff-scope-check' "implementer: names the scope check"

has "$ORCH" '### Scope check — `atelier-diff-scope-check` (#452)' "orchestrator: Scope check section"
has "$ORCH" 'run the **Scope check** (below) first; only on `result=pass` immediately invoke `/validate`' "orchestrator: scope check before /validate"
has "$ORCH" 'right before **every** authoring dispatch' "orchestrator: scope check before authoring dispatch"
has "$ORCH" 're-run the **Scope check** (`result=pass` required), then dispatch the selected primitive' "orchestrator: re-run before dispatch"
has "$ORCH" 'does not consume a review-fix cycle' "orchestrator: no review-fix cycle consumed"
has "$ORCH" 'one normal attempt' "orchestrator: one normal attempt"
has "$ORCH" 'held: unplanned removal needs plan amendment' "orchestrator: second-identical-finding hold"
has "$ORCH" 'held: diff scope check errored' "orchestrator: exit 2 fails closed"

has "$INSTALL" '_phase_c_1_symlink_helper atelier-diff-scope-check' "install.sh: helper symlink registration"

# Ordering: scope check mention precedes the /validate invocation on the same line.
line=$(grep -F 'run the **Scope check** (below) first' "$ORCH" | head -1)
case "$line" in
  *'Scope check'*'/validate'*) pass "orchestrator: Scope check precedes /validate in the loop step" ;;
  *) fail "orchestrator: Scope check should precede /validate in the loop step" ;;
esac

echo
if [ "$fails" -eq 0 ]; then
  echo "diff-scope-check: all assertions passed"
  exit 0
fi
echo "diff-scope-check: $fails assertion(s) failed"
exit 1
