#!/usr/bin/env bash
#
# Regression test for #277 — harden hooks/safe-commit.sh against
# gate-bypass attempts (git --git-dir/--work-tree redirection, inline
# ATELIER_SKIP_SAFE_COMMIT= assignment, --no-verify), observed during
# #208. Asserts:
#
#   1. A `git --git-dir=... --work-tree=... commit` form is now
#      INTERCEPTED and GATED — it must not fall through to a silent
#      `exit 0` (the matcher-gap that made #208 possible).
#   2. Every in-command bypass signature is BLOCKED (exit 2), logged as
#      a "block" / "gate-bypass signature: ..." decision:
#        - inline `ATELIER_SKIP_SAFE_COMMIT=` assignment
#        - `--git-dir=<path>` / `--git-dir <path>` (both spacing forms)
#        - `--work-tree=<path>` / `--work-tree <path>` (both spacing forms)
#        - `--no-verify`
#   3. Legitimate flows are NOT over-blocked:
#        - the operator's out-of-band `ATELIER_SKIP_SAFE_COMMIT=1`
#          escape hatch, set in the hook's *environment* (never inline
#          in the command) → exit 0
#        - a plain green `git commit -m ...` → exit 0
#        - a legitimate `git -C <worktree> commit -m ...` (M7.1.F57
#          form, no bypass flags) → exit 0
#
# Hermetic: builds throwaway git repos + a linked worktree under a temp
# dir and drives hooks/safe-commit.sh directly. No network, no real
# pnpm/npm — package managers are shimmed on PATH exactly as in
# hooks/tests/safe-commit-worktree.test.sh (same harness, mirrored here
# rather than shared, per the M7.1.F57 pattern). Requires git + jq.
#
# Run:  hooks/tests/safe-commit-bypass.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/safe-commit.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- package-manager shims --------------------------------------------------
# Each shim implements `<pm> run <script>`: read package.json#scripts[$2]
# in the cwd and exec it. Lets legitimate-flow cases run a real green
# gate without installing anything.
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

# --- helpers ----------------------------------------------------------------

# Run the hook as Claude Code would: PWD = main repo, payload = a Bash
# command. Echoes the exit code.
run_hook() {
  local pwd_dir="$1" command_str="$2"
  local payload
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$pwd_dir" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$HOOK" <<<"$payload" >/dev/null 2>&1
  )
  echo "$?"
}

# Like run_hook but also exports ATELIER_SKIP_SAFE_COMMIT=1 into the
# hook's own environment (the legitimate operator out-of-band escape
# hatch — distinct from an inline assignment inside the command string).
run_hook_env_skip() {
  local pwd_dir="$1" command_str="$2"
  local payload
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$pwd_dir" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$TMP/logs" \
    ATELIER_SKIP_SAFE_COMMIT=1 \
      bash "$HOOK" <<<"$payload" >/dev/null 2>&1
  )
  echo "$?"
}

# Echoes the hook's combined stderr (the block message) instead of the
# exit code.
run_hook_stderr() {
  local pwd_dir="$1" command_str="$2"
  local payload
  payload="$(jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$pwd_dir" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$HOOK" <<<"$payload" 2>&1 1>/dev/null
  )
}

# Build a main repo whose `typecheck` exits 0 (a green gate), plus a
# pnpm lockfile. `lint`/`test` are intentionally absent so those steps
# hit the "N/A — allow" path, mirroring safe-commit-worktree.test.sh.
make_project() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  cat > "$dir/package.json" <<'PKG'
{ "name": "fixture", "version": "0.0.0", "scripts": { "typecheck": "sh ./tc.sh" } }
PKG
  printf 'exit 0\n' > "$dir/tc.sh"
  : > "$dir/pnpm-lock.yaml"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
}

echo "#277 regression — safe-commit.sh refuses gate-bypass attempts"

# === Fixture: main repo + linked worktree, GATE WOULD PASS ================
# Deliberately a green gate everywhere. This means any FAIL-to-block
# result below is unambiguous: it cannot be explained by an unrelated
# red gate, only by the hook failing to recognise the bypass signature.
S="$TMP/s"; make_project "$S/main"
git -C "$S/main" worktree add -q -b task/bypass "$S/wt"
printf 'console.log(1)\n' > "$S/wt/feature.js"
git -C "$S/wt" add -A

WT="$S/wt"
GITDIR="$S/wt/.git"

# === 1. git-dir/work-tree commit is now GATED, not silently allowed =======
# Both flags together, `=` form — the exact #208 vector. Must be exit 2
# (blocked as a bypass signature), never exit 0.
code="$(run_hook "$S/main" "git --git-dir=$GITDIR --work-tree=$WT commit -m x")"
[ "$code" = "2" ] && pass "git --git-dir=/--work-tree= commit → intercepted + blocked (exit 2), not silently allowed" \
                   || fail "git --git-dir=/--work-tree= commit expected exit 2 (gated), got $code"

# === 2. Inline bypass signatures — each blocked with exit 2 ===============

