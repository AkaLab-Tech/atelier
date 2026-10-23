#!/usr/bin/env bash
#
# Regression test for #504 — safe-commit must trigger only on REAL
# `git commit` invocations (not text that merely mentions one) and must fail
# closed (exit 2, "could not determine the target tree") when the commit's
# target tree is not a literal, resolvable path.
#
# Hermetic: throwaway git repos under a temp dir, package managers shimmed
# on PATH. The
# fixtures' `typecheck` script writes a marker file in its cwd and fails,
# so:
#   none  = exit 0, no marker, no log entry   (hook did not trigger)
#   gated = exit 2 from the red step, marker in the expected tree
#   unres = exit 2 "could not determine the target tree", no marker, a
#           `target-unresolved` block log entry
#   bypass= exit 2 with the #277 gate-bypass refusal (not target-unresolved)
#
# bash-3.2 compatible. Run:  hooks/tests/safe-commit-matcher.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# The single-quoted command fixtures deliberately carry literal $VAR text.
# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/safe-commit.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

SHIM_BIN="$TMP/bin"
mkdir -p "$SHIM_BIN"
for pm in pnpm npm yarn bun; do
  cat > "$SHIM_BIN/$pm" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "run" ]; then
  script="$(jq -r --arg s "$2" '.scripts[$s] // empty' package.json 2>/dev/null)"
  [ -z "$script" ] && { echo "no script: $2" >&2; exit 1; }
  exec sh -c "$script"
fi
exit 0
SHIM
  chmod +x "$SHIM_BIN/$pm"
done
export PATH="$SHIM_BIN:$PATH"

# A repo whose typecheck drops ./marker and fails, with one staged non-docs
# file so the docs-only short-circuit does not apply.
make_tree() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  cat > "$dir/package.json" <<'PKG'
{ "name": "fixture", "version": "0.0.0", "scripts": { "typecheck": "touch ./marker; exit 1" } }
PKG
  : > "$dir/pnpm-lock.yaml"
  printf 'console.log(1)\n' > "$dir/feature.js"
  git -C "$dir" add -A
}

P="$TMP/p"; Q="$TMP/q"; CWD="$TMP/cwd"
make_tree "$P"; make_tree "$Q"; make_tree "$CWD"
LOGS="$TMP/logs"

# run_case <expect> <expect-marker-dir|-> <cwd> <label> <command>
run_case() {
  local expect="$1" mdir="$2" cwd="$3" label="$4" cmd="$5"
  local payload out rc logf
  rm -f "$P/marker" "$Q/marker" "$CWD/marker"
  rm -rf "$LOGS"
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')"
  out="$(
    cd "$cwd" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$LOGS" \
      bash "$HOOK" <<<"$payload" 2>&1 >/dev/null
  )"
  rc=$?
  logf="$LOGS/.task-log/hook-decisions.jsonl"
  local marked=""
  [ -f "$P/marker" ] && marked="$marked p"
  [ -f "$Q/marker" ] && marked="$marked q"
  [ -f "$CWD/marker" ] && marked="$marked cwd"

  case "$expect" in
    none)
      if [ "$rc" = 0 ] && [ -z "$marked" ] && [ ! -s "$logf" ]; then
        pass "$label"
      else
        fail "$label — expected no trigger; rc=$rc marker=[$marked] log=$([ -s "$logf" ] && echo yes || echo no)"
      fi ;;
    gated)
      if [ "$rc" = 2 ] && [ "$marked" = " $mdir" ] \
         && ! printf '%s' "$out" | grep -q 'could not determine'; then
        pass "$label"
      else
        fail "$label — expected red gate in [$mdir]; rc=$rc marker=[$marked] out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      fi ;;
    unres)
      if [ "$rc" = 2 ] && [ -z "$marked" ] \
         && printf '%s' "$out" | grep -q 'could not determine the target tree; pass the literal absolute path' \
         && grep -q 'target-unresolved' "$logf" 2>/dev/null; then
        pass "$label"
      else
        fail "$label — expected target-unresolved refusal; rc=$rc marker=[$marked] out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      fi ;;
    bypass)
      if [ "$rc" = 2 ] && [ -z "$marked" ] \
         && printf '%s' "$out" | grep -q 'gate-bypass' \
         && ! printf '%s' "$out" | grep -q 'could not determine' \
         && grep -q 'bypass-attempt' "$logf" 2>/dev/null; then
        pass "$label"
      else
        fail "$label — expected #277 bypass refusal; rc=$rc marker=[$marked] out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      fi ;;
  esac
}

echo "#504 — safe-commit matcher: only real commits trigger"
run_case none - "$CWD" "git log + gh api --jq with commit_id (no commit invoked)" \
  "git -C $P log --oneline && gh api repos/o/r/pulls/1/reviews --jq '.[] | .commit_id[0:8]'"
run_case none - "$CWD" "heredoc body mentioning 'git -C /x commit'" \
  $'cat <<EOF\ngit -C /x commit\nEOF'
