#!/usr/bin/env bash
#
# Regression test for hooks/block-env-read.sh — task #770 section A: a script
# written by a heredoc (`cat > F`, `cat >> F`, `tee [-a] F`) and RUN in the
# same Bash command is no longer inert text. Its body must not name a
# protected (non-template) env file, name-only uses included, and it keeps the
# regular per-segment inspection. A heredoc that is only written (or only
# touched by git add / chmod / ls / shellcheck) stays allowed as text, as #765
# made it.
#
# Hermetic: the hook is driven directly with a JSON payload; the only fixture
# files are empty placeholders under `mktemp -d`. No test ever reads an env
# fixture's contents. Requires jq (the hook fails open without it).
#
# Run:  hooks/tests/env-heredoc-script-run.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2016  # test commands are literal text; no expansion wanted

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-env-read.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FX="$TMP/fx"; mkdir -p "$FX"
# cwd whose tree holds an env file: a recursive grep there reads it.
CLEANTREE="$TMP/cleantree"; mkdir -p "$CLEANTREE/src"
: > "$CLEANTREE/.env"; : > "$CLEANTREE/src/a.ts"
DIRTYTREE="$TMP/dirtytree"; mkdir -p "$DIRTYTREE/src"
: > "$DIRTYTREE/src/a.ts"; : > "$DIRTYTREE/src/.env"

fails=0
cases=0
pass() { cases=$((cases + 1)); printf '  PASS: %s\n' "$1"; }
fail() { cases=$((cases + 1)); printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

HOOK_CWD=""
LAST_CODE=""
LAST_ERR=""
LAST_LOG=""

run_hook() {
  local payload d
  if [ -n "${HOOK_CWD:-}" ]; then
    payload="$(jq -cn --arg c "$1" --arg d "$HOOK_CWD" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')"
  else
    payload="$(jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}')"
  fi
  d="$(mktemp -d "$TMP/run.XXXXXX")"
  (
    cd "$FX" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$d" \
      bash "$HOOK" <<<"$payload" >/dev/null 2>"$d/stderr"
  )
  LAST_CODE=$?
  LAST_ERR="$(cat "$d/stderr")"
  LAST_LOG=""
  [ -f "$d/.task-log/hook-decisions.jsonl" ] && LAST_LOG="$(cat "$d/.task-log/hook-decisions.jsonl")"
}

expect_block() {
  run_hook "$1"
  if [ "$LAST_CODE" != "2" ]; then
    fail "block: ${1//$'\n'/ \\n } (expected exit 2, got $LAST_CODE)"
  elif ! grep -qi 'operator-only' <<<"$LAST_ERR"; then
    fail "block: ${1//$'\n'/ \\n } (stderr lacks 'operator-only')"
  elif ! printf '%s' "$LAST_LOG" | jq -e 'select(.hook=="block-env-read" and .action=="block")' >/dev/null 2>&1; then
    fail "block: ${1//$'\n'/ \\n } (no block entry in decision log)"
  else
    pass "block: ${1//$'\n'/ \\n }"
  fi
}

expect_allow() {
  run_hook "$1"
  if [ "$LAST_CODE" != "0" ]; then
    fail "allow: ${1//$'\n'/ \\n } (expected exit 0, got $LAST_CODE)"
  else
    pass "allow: ${1//$'\n'/ \\n }"
  fi
}

# hd <writer-line> <delimiter> <body> [rest-of-command]
# Builds: writer line, body line, delimiter line, then the rest (if any).
hd() {
  local out="$1"$'\n'"$3"$'\n'"$2"
  [ -n "${4-}" ] && out+=$'\n'"$4"
  printf '%s' "$out"
}

# --- A1: every writer shape x the run in the same command, body names a
# protected env file -> blocked.
echo "env-heredoc-script-run — writers x runner, body names a protected env file"
WRITERS=(
  "cat > run.sh <<'EOF'"
  'cat > run.sh <<EOF'
  'cat >> run.sh <<EOF'
  "cat >> run.sh <<'EOF'"
  'cat >run.sh <<EOF'
  'tee run.sh <<EOF'
  "tee run.sh <<'EOF'"
  'tee -a run.sh <<EOF'
  'cat <<EOF > run.sh'
  'cat <<EOF >> run.sh'
  'cat <<EOF >run.sh'
  'cat <<EOF >>run.sh'
  "cat <<'EOF' > run.sh"
)
for w in "${WRITERS[@]}"; do
  expect_block "$(hd "$w" EOF 'cat .env.prod' 'bash run.sh')"
done
expect_block "$(hd 'cat > run.sh <<-EOF' $'\tEOF' $'\tcat .env.prod' 'bash run.sh')"
expect_block "$(hd "cat > run.sh <<-'EOF'" $'\tEOF' $'\tcat .env.prod' 'sh run.sh')"

echo "env-heredoc-script-run — every runner shape, body names a protected env file"
RUNNERS=(
  'bash run.sh'
  'sh run.sh'
  'source run.sh'
  '. run.sh'
  './run.sh'
  'chmod +x run.sh && ./run.sh'
  'python3 run.sh'
  'node run.sh'
  'cat run.sh | sh'
  'sh < run.sh'
  'cp run.sh y.sh && bash y.sh'
  'zsh run.sh'
  'bash ./run.sh'
  'bash -x run.sh'
  'bash $PWD/run.sh'
)
for r in "${RUNNERS[@]}"; do
  expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' "$r")"
done
# tee and append writers with a few runners too.
expect_block "$(hd 'tee -a run.sh <<EOF' EOF 'cat .env' 'source run.sh')"
expect_block "$(hd 'tee run.sh <<EOF' EOF 'cat .env.local' 'chmod +x run.sh && ./run.sh')"
expect_block "$(hd 'cat >> run.sh <<EOF' EOF 'cat .env' 'python3 run.sh')"
# The write and the run on one line, and with a path in the target.
expect_block "$(hd "cat > /tmp/x/run.sh <<'EOF'" EOF 'cat .env.prod' 'bash /tmp/x/run.sh')"
expect_block "$(hd "cat > ./run.sh <<'EOF'" EOF 'cat .env.prod' 'chmod +x ./run.sh; ./run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' 'cd sub && bash ../run.sh')"

echo "env-heredoc-script-run — name-only uses of a protected env file in the body count"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'test -f .env.prod && echo yes' 'bash run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'ls -la .env' 'bash run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'echo ".env.local present"' 'bash run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cp x ../a/.env.staging' 'sh run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF '. ./.env.production' './run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .envrc' 'bash run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.example.local' 'bash run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .ENV.PROD' 'bash run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF $'echo start\nexport A=1\ntest -f .env.prod\necho done' 'bash run.sh')"
# A template named next to a protected file still blocks.
expect_block "$(hd "cat > run.sh <<'EOF'" EOF $'cp .env.example x\ncat .env' 'bash run.sh')"