# (a) inline ATELIER_SKIP_SAFE_COMMIT= assignment embedded in the command
# (as opposed to set in the environment — see legitimate-flow case below).
code="$(run_hook "$S/main" "ATELIER_SKIP_SAFE_COMMIT=1 git commit -m x")"
[ "$code" = "2" ] && pass "inline ATELIER_SKIP_SAFE_COMMIT=1 in command → blocked (exit 2)" \
                   || fail "inline ATELIER_SKIP_SAFE_COMMIT=1 expected exit 2, got $code"

# (b) --git-dir=..., "=" spacing form.
code="$(run_hook "$S/main" "git --git-dir=$GITDIR commit -m x")"
[ "$code" = "2" ] && pass "git --git-dir=<path> commit → blocked (exit 2)" \
                   || fail "git --git-dir=<path> commit expected exit 2, got $code"

# (b') --git-dir <path>, space spacing form.
code="$(run_hook "$S/main" "git --git-dir $GITDIR commit -m x")"
[ "$code" = "2" ] && pass "git --git-dir <path> commit (space form) → blocked (exit 2)" \
                   || fail "git --git-dir <path> commit (space form) expected exit 2, got $code"

# (c) --work-tree=..., "=" spacing form.
code="$(run_hook "$S/main" "git --work-tree=$WT commit -m x")"
[ "$code" = "2" ] && pass "git --work-tree=<path> commit → blocked (exit 2)" \
                   || fail "git --work-tree=<path> commit expected exit 2, got $code"

# (c') --work-tree <path>, space spacing form.
code="$(run_hook "$S/main" "git --work-tree $WT commit -m x")"
[ "$code" = "2" ] && pass "git --work-tree <path> commit (space form) → blocked (exit 2)" \
                   || fail "git --work-tree <path> commit (space form) expected exit 2, got $code"

# (d) --no-verify.
code="$(run_hook "$S/main" "git commit --no-verify -m x")"
[ "$code" = "2" ] && pass "git commit --no-verify → blocked (exit 2)" \
                   || fail "git commit --no-verify expected exit 2, got $code"

# --- block is logged as a gate-bypass signature -----------------------------
# Re-run one representative bypass (git-dir, "=" form) with a fresh log
# dir and assert the JSONL entry log_decision writes on the block path:
# hook=safe-commit, action=block, message mentions "gate-bypass signature".
LOGDIR="$TMP/logs-bypass"
mkdir -p "$LOGDIR"
payload="$(jq -cn --arg c "git --git-dir=$GITDIR commit -m x" '{tool_name:"Bash", tool_input:{command:$c}}')"
(
  cd "$S/main" || exit 99
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  CLAUDE_PROJECT_DIR="$LOGDIR" \
    bash "$HOOK" <<<"$payload" >/dev/null 2>&1
)
logfile="$LOGDIR/.task-log/hook-decisions.jsonl"
if [ -f "$logfile" ] && jq -e '
      select(.hook == "safe-commit"
             and .action == "block"
             and (.message | test("gate-bypass signature")))
    ' "$logfile" >/dev/null 2>&1; then
  pass "blocked bypass is logged (hook=safe-commit action=block message~=gate-bypass signature)"
else
  fail "expected a logged block entry with 'gate-bypass signature' in $logfile, got: $(cat "$logfile" 2>/dev/null || echo '<no file>')"
fi

# --- block message is also surfaced on stderr (belt-and-braces) -----------
stderr="$(run_hook_stderr "$S/main" "git --git-dir=$GITDIR commit -m x")"
echo "$stderr" | grep -q 'gate-bypass attempt refused' \
  && pass "blocked bypass reports 'gate-bypass attempt refused' on stderr" \
  || fail "expected 'gate-bypass attempt refused' on stderr, got: $(echo "$stderr" | tr '\n' ' ')"

# === 3. Legitimate flows still pass (guard against over-blocking) =========

# (a) Operator out-of-band escape hatch: ATELIER_SKIP_SAFE_COMMIT=1 set in
# the hook's ENVIRONMENT (not inside the command string) with a plain
# `git commit` → exit 0.
code="$(run_hook_env_skip "$S/main" "git commit -m x")"
[ "$code" = "0" ] && pass "ATELIER_SKIP_SAFE_COMMIT=1 in environment (plain git commit) → allowed (exit 0)" \
                   || fail "env-var escape hatch expected exit 0, got $code"

# (b) Plain green `git commit -m ...` in the main repo (gate would pass).
code="$(run_hook "$S/main" "git commit -m x")"
[ "$code" = "0" ] && pass "plain green git commit → allowed (exit 0)" \
                   || fail "plain green git commit expected exit 0, got $code"

# (c) Legitimate `git -C <worktree> commit -m ...` (M7.1.F57 target-worktree
# form, no bypass flags) → still allowed, not refused as a bypass.
code="$(run_hook "$S/main" "git -C $WT commit -m x")"
[ "$code" = "0" ] && pass "git -C <worktree> commit (no bypass flags) → allowed (exit 0)" \
                   || fail "git -C <worktree> commit expected exit 0, got $code"

echo
if [ "$fails" -eq 0 ]; then
  echo "All #277 gate-bypass regression checks passed."
  exit 0
else
  echo "$fails #277 gate-bypass regression check(s) FAILED."
  exit 1
fi