run_case none - "$CWD" "echo of a quoted commit command" \
  'echo "git -C /x commit -m y"'
run_case none - "$CWD" "printf of 'git commit'" \
  "printf '%s\\n' 'git commit'"
run_case none - "$CWD" "git log --grep=\"git commit\"" \
  'git log --grep="git commit"'

echo "#504 — unresolved target tree is refused (fail closed)"
run_case unres - "$CWD" 'git -C "$W" commit (literal $W)' \
  'git -C "$W" commit -m x'
run_case unres - "$CWD" 'git -C ~/wt commit' \
  'git -C ~/wt commit'
run_case unres - "$CWD" 'git -C "$(pwd)/wt" commit' \
  'git -C "$(pwd)/wt" commit'
run_case unres - "$CWD" 'cd "$W" && git commit' \
  'cd "$W" && git commit'
run_case unres - "$CWD" 'git -C /does/not/exist commit' \
  'git -C /does/not/exist commit'
run_case unres - "$CWD" "two commit segments pointing at different trees" \
  "git -C $P commit -m a && git -C $Q commit -m b"

echo "#504 — a literal path is validated"
run_case gated p "$CWD" "git -C <literal> commit (bare)" \
  "git -C $P commit -m x"
run_case gated p "$CWD" "git -C \"<literal>\" commit (double-quoted)" \
  "git -C \"$P\" commit -m x"
run_case gated p "$CWD" "cd <literal> && git commit" \
  "cd $P && git commit -m x"
run_case gated p "$CWD" "git -C <p> add -A && git -C <p> commit" \
  "git -C $P add -A && git -C $P commit -m x"
run_case gated p "$CWD" "commit on the line after a closed heredoc" \
  $'cat <<EOF\nhello\nEOF\n'"git -C $P commit -m x"
run_case gated p "$CWD" "(cd <p> && git commit) subshell" \
  "(cd $P && git commit -m x)"
run_case gated p "$CWD" "FOO=1 git -C <p> commit" \
  "FOO=1 git -C $P commit"
run_case gated p "$CWD" "git -C <p> -c user.name=x commit" \
  "git -C $P -c user.name=x commit"
run_case gated p "$CWD" "bash -c 'git -C <p> commit -m x'" \
  "bash -c 'git -C $P commit -m x'"

echo "#504 — also"
run_case gated cwd "$CWD" "plain git commit validates \$PWD" \
  "git commit -m x"
run_case bypass - "$CWD" 'unresolved --git-dir="$X" still gets the #277 bypass refusal' \
  'git --git-dir="$X" commit -m x'
run_case gated p "$CWD" "fallback (unbalanced quote containing git commit) still gates" \
  "git -C $P commit -m 'unterminated"

echo "#504 — commit fed to a shell on stdin (fail-closed, legacy path)"
run_case gated p "$CWD" "bash heredoc carrying git -C <p> commit" \
  $'bash <<\'EOF\'\ngit -C '"$P"$' commit -m x\nEOF'
run_case gated p "$CWD" "echo '...' | sh" \
  "echo 'git -C $P commit -m x' | sh"
run_case gated p "$CWD" "pipe into /bin/bash" \
  "echo 'git -C $P commit -m x' | /bin/bash"
run_case gated p "$CWD" "pipe into env bash" \
  "echo 'git -C $P commit -m x' | env bash"
run_case gated p "$CWD" "pipe into sh -s" \
  "echo 'git -C $P commit -m x' | sh -s"
run_case gated p "$CWD" "pipe into bash -" \
  "echo 'git -C $P commit -m x' | bash -"
run_case gated p "$CWD" "pipe into bash -o pipefail" \
  "echo 'git -C $P commit -m x' | bash -o pipefail"
run_case gated p "$CWD" "bash < file with a commit in the line" \
  "bash < /tmp/x.sh; git -C $P commit -m x"
run_case gated p "$CWD" "bash <<< here-string" \
  "bash <<< 'git -C $P commit -m x'"
run_case gated p "$CWD" "pipe into xargs sh" \
  "echo 'git -C $P commit -m x' | xargs sh"
run_case gated p "$CWD" "pipe into source /dev/stdin" \
  "echo 'git -C $P commit -m x' | source /dev/stdin"
run_case unres - "$CWD" "pipe into sh with an unresolved target is refused" \
  "echo 'git -C \"\$W\" commit -m x' | sh"
run_case none - "$CWD" "bash script.sh without a commit does not trigger" \
  "bash script.sh"
run_case none - "$CWD" "heredoc into bash without a commit does not trigger" \
  $'bash <<EOF\necho hi\nEOF'
run_case none - "$CWD" "cat heredoc body mentioning a commit does not trigger" \
  $'cat <<EOF\ngit -C /x commit\nEOF'

echo
if [ "$fails" -eq 0 ]; then
  echo "All #504 matcher checks passed."
  exit 0
else
  echo "$fails #504 matcher check(s) FAILED."
  exit 1
fi
