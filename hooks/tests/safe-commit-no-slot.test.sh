#!/usr/bin/env bash
#
# Regression test for #586 — hooks/safe-commit.sh runs the commit gate with NO
# CPU slot. The gate used to wait on the machine-wide slot
# (scripts/atelier-cpu-slot) and could block a commit with `BLOCKED — CPU`;
# that whole path is gone. This test pins:
#   - a green gate commits (exit 0, push-gate-green logged);
#   - a red gate blocks with the normal `🚫 atelier:safe-commit BLOCKED`;
#   - a foreign live holder in the old lock dir neither blocks nor delays the
#     commit, and its lock is left untouched;
#   - no `BLOCKED — CPU` output and no `cpu-slot-*` decision log, even with a
#     fake high load;
#   - the same results with `atelier-cpu-slot` absent from the plugin root and
#     from PATH;
#   - the #277 bypass refusals are unchanged.
#
# Hermetic: throwaway git repos under a temp dir, a shimmed `pnpm` on PATH, and
# every config dir pinned to a temp dir (the operator's real
# ~/.claude-work/cpu-slot.json is never read). Every wait on the hook is
# bounded; background processes the test starts are killed on exit.
# Portable to GNU/Linux and macOS/BSD.
#
# Run:  hooks/tests/safe-commit-no-slot.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2015,SC2016,SC2329 # `A && pass || fail` idiom; literal $ in fixture scripts; trap-invoked cleanup
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/safe-commit.sh"

TMP="$(mktemp -d)"
BG_PIDS=""
cleanup() {
  local p
  for p in $BG_PIDS; do
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# Nothing from the surrounding session may leak in.
unset CPU_SLOT_HELD CPU_SLOT_LABEL
export HOME="$TMP/home"; mkdir -p "$HOME"
export ATELIER_CONFIG_DIR="$TMP/config"; mkdir -p "$ATELIER_CONFIG_DIR"
export CLAUDE_CONFIG_DIR="$TMP/config"

# --- shim and plugin roots ----------------------------------------------------
SHIM_BIN="$TMP/bin"
mkdir -p "$SHIM_BIN"
cat > "$SHIM_BIN/pnpm" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "run" ]; then
  script="$(jq -r --arg s "$2" '.scripts[$s] // empty' package.json 2>/dev/null)"
  [ -z "$script" ] && { echo "no script: $2" >&2; exit 1; }
  exec sh -c "$script"
fi
exit 0
SHIM
chmod +x "$SHIM_BIN/pnpm"
export PATH="$SHIM_BIN:$PATH"

# The old slot lock dir (what a foreign holder would occupy).
CPU_SLOT_DIR="$TMP/cpu-slot"; mkdir -p "$CPU_SLOT_DIR"; export CPU_SLOT_DIR
LOCK="$CPU_SLOT_DIR/cpu-slot.lock"

# Plugin root: ROOT_NOHELP has
# only hooks/lib (no scripts/atelier-cpu-slot at all).
ROOT_NOHELP="$TMP/root-nohelp"; mkdir -p "$ROOT_NOHELP/hooks"
ln -s "$REPO_ROOT/hooks/lib" "$ROOT_NOHELP/hooks/lib"

# A PATH with no atelier-cpu-slot anywhere (the shim dir plus system dirs).
NOSLOT_PATH="$SHIM_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
for d in $(dirname "$(command -v jq)") $(dirname "$(command -v git)"); do
  case ":$NOSLOT_PATH:" in *":$d:"*) ;; *) NOSLOT_PATH="$NOSLOT_PATH:$d" ;; esac
done
if PATH="$NOSLOT_PATH" command -v atelier-cpu-slot > /dev/null 2>&1; then
  # The host has it in a system dir; drop to a minimal PATH of symlinks.
  MIN="$TMP/minbin"; mkdir -p "$MIN"
  for t in bash sh jq git sed awk grep cat date mkdir rm sleep tr head tail cut sort wc dirname basename env mktemp printf uname ps kill touch ls mv cp tee xargs find readlink id; do
    p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "$MIN/$t"
  done
  NOSLOT_PATH="$SHIM_BIN:$MIN"