echo "env-heredoc-script-run — script runs earlier or later in the command, other segments"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' 'echo go; bash run.sh; echo done')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' 'true || bash run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' 'ls && sh run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' 'echo $(bash run.sh)')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' 'x=`bash run.sh`')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' 'cat run.sh | sh | tee out.log')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' 'wc -l run.sh | cat; bash run.sh')"
# Piped or nested inert-listed command still counts as a run.
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' 'ls run.sh | sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.prod' 'sh -c "$(cat run.sh)"')"
# A target that is not a plain word is run by any later interpreter.
expect_block "$(hd 'cat > $HOME/x.sh <<EOF' EOF 'cat .env.prod' 'bash $HOME/x.sh')"
expect_block "$(hd 'cat > "$D"/x.sh <<EOF' EOF 'cat .env.prod' 'sh something')"
# git runs a hook script itself.
expect_block "$(hd "cat > .git/hooks/pre-commit <<'EOF'" EOF 'cat .env.prod' 'chmod +x .git/hooks/pre-commit')"
expect_block "$(hd "cat > hooks/pre-commit <<'EOF'" EOF 'cat .env.prod' 'git commit -m x')"

echo "env-heredoc-script-run — two heredocs, one run script"
expect_block "$(printf '%s\n' "cat > a.sh <<'EOF'" 'echo ok' 'EOF' "cat > b.sh <<'EOF'" 'cat .env.prod' 'EOF' 'bash b.sh')"

# --- A2: template-only / no-env-name bodies that are run stay allowed.
echo "env-heredoc-script-run — run script naming only templates or no env name"
for tpl in .env.example .env.sample .env.template .env.dist .env.catalog.example ../x/.env.example; do
  expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "test -f $tpl" 'bash run.sh')"
done
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.example' './run.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF 'cp .env.sample x 2>/dev/null; echo hi' 'chmod +x run.sh && ./run.sh')"
expect_allow "$(hd 'tee run.sh <<EOF' EOF 'cat .env.template' 'source run.sh')"
expect_allow "$(hd 'cat >> run.sh <<EOF' EOF 'diff .env.dist x' 'python3 run.sh')"
expect_allow "$(hd 'cat <<EOF > run.sh' EOF 'cat .env.catalog.example' 'bash run.sh')"
expect_allow "$(hd 'cat > run.sh <<-EOF' $'\tEOF' $'\tcat .env.example' 'bash run.sh')"
for r in "${RUNNERS[@]}"; do
  expect_allow "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.example' "$r")"
done
for r in "${RUNNERS[@]}"; do
  expect_allow "$(hd "cat > run.sh <<'EOF'" EOF $'echo hello\nexit 0' "$r")"
done
expect_allow "$(hd 'cat > run.sh <<EOF' EOF 'echo $HOME' 'bash run.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF $'echo one\n# env docs: use a .env.example' 'bash run.sh')"

# --- A2: the regular per-segment inspection still applies to a run script.
echo "env-heredoc-script-run — run script body still gets per-segment inspection"
HOOK_CWD="$DIRTYTREE"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'grep -rn TODO src/' 'bash run.sh')"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'grep -rn TODO' './run.sh')"
expect_block "$(hd 'tee run.sh <<EOF' EOF 'grep -rn TODO .' 'sh run.sh')"
# The same recursive-grep script that is only written stays text.
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF 'grep -rn TODO src/')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF 'grep -rn TODO src/' 'chmod +x run.sh')"
# A body that spells the `.env*` glob (even in --exclude) names a protected
# name, so a run script is blocked: pinned current behaviour, use rg instead.
expect_block "$(hd "cat > run.sh <<'EOF'" EOF "grep -rn --exclude='.env*' TODO src/" 'bash run.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF 'rg TODO src/' 'bash run.sh')"
# A clean tree: the recursive grep reads no env file, so it stays allowed.
HOOK_CWD="$CLEANTREE"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF 'grep -rn TODO src/' 'bash run.sh')"
HOOK_CWD=""
# A direct read in the body is a protected name, with or without a cwd tree.
HOOK_CWD="$DIRTYTREE"
expect_block "$(hd "cat > run.sh <<'EOF'" EOF 'cat .env.local' 'bash run.sh')"
HOOK_CWD=""

# --- A3: written and not run in the command -> allowed as text (#765).
echo "env-heredoc-script-run — written but not run stays allowed text"
NOTRUN_BODY='cat .env.prod'
for w in "${WRITERS[@]}"; do
  expect_allow "$(hd "$w" EOF "$NOTRUN_BODY")"
done
expect_allow "$(hd 'cat > run.sh <<-EOF' $'\tEOF' $'\tcat .env.prod')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'git add run.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'chmod +x run.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'ls run.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'ls -l run.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'shellcheck run.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'chmod +x run.sh && git add run.sh && ls run.sh && shellcheck run.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'test -f run.sh && wc -l run.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'git add run.sh && git diff --cached --stat')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'stat run.sh; file run.sh; diff run.sh other.sh; cmp run.sh other.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'rm run.sh')"
# Running a different script is not running the written one.
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'bash other.sh')"
expect_allow "$(hd "cat > run.sh <<'EOF'" EOF "$NOTRUN_BODY" 'bash run.sh.bak')"
# Pre-existing #765 heredoc-as-text results are unchanged.
expect_allow $'cat > out <<\'EOF\'\nhello .env\nEOF'
expect_allow $'cat > out <<-EOF\nx .env\nEOF'
expect_allow $'cat > out <<"EOF"\nx .env\nEOF'
expect_allow $'tee notes.md <<\'EOF\'\nsee .env.local\nEOF'
expect_allow $'cat >> notes.md <<\'EOF\'\nsource .env.prod\nEOF'
# A heredoc fed straight to an interpreter is still blocked.
expect_block $'bash <<\'EOF\'\ncat .env\nEOF'

echo
echo "cases: $cases, failures: $fails"
[ "$fails" -eq 0 ] && exit 0 || exit 1