fi

# --- helpers --------------------------------------------------------------------
LOG_ROOT="$TMP/logs"
LOG_FILE="$LOG_ROOT/.task-log/hook-decisions.jsonl"
OUT="$TMP/hook.out"
ERR="$TMP/hook.err"
PAYLOAD="$TMP/payload.json"
RC=""

# run_hook <cwd> <command> [VAR=val ...] — bounded (20 s) run of the hook.
# PLUGIN_ROOT (default: the real repo) selects CLAUDE_PLUGIN_ROOT; HOOK_PATH
# (default: current PATH) selects PATH.
run_hook() {
  local pwd_dir="$1" command_str="$2" pid i=0
  shift 2
  rm -rf "$LOG_ROOT"; rm -f "$OUT" "$ERR"
  jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}' > "$PAYLOAD"
  (
    cd "$pwd_dir" || exit 99
    exec env CLAUDE_PLUGIN_ROOT="${PLUGIN_ROOT:-$REPO_ROOT}" PATH="${HOOK_PATH:-$PATH}" \
      CLAUDE_PROJECT_DIR="$LOG_ROOT" "$@" \
      bash "$HOOK" < "$PAYLOAD" > "$OUT" 2> "$ERR"
  ) &
  pid=$!
  BG_PIDS="$BG_PIDS $pid"
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    RC=124
  else
    wait "$pid" 2>/dev/null
    RC=$?
  fi
}

make_project() {
  local dir="$1" body="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  printf '%s\n' "$body" > "$dir/package.json"
  : > "$dir/pnpm-lock.yaml"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
}

stage_feature() {
  printf 'console.log(1)\n' > "$1/feature.js"
  git -C "$1" add -A
}

log_has() { grep -q "\"pattern\":\"$1\"" "$LOG_FILE" 2>/dev/null; }
no_cpu_artifacts() { # <label>
  grep -q 'BLOCKED — CPU' "$ERR" "$OUT" 2>/dev/null \
    && fail "$1: output carries 'BLOCKED — CPU'" || pass "$1: no 'BLOCKED — CPU' output"
  grep -q 'cpu-slot' "$LOG_FILE" 2>/dev/null \
    && fail "$1: a cpu-slot-* decision was logged" || pass "$1: no cpu-slot-* decision log"
}

GREEN_PKG='{ "name": "f", "version": "0.0.0", "scripts": { "lint": "echo l >> ran.txt", "typecheck": "echo t >> ran.txt", "test": "echo s >> ran.txt" } }'
RED_PKG='{ "name": "f", "version": "0.0.0", "scripts": { "test": "exit 1" } }'
EXP_RAN="$(printf 'l\nt\ns')"

echo "#586 regression — safe-commit runs the gate with no CPU slot"

# === 1: green gate commits ====================================================
P1="$TMP/p1"; make_project "$P1" "$GREEN_PKG"; stage_feature "$P1"
run_hook "$P1" "git commit -m x"
[ "$RC" = "0" ] && pass "green gate → exit 0" || fail "green gate: expected exit 0, got $RC ($(cat "$ERR"))"
[ "$(cat "$P1/ran.txt" 2>/dev/null)" = "$EXP_RAN" ] \
  && pass "lint, typecheck and test all ran in order" || fail "steps ran: '$(tr '\n' ' ' < "$P1/ran.txt" 2>/dev/null)'"
log_has "push-gate-green" && pass "green logged push-gate-green" || fail "no push-gate-green log"
no_cpu_artifacts "green"
[ ! -e "$LOCK" ] && pass "green: no slot lock created" || fail "green: lock dir appeared"

# === 2: red gate blocks normally ==============================================
P2="$TMP/p2"; make_project "$P2" "$RED_PKG"; stage_feature "$P2"
run_hook "$P2" "git commit -m x"
[ "$RC" = "2" ] && pass "red gate → exit 2" || fail "red gate: expected exit 2, got $RC"
grep -q '🚫 atelier:safe-commit BLOCKED' "$ERR" \
  && pass "red gate: stderr carries '🚫 atelier:safe-commit BLOCKED'" || fail "red gate: no BLOCKED banner: $(cat "$ERR")"
no_cpu_artifacts "red"

# === 3: foreign live holder neither blocks nor delays =========================
P3="$TMP/p3"; make_project "$P3" "$GREEN_PKG"
printf '{ "safeCommit": { "slotMaxWait": 60 } }\n' > "$P3/.atelier.json"
stage_feature "$P3"
sleep 120 & HOLDER=$!; BG_PIDS="$BG_PIDS $HOLDER"
mkdir "$LOCK"; echo "$HOLDER" > "$LOCK/pid"; echo "holder-x" > "$LOCK/label"; date '+%H:%M:%S' > "$LOCK/since"
SECONDS=0
run_hook "$P3" "git commit -m x" CPU_SLOT_FAKE_LOAD=50 CPU_SLOT_FAKE_CORES=4
elapsed=$SECONDS
[ "$RC" = "0" ] && pass "live foreign holder + load 50/4 cores → exit 0 (not blocked)" || fail "foreign holder: expected exit 0, got $RC ($(cat "$ERR"))"
[ "$elapsed" -lt 10 ] && pass "commit not delayed (${elapsed}s < 10s, old slotMaxWait was 60)" || fail "commit took ${elapsed}s"
[ "$(cat "$P3/ran.txt" 2>/dev/null)" = "$EXP_RAN" ] && pass "foreign holder: the gate steps ran" || fail "foreign holder: steps did not run"
no_cpu_artifacts "foreign holder"
[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$HOLDER" ] && pass "foreign holder's lock left untouched" || fail "foreign lock changed: '$(cat "$LOCK/pid" 2>/dev/null)'"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
rm -rf "$LOCK"

# === 4: atelier-cpu-slot absent from plugin root and PATH =====================
P4="$TMP/p4"; make_project "$P4" "$GREEN_PKG"; stage_feature "$P4"
PLUGIN_ROOT="$ROOT_NOHELP" HOOK_PATH="$NOSLOT_PATH" run_hook "$P4" "git commit -m x"
[ "$RC" = "0" ] && [ "$(cat "$P4/ran.txt" 2>/dev/null)" = "$EXP_RAN" ] \
  && pass "helper absent: green gate → exit 0, steps ran" || fail "helper absent green: exit $RC ($(cat "$ERR"))"
log_has "push-gate-green" && pass "helper absent: push-gate-green logged" || fail "helper absent: no push-gate-green log"
no_cpu_artifacts "helper absent green"

P4R="$TMP/p4r"; make_project "$P4R" "$RED_PKG"; stage_feature "$P4R"
PLUGIN_ROOT="$ROOT_NOHELP" HOOK_PATH="$NOSLOT_PATH" run_hook "$P4R" "git commit -m x"
[ "$RC" = "2" ] && grep -q '🚫 atelier:safe-commit BLOCKED' "$ERR" \
  && pass "helper absent: red gate → exit 2 with the normal BLOCKED banner" || fail "helper absent red: exit $RC ($(cat "$ERR"))"
no_cpu_artifacts "helper absent red"

# === 5: N/A paths and #277 bypass refusals unchanged ==========================
run_hook "$P1" "git commit -m x" ATELIER_SKIP_SAFE_COMMIT=1
[ "$RC" = "0" ] && pass "skip env → exit 0" || fail "skip env: exit $RC"
run_hook "$P1" "git status"
[ "$RC" = "0" ] && pass "non-commit command → exit 0" || fail "non-commit: exit $RC"
run_hook "$P1" "ATELIER_SKIP_SAFE_COMMIT=1 git commit -m x"
[ "$RC" = "2" ] && log_has "bypass-attempt" \
  && pass "inline bypass refused (exit 2, bypass-attempt logged)" \
  || fail "inline bypass: expected exit 2 + bypass-attempt log, got $RC"
no_cpu_artifacts "inline bypass"

echo
if [ "$fails" -eq 0 ]; then
  echo "safe-commit-no-slot: all assertions passed"
  exit 0
fi
echo "safe-commit-no-slot: $fails assertion(s) failed"
exit 1
