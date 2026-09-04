#!/usr/bin/env bash
#
# Regression test for #196a — block-cross-worktree-edit.sh must
# categorically deny a session from editing a sibling task's worktree
# while it already owns a DIFFERENT worktree of the same repository, and
# must NEVER deny a session that owns nothing (or that only owns worktrees
# in a different repository). It must also fail open on every degraded
# path (missing jq, unwritable $ATELIER_CONFIG_DIR, no working `stat`,
# target not inside any git worktree).
#
# Hermetic: drives hooks/block-cross-worktree-edit.sh directly with
# crafted stdin JSON against real throwaway git repos + `git worktree add`
# checkouts under a temp dir. No network. Requires `git` and `jq` (the
# hook's own dependencies).
#
# Run:  hooks/tests/block-cross-worktree-edit.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-cross-worktree-edit.sh"
BASH_BIN="$(command -v bash)"

TMP="$(mktemp -d)"
# Canonicalise: macOS `mktemp -d` returns a path under /var/folders/**,
# which is itself a symlink to /private/var/folders/**. The hook
# canonicalises every target path with `pwd -P` before deriving a
# worktree/container id, so this test's own key computations (which
# re-derive the same ids to assert on-disk ownership state directly) must
# start from the same physical path or they'll compute a different key
# than the hook did.
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

CFG="$TMP/atelier-config"
mkdir -p "$CFG"

# --- helpers -----------------------------------------------------------

mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "test"
  printf 'hi\n' > "$dir/f.txt"
  git -C "$dir" add f.txt
  git -C "$dir" commit -q -m init
}

mk_worktree() {
  local repo="$1" branch="$2" wtpath="$3"
  git -C "$repo" worktree add -q -b "$branch" "$wtpath" >/dev/null 2>&1
}

# Run the hook as Claude Code would: payload = an Edit/Write/MultiEdit/
# NotebookEdit tool call against $file_path. $token drives
# CLAUDE_CODE_BRIDGE_SESSION_ID — this hook's primary session-token
# source (see the hook's own header comment for why). Echoes the exit
# code; hook stderr is captured to $TMP/last_stderr for message
# assertions.
run_hook() {
  local tool="$1" file_path="$2" token="$3" custom_path="${4:-}"
  local field payload rc
  field="file_path"
  [ "$tool" = "NotebookEdit" ] && field="notebook_path"
  payload="$(jq -cn --arg t "$tool" --arg f "$file_path" --arg field "$field" \
    '{tool_name:$t, tool_input: ({} | .[$field]=$f), session_id:("sess-"+$t), transcript_path:("/tmp/does-not-exist-"+$t+".jsonl")}')"
  (
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
    export CLAUDE_PROJECT_DIR="$TMP/logs"
    export ATELIER_CONFIG_DIR="$CFG"
    export CLAUDE_CODE_BRIDGE_SESSION_ID="$token"
    if [ -n "$custom_path" ]; then
      export PATH="$custom_path"
    fi
    "$BASH_BIN" "$HOOK" <<<"$payload" >"$TMP/last_stdout" 2>"$TMP/last_stderr"
  )
  rc=$?
  echo "$rc"
}

assert_block() {
  local desc="$1" tool="$2" file_path="$3" token="$4"
  local code
  code="$(run_hook "$tool" "$file_path" "$token")"
  [ "$code" = "2" ] && pass "$desc → blocked (exit 2)" \
                     || fail "$desc expected exit 2, got $code (stderr: $(cat "$TMP/last_stderr" 2>/dev/null))"
}

assert_allow() {
  local desc="$1" tool="$2" file_path="$3" token="$4" custom_path="${5:-}"
  local code
  code="$(run_hook "$tool" "$file_path" "$token" "$custom_path")"
  [ "$code" = "0" ] && pass "$desc → allowed (exit 0)" \
                     || fail "$desc expected exit 0, got $code (stderr: $(cat "$TMP/last_stderr" 2>/dev/null))"
}

assert_stderr_contains() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$TMP/last_stderr" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc — stderr was: $(cat "$TMP/last_stderr" 2>/dev/null)"
  fi
}

echo "#196a regression — block-cross-worktree-edit categorical worktree-isolation guard"

# =============================================================================
# SECTION A — baseline ownership rules within one repo (one "container")
# =============================================================================
echo
echo "-- section A: baseline self-claim / same-owner / foreign-but-caller-owns-nothing --"

REPO1="$TMP/repo1"
mk_repo "$REPO1"
WT_A="$TMP/repo1-wt-a"
WT_B="$TMP/repo1-wt-b"
WT_D="$TMP/repo1-wt-d"
mk_worktree "$REPO1" "task/a" "$WT_A"
mk_worktree "$REPO1" "task/b" "$WT_B"
mk_worktree "$REPO1" "task/d" "$WT_D"

# 1. Fresh token, unclaimed worktree A → self-claims, allowed.
assert_allow "token A first write into worktree A (unclaimed)" "Write" "$WT_A/new.txt" "token-A"

# 2. Same token writes into the same worktree again → still allowed.
assert_allow "token A writes into worktree A again (already owner)" "Edit" "$WT_A/f.txt" "token-A"

# 3. Different token (B), worktree A already owned fresh by A, but B owns
#    nothing else yet → allowed (never denied when the caller owns nothing).
assert_allow "token B writes into worktree A (B owns nothing else)" "Write" "$WT_A/other.txt" "token-B"

# Worktree A's ownership must still be token-A after (3) — B's allowed
# pass-through must NOT reassign ownership.
container_common="$(cd "$REPO1" && git rev-parse --git-common-dir)"
case "$container_common" in
  /*) : ;;
  *) container_common="$(cd "$REPO1" && cd "$container_common" && pwd -P)" ;;
esac
enc() { printf '%s' "$1" | cksum | tr -s ' ' '-'; }
key_a="$(enc "$container_common")--$(enc "$WT_A")"
owner_token_a="$(cat "$CFG/state/worktree-owner/$key_a/token" 2>/dev/null || true)"
if [ "$owner_token_a" = "token-A" ]; then
  pass "worktree A ownership still token-A after B's pass-through edit"
else
  fail "worktree A ownership changed unexpectedly (now: $owner_token_a)"
fi

# 4. Token A writes into worktree B (unclaimed) → self-claims B too. A now
#    owns two worktrees (A and B) in this container.
assert_allow "token A first write into worktree B (unclaimed)" "Write" "$WT_B/new.txt" "token-A"

# 5. Token C self-claims worktree D (unclaimed).
assert_allow "token C first write into worktree D (unclaimed)" "Write" "$WT_D/new.txt" "token-C"

# 6. Token A (owns A and B) writes into worktree D (owned fresh by C) →
#    denied — A already owns a different worktree in this same container.
assert_block "token A writes into worktree D (C's, A owns A+B) → cross-worktree deny" \
  "Write" "$WT_D/blocked.txt" "token-A"

# 7. Token E (owns nothing at all) writes into worktree D (owned fresh by
#    C) → allowed — E owns nothing else, so it is never denied.
assert_allow "token E (owns nothing) writes into worktree D (C's)" "Write" "$WT_D/e.txt" "token-E"

# =============================================================================
# SECTION B — cross-container non-interference
# =============================================================================
echo
echo "-- section B: ownership in one repo must not deny edits in a different repo --"

REPO2="$TMP/repo2"
mk_repo "$REPO2"
WT_Z="$TMP/repo2-wt-z"
mk_worktree "$REPO2" "task/z" "$WT_Z"

# Token G self-claims worktree Z in repo2 (fresh, foreign to token-A).
assert_allow "token G first write into worktree Z (repo2, unclaimed)" "Write" "$WT_Z/new.txt" "token-G"

# Token A owns worktree A + B in repo1 only — nothing in repo2 — so its
# write into worktree Z (repo2, owned fresh by G) must still be allowed:
# the "caller already owns a different worktree" condition is scoped to
# the SAME container.
assert_allow "token A (owns only repo1 worktrees) writes into worktree Z (repo2, G's)" \
  "Write" "$WT_Z/cross-container.txt" "token-A"

# =============================================================================
# SECTION C — stale reclaim
# =============================================================================
echo
echo "-- section C: a stale (expired ownerTtlSeconds) claim is reclaimed, not denied --"

REPO3="$TMP/repo3"
mk_repo "$REPO3"
WT_S="$TMP/repo3-wt-s"
mk_worktree "$REPO3" "task/s" "$WT_S"
printf '{"ownerTtlSeconds": 1}\n' > "$WT_S/.atelier.json"

# Token H claims worktree S first.
assert_allow "token H first write into worktree S (ttl=1s)" "Write" "$WT_S/new.txt" "token-H"

# Backdate the claim's token-file mtime far into the past so it reads as
# stale regardless of how fast this test runs. `touch -t` is POSIX/BSD
# and GNU compatible (unlike `-d`), matching the hook's own portability
# constraints.
container3_common="$(cd "$REPO3" && git rev-parse --git-common-dir)"
case "$container3_common" in
  /*) : ;;
  *) container3_common="$(cd "$REPO3" && cd "$container3_common" && pwd -P)" ;;
esac
key_s="$(enc "$container3_common")--$(enc "$WT_S")"
touch -t 202001010000 "$CFG/state/worktree-owner/$key_s/token" 2>/dev/null

# Token I (foreign) writes into worktree S → the stale claim is reclaimed
# atomically (mv -> rm -rf -> mkdir), never denied.
assert_allow "token I writes into worktree S (H's claim is stale) → reclaimed" \
  "Write" "$WT_S/reclaimed.txt" "token-I"

new_owner_s="$(cat "$CFG/state/worktree-owner/$key_s/token" 2>/dev/null || true)"
if [ "$new_owner_s" = "token-I" ]; then
  pass "worktree S ownership transferred to token-I after stale reclaim"
else
  fail "worktree S ownership did not transfer as expected (now: $new_owner_s)"
fi

# =============================================================================
# SECTION D — race: claim dir exists, token file not written yet
# =============================================================================
echo
echo "-- section D: an in-flight claim (dir exists, no token file) is never a foreign owner --"

REPO4="$TMP/repo4"
mk_repo "$REPO4"
WT_R="$TMP/repo4-wt-r"
mk_worktree "$REPO4" "task/r" "$WT_R"

container4_common="$(cd "$REPO4" && git rev-parse --git-common-dir)"
case "$container4_common" in
  /*) : ;;
  *) container4_common="$(cd "$REPO4" && cd "$container4_common" && pwd -P)" ;;
esac
key_r="$(enc "$container4_common")--$(enc "$WT_R")"
mkdir -p "$CFG/state/worktree-owner/$key_r" # claim dir exists, no token file yet

assert_allow "token J writes into worktree R (claim dir exists, no token file)" \
  "Write" "$WT_R/racer.txt" "token-J"

# =============================================================================
# SECTION E — main-checkout edits (unblocker Step 5 / task-orchestrator
# Step 8) must still pass the hook
# =============================================================================
echo
echo "-- section E: main-checkout edit alongside an owned task worktree --"

REPO5="$TMP/repo5"
mk_repo "$REPO5"
WT_TASK="$TMP/repo5-wt-task"
mk_worktree "$REPO5" "task/196a-sim" "$WT_TASK"

# Token K owns the task worktree (as implementer/tester would over the
# course of a chain).
assert_allow "token K writes into its own task worktree" "Edit" "$WT_TASK/f.txt" "token-K"

# unblocker Step 5 / task-orchestrator Step 8 edit ROADMAP.md/IN_PROGRESS.md
# on the MAIN checkout (REPO5 itself) — a different worktree of the same
# container, currently unclaimed — must still be allowed.
assert_allow "token K (owns task worktree) writes into the main checkout (unclaimed)" \
  "Edit" "$REPO5/IN_PROGRESS.md" "token-K"

# =============================================================================
# SECTION F — tool-name matcher coverage
# =============================================================================
echo
echo "-- section F: matcher coverage (Edit/Write/MultiEdit/NotebookEdit vs everything else) --"

REPO6="$TMP/repo6"
mk_repo "$REPO6"
WT_M="$TMP/repo6-wt-m"
mk_worktree "$REPO6" "task/m" "$WT_M"

assert_allow "MultiEdit into a fresh worktree self-claims" "MultiEdit" "$WT_M/multi.txt" "token-M1"
assert_allow "NotebookEdit into a fresh worktree self-claims" "NotebookEdit" "$WT_M/nb.ipynb" "token-M1"

WT_N="$TMP/repo6-wt-n"
mk_worktree "$REPO6" "task/n" "$WT_N"
assert_allow "token M2 self-claims worktree N" "Write" "$WT_N/new.txt" "token-M2"
assert_block "MultiEdit cross-worktree (M1 owns M, writes into N owned by M2)" \
  "MultiEdit" "$WT_N/blocked.txt" "token-M1"

# A non-matching tool (Bash) must never be evaluated by this hook at all,
# regardless of ownership state — always exit 0.
code="$(
  payload="$(jq -cn '{tool_name:"Bash", tool_input:{command:"ls"}}')"
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
  CLAUDE_CODE_BRIDGE_SESSION_ID="token-M1" \
    "$BASH_BIN" "$HOOK" <<<"$payload" >/dev/null 2>&1
  echo $?
)"
[ "$code" = "0" ] && pass "Bash tool call is never evaluated (exit 0)" \
                   || fail "Bash tool call expected exit 0, got $code"

# =============================================================================
# SECTION G — degraded paths: every one exits 0 with a warning
# =============================================================================
echo
echo "-- section G: fail-open degraded paths --"

REPO7="$TMP/repo7"
mk_repo "$REPO7"
WT_G1="$TMP/repo7-wt-g1"
mk_worktree "$REPO7" "task/g1" "$WT_G1"

# G1. jq missing.
BIN_NO_JQ="$TMP/bin-no-jq"
mkdir -p "$BIN_NO_JQ"
for b in git cksum stat date mkdir rm mv dirname cat tr basename sed awk grep head bash env; do
  src="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$BIN_NO_JQ/$b"
done
assert_allow "jq missing → degrades to allow" "Write" "$WT_G1/new.txt" "token-G1" "$BIN_NO_JQ"
assert_stderr_contains "jq-missing degrade warns on stderr" "jq missing"

# G2. $ATELIER_CONFIG_DIR unwritable (parent is a regular file, not a dir).
BLOCKER_FILE="$TMP/not-a-dir"
: > "$BLOCKER_FILE"
BAD_CFG="$BLOCKER_FILE/sub"
code="$(
  payload="$(jq -cn --arg f "$WT_G1/other.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$BAD_CFG" \
  CLAUDE_CODE_BRIDGE_SESSION_ID="token-G2" \
    "$BASH_BIN" "$HOOK" <<<"$payload" >"$TMP/last_stdout" 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code" = "0" ] && pass "unwritable \$ATELIER_CONFIG_DIR → degrades to allow" \
                   || fail "unwritable \$ATELIER_CONFIG_DIR expected exit 0, got $code"
assert_stderr_contains "unwritable-config-dir degrade warns on stderr" "unwritable"

# G3. No working `stat` — needs an existing FOREIGN FRESH claim so the
# hook actually reaches the stat call.
WT_G3="$TMP/repo7-wt-g3"
mk_worktree "$REPO7" "task/g3" "$WT_G3"
assert_allow "token G3-owner claims worktree G3 first" "Write" "$WT_G3/new.txt" "token-G3-owner"

BIN_NO_STAT="$TMP/bin-no-stat"
mkdir -p "$BIN_NO_STAT"
for b in jq git cksum date mkdir rm mv dirname cat tr basename sed awk grep head bash env; do
  src="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$BIN_NO_STAT/$b"
done
cat > "$BIN_NO_STAT/stat" <<'STATEOF'
#!/bin/sh
exit 1
STATEOF
chmod +x "$BIN_NO_STAT/stat"

assert_allow "no working stat (foreign fresh claim) → degrades to allow" \
  "Write" "$WT_G3/foreign.txt" "token-G3-other" "$BIN_NO_STAT"
assert_stderr_contains "no-working-stat degrade warns on stderr" "stat"

# G4. Target worktree gone — not inside any git worktree at all.
NO_REPO_DIR="$TMP/no-repo-here"
mkdir -p "$NO_REPO_DIR"
code="$(
  payload="$(jq -cn --arg f "$NO_REPO_DIR/f.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
  CLAUDE_CODE_BRIDGE_SESSION_ID="token-G4" \
    "$BASH_BIN" "$HOOK" <<<"$payload" >"$TMP/last_stdout" 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code" = "0" ] && pass "target outside any git worktree → degrades to allow" \
                   || fail "target outside any git worktree expected exit 0, got $code"
assert_stderr_contains "worktree-gone degrade warns on stderr" "worktree gone"

# --- shared helper for the sections below -------------------------------

# Container id (git-common-dir, canonicalised) for a repo, matching the
# hook's own resolution exactly (relative git-common-dir joined onto the
# worktree it was resolved from, then canonicalised).
container_dir_of() {
  local repo="$1" c
  c="$(cd "$repo" && git rev-parse --git-common-dir)"
  case "$c" in
    /*) : ;;
    *) c="$(cd "$repo" && cd "$c" && pwd -P)" ;;
  esac
  printf '%s' "$c"
}

# Set a file's mtime to now-minus-N-seconds, portably (BSD `date -r`, then
# GNU `date -d @epoch`) — mirrors the hook's own BSD-then-GNU fallback
# style for `stat`. Never uses a fixed calendar date, since these tests
# need mtimes anchored close to "now" to exercise the TTL boundary.
touch_age() {
  local file="$1" age="$2" now target ts
  now="$(date +%s)"
  target=$((now - age))
  ts="$(date -r "$target" +%Y%m%d%H%M.%S 2>/dev/null)" || \
    ts="$(date -d "@$target" +%Y%m%d%H%M.%S 2>/dev/null)"
  [ -n "$ts" ] && touch -t "$ts" "$file" 2>/dev/null
}

# =============================================================================
# SECTION H — TTL boundary: just-inside (fresh, still denies) vs
# just-outside (stale, reclaimed) the SAME ownerTtlSeconds window, plus the
# TTL being read from the correct worktree's OWN .atelier.json.
# =============================================================================
echo
echo "-- section H: TTL boundary (just-inside vs just-outside) + correct .atelier.json source --"

REPO8="$TMP/repo8"
mk_repo "$REPO8"
WT8_CALLER="$TMP/repo8-wt-caller"
WT8_TARGET="$TMP/repo8-wt-target"
mk_worktree "$REPO8" "task/8-caller" "$WT8_CALLER"
mk_worktree "$REPO8" "task/8-target" "$WT8_TARGET"
printf '{"ownerTtlSeconds": 30}\n' > "$WT8_TARGET/.atelier.json"

# Token L8 owns a different worktree in the same container.
assert_allow "token L8 claims WT8_CALLER (owns something in this container)" \
  "Write" "$WT8_CALLER/new.txt" "token-L8"
# Token F8 claims the ttl=30 worktree.
assert_allow "token F8 claims WT8_TARGET (ttl=30)" "Write" "$WT8_TARGET/new.txt" "token-F8"

key8="$(enc "$(container_dir_of "$REPO8")")--$(enc "$WT8_TARGET")"
tokfile8="$CFG/state/worktree-owner/$key8/token"

# Just inside the window: age 27s < ttl 30s (margin 3s to absorb exec
# jitter between setting the mtime and the hook computing `now`) — still
# fresh, so L8 (who owns a different worktree here) is denied.
touch_age "$tokfile8" 27
assert_block "L8 writes into WT8_TARGET while F8's claim is fresh (age 27s < ttl 30s)" \
  "Write" "$WT8_TARGET/blocked-fresh.txt" "token-L8"

# Just outside the window: age 33s >= ttl 30s (same 3s margin) — now
# stale, reclaimed rather than denied.
touch_age "$tokfile8" 33
assert_allow "L8 writes into WT8_TARGET once F8's claim ages past ttl (age 33s >= ttl 30s) → reclaimed" \
  "Write" "$WT8_TARGET/reclaimed.txt" "token-L8"
owner8="$(cat "$tokfile8" 2>/dev/null || true)"
if [ "$owner8" = "token-L8" ]; then
  pass "WT8_TARGET ownership transferred to token-L8 after crossing the ttl boundary"
else
  fail "WT8_TARGET ownership did not transfer at the ttl boundary (now: $owner8)"
fi

# --- ttl is read from the TARGET's own .atelier.json, never a decoy at
#     the hook process's cwd ------------------------------------------------

REPO9="$TMP/repo9"
mk_repo "$REPO9"
WT9_CALLER="$TMP/repo9-wt-caller"
WT9_TARGET="$TMP/repo9-wt-target"
mk_worktree "$REPO9" "task/9-caller" "$WT9_CALLER"
mk_worktree "$REPO9" "task/9-target" "$WT9_TARGET"
printf '{"ownerTtlSeconds": 30}\n' > "$WT9_TARGET/.atelier.json"

DECOY_CWD="$TMP/decoy-cwd"
mkdir -p "$DECOY_CWD"
printf '{"ownerTtlSeconds": 1}\n' > "$DECOY_CWD/.atelier.json"

assert_allow "token L9 claims WT9_CALLER" "Write" "$WT9_CALLER/new.txt" "token-L9"
assert_allow "token F9 claims WT9_TARGET (ttl=30)" "Write" "$WT9_TARGET/new.txt" "token-F9"

key9="$(enc "$(container_dir_of "$REPO9")")--$(enc "$WT9_TARGET")"
tokfile9="$CFG/state/worktree-owner/$key9/token"
# age 10s: fresh under the TARGET's real ttl=30, but would read as stale
# (10 >= 1) if the hook ever mistakenly consulted a decoy .atelier.json at
# its own cwd instead of the target worktree's.
touch_age "$tokfile9" 10

payload9="$(jq -cn --arg f "$WT9_TARGET/blocked.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
code9="$(
  cd "$DECOY_CWD" && \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
  CLAUDE_CODE_BRIDGE_SESSION_ID="token-L9" \
    "$BASH_BIN" "$HOOK" <<<"$payload9" >"$TMP/last_stdout" 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code9" = "2" ] && pass "ttl read from WT9_TARGET's own .atelier.json, not the hook's cwd (blocked as fresh)" \
                    || fail "expected exit 2 (target's own ttl=30 makes age=10 fresh), got $code9 — decoy cwd .atelier.json may have leaked in"

# --- candidate (the caller's OTHER owned worktree) freshness is judged by
#     THAT worktree's own ttl, not the target's or a hardcoded default ----

REPO10="$TMP/repo10"
mk_repo "$REPO10"
WT10_OTHER="$TMP/repo10-wt-other"   # caller's other claim; short ttl, goes stale fast
WT10_TARGET="$TMP/repo10-wt-target" # default ttl; freshly foreign-owned
mk_worktree "$REPO10" "task/10-other" "$WT10_OTHER"
mk_worktree "$REPO10" "task/10-target" "$WT10_TARGET"
printf '{"ownerTtlSeconds": 1}\n' > "$WT10_OTHER/.atelier.json"

assert_allow "token L10 claims WT10_OTHER (ttl=1)" "Write" "$WT10_OTHER/new.txt" "token-L10"
key10_other="$(enc "$(container_dir_of "$REPO10")")--$(enc "$WT10_OTHER")"
touch_age "$CFG/state/worktree-owner/$key10_other/token" 50 # 50s >= its own ttl=1 → L10's OTHER claim is itself stale now

assert_allow "token F10 claims WT10_TARGET (default ttl, fresh)" "Write" "$WT10_TARGET/new.txt" "token-F10"

assert_allow "L10 writes into WT10_TARGET (F10's, fresh) — allowed because L10's own OTHER claim (WT10_OTHER) is stale per ITS OWN ttl=1, not freshly owned anymore" \
  "Write" "$WT10_TARGET/allowed.txt" "token-L10"

# =============================================================================
# SECTION I — malformed on-disk state: empty token file, malformed/
# non-numeric ownerTtlSeconds
# =============================================================================
echo
echo "-- section I: malformed on-disk state degrades sanely, never crashes --"

REPO11="$TMP/repo11"
mk_repo "$REPO11"
WT11_EMPTY="$TMP/repo11-wt-empty"
mk_worktree "$REPO11" "task/11-empty" "$WT11_EMPTY"
key11_empty="$(enc "$(container_dir_of "$REPO11")")--$(enc "$WT11_EMPTY")"
mkdir -p "$CFG/state/worktree-owner/$key11_empty"
: > "$CFG/state/worktree-owner/$key11_empty/token" # claim dir + token file exist, but empty (corruption, not a race)

assert_allow "empty (corrupt) token file is treated as unowned, never a foreign owner" \
  "Write" "$WT11_EMPTY/new.txt" "token-anyone"

REPO12="$TMP/repo12"
mk_repo "$REPO12"
WT12_CALLER="$TMP/repo12-wt-caller"
WT12_BADJSON="$TMP/repo12-wt-badjson"
mk_worktree "$REPO12" "task/12-caller" "$WT12_CALLER"
mk_worktree "$REPO12" "task/12-badjson" "$WT12_BADJSON"
printf '{ this is not valid json' > "$WT12_BADJSON/.atelier.json"

assert_allow "token L12 claims WT12_CALLER" "Write" "$WT12_CALLER/new.txt" "token-L12"
assert_allow "token F12 claims WT12_BADJSON (malformed .atelier.json)" "Write" "$WT12_BADJSON/new.txt" "token-F12"
key12="$(enc "$(container_dir_of "$REPO12")")--$(enc "$WT12_BADJSON")"
# Fresh (age ~0s): malformed JSON must fall back to the DEFAULT ttl
# (43200s), not crash and not silently treat the claim as stale.
assert_block "malformed .atelier.json falls back to default ttl (claim stays fresh, still denied)" \
  "Write" "$WT12_BADJSON/blocked.txt" "token-L12"
# Far in the past: same malformed config, but old enough to be stale even
# under the (fallback) default ttl — proves the fallback default is a
# real number, not something that make the claim eternally fresh either.
touch -t 202001010000 "$CFG/state/worktree-owner/$key12/token" 2>/dev/null
assert_allow "malformed .atelier.json + very old claim still reclaims via the default ttl fallback" \
  "Write" "$WT12_BADJSON/reclaimed.txt" "token-L12"

REPO13="$TMP/repo13"
mk_repo "$REPO13"
WT13_CALLER="$TMP/repo13-wt-caller"
WT13_BADTTL="$TMP/repo13-wt-badttl"
mk_worktree "$REPO13" "task/13-caller" "$WT13_CALLER"
mk_worktree "$REPO13" "task/13-badttl" "$WT13_BADTTL"
printf '{"ownerTtlSeconds": "soon"}\n' > "$WT13_BADTTL/.atelier.json" # non-numeric

assert_allow "token L13 claims WT13_CALLER" "Write" "$WT13_CALLER/new.txt" "token-L13"
assert_allow "token F13 claims WT13_BADTTL (non-numeric ownerTtlSeconds)" "Write" "$WT13_BADTTL/new.txt" "token-F13"
assert_block "non-numeric ownerTtlSeconds falls back to default ttl (claim stays fresh, denied)" \
  "Write" "$WT13_BADTTL/blocked.txt" "token-L13"

# =============================================================================
# SECTION J — canonicalisation walks up to the nearest EXISTING ancestor
# for not-yet-existing, multi-level-deep Write targets
# =============================================================================
echo
echo "-- section J: deeply-nested not-yet-existing target paths resolve to the right worktree --"

REPO14="$TMP/repo14"
mk_repo "$REPO14"
WT14="$TMP/repo14-wt"
mk_worktree "$REPO14" "task/14" "$WT14"

assert_allow "self-claim via a 3-levels-deep not-yet-existing path" \
  "Write" "$WT14/brand/new/nested/file.txt" "token-N14"
key14="$(enc "$(container_dir_of "$REPO14")")--$(enc "$WT14")"
if [ -d "$CFG/state/worktree-owner/$key14" ]; then
  pass "deep not-yet-existing target resolved to WT14 itself, not some other ancestor"
else
  fail "deep not-yet-existing target did not resolve to the expected worktree key"
fi
# A second, different worktree in the same container, freshly owned by a
# different token — a deep not-yet-existing target under it must still be
# correctly recognised as a DIFFERENT worktree and get the categorical deny.
WT14B="$TMP/repo14-wt-b"
mk_worktree "$REPO14" "task/14b" "$WT14B"
assert_allow "token M14 claims WT14B" "Write" "$WT14B/new.txt" "token-M14"
assert_block "token N14 (owns WT14) writes a deep not-yet-existing path under WT14B (M14's) → denied" \
  "Write" "$WT14B/brand/new/nested/blocked.txt" "token-N14"

# =============================================================================
# SECTION K — paths containing spaces
# =============================================================================
echo
echo "-- section K: worktree paths and filenames containing spaces --"

REPO15="$TMP/repo one five"
mk_repo "$REPO15"
WT15_A="$TMP/repo one five-wt a"
WT15_B="$TMP/repo one five-wt b"
mk_worktree "$REPO15" "task/15-a" "$WT15_A"
mk_worktree "$REPO15" "task/15-b" "$WT15_B"

assert_allow "self-claim into a worktree path with a space, filename with a space" \
  "Write" "$WT15_A/new file.txt" "token-SP1"
assert_allow "token SP2 claims the sibling space-y worktree" \
  "Write" "$WT15_B/new file.txt" "token-SP2"
assert_block "cross-worktree deny still fires correctly across space-containing paths" \
  "Write" "$WT15_B/blocked file.txt" "token-SP1"

# =============================================================================
# SECTION L — concurrency: N parallel first-writers racing one unclaimed
# worktree. Design guarantees every branch here exits 0 regardless of
# interleaving (see the hook's in-flight-race comment) — this asserts that
# in practice, across real parallel processes, exactly one owner ends up
# recorded and no empty/partial claim state is left behind.
# =============================================================================
echo
echo "-- section L: concurrent claims on one unclaimed worktree --"

REPO16="$TMP/repo16"
mk_repo "$REPO16"
WT16="$TMP/repo16-wt"
mk_worktree "$REPO16" "task/16" "$WT16"

RACE_N=6
i=1
while [ "$i" -le "$RACE_N" ]; do
  (
    payload="$(jq -cn --arg f "$WT16/racer-$i.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
    CLAUDE_CODE_BRIDGE_SESSION_ID="token-racer-$i" \
      "$BASH_BIN" "$HOOK" <<<"$payload" >/dev/null 2>"$TMP/race-stderr-$i"
    echo $? > "$TMP/race-rc-$i"
  ) &
  i=$((i + 1))
done
wait

race_all_ok=1
i=1
while [ "$i" -le "$RACE_N" ]; do
  rc="$(cat "$TMP/race-rc-$i" 2>/dev/null || echo missing)"
  if [ "$rc" != "0" ]; then
    race_all_ok=0
    fail "racer $i expected exit 0, got $rc (stderr: $(cat "$TMP/race-stderr-$i" 2>/dev/null))"
  fi
  i=$((i + 1))
done
[ "$race_all_ok" -eq 1 ] && pass "all $RACE_N concurrent racers were allowed (exit 0)"

key16="$(enc "$(container_dir_of "$REPO16")")--$(enc "$WT16")"
claimdir16="$CFG/state/worktree-owner/$key16"
if [ -d "$claimdir16" ] && [ -f "$claimdir16/token" ] && [ -s "$claimdir16/token" ]; then
  pass "exactly one claim dir exists for WT16 with a non-empty token file (no empty-owner state left behind)"
else
  fail "WT16 claim state is missing or empty after the race ($claimdir16)"
fi
winner16="$(cat "$claimdir16/token" 2>/dev/null || true)"
case "$winner16" in
  token-racer-*)
    pass "the recorded owner (\"$winner16\") is one of the $RACE_N racers, not a stray value"
    ;;
  *)
    fail "recorded owner \"$winner16\" does not match any racer token"
    ;;
esac
# Only ONE claim directory should exist for this worktree/container pair —
# confirm there's no sibling directory for the same key (would indicate a
# non-atomic claim).
n_claimdirs16="$(find "$CFG/state/worktree-owner" -maxdepth 1 -type d -name "$key16*" 2>/dev/null | wc -l | tr -d ' ')"
[ "$n_claimdirs16" = "1" ] && pass "exactly one claim directory exists for WT16's key (atomic mkdir held)" \
                            || fail "expected exactly 1 claim directory for WT16's key, found $n_claimdirs16"

# =============================================================================
# SECTION M — session-token resolution order and the "no stable token"
# path writing NO state at all
# =============================================================================
echo
echo "-- section M: token source order (bridge env > payload.session_id > transcript_path dir > none) --"

REPO17="$TMP/repo17"
mk_repo "$REPO17"
WT17A="$TMP/repo17-wt-a"
WT17B="$TMP/repo17-wt-b"
WT17C="$TMP/repo17-wt-c"
mk_worktree "$REPO17" "task/17-a" "$WT17A"
mk_worktree "$REPO17" "task/17-b" "$WT17B"
mk_worktree "$REPO17" "task/17-c" "$WT17C"

# M1: no CLAUDE_CODE_BRIDGE_SESSION_ID, payload carries session_id → used.
payload_m1="$(jq -cn --arg f "$WT17A/new.txt" --arg sid "sess-fallback-payload" \
  '{tool_name:"Write", tool_input:{file_path:$f}, session_id:$sid}')"
code_m1="$(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
    "$BASH_BIN" "$HOOK" <<<"$payload_m1" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_m1" = "0" ] && pass "no bridge env, payload.session_id used as fallback token → allowed" \
                      || fail "expected exit 0, got $code_m1"
key17a="$(enc "$(container_dir_of "$REPO17")")--$(enc "$WT17A")"
owner_m1="$(cat "$CFG/state/worktree-owner/$key17a/token" 2>/dev/null || true)"
[ "$owner_m1" = "sess-fallback-payload" ] && pass "claim recorded under payload.session_id (\"sess-fallback-payload\")" \
                                            || fail "expected owner sess-fallback-payload, got \"$owner_m1\""

# M2: no bridge env, no session_id → falls back to dirname(transcript_path).
TRANSCRIPT_DIR="$TMP/faux-transcripts/abc123"
mkdir -p "$TRANSCRIPT_DIR"
payload_m2="$(jq -cn --arg f "$WT17B/new.txt" --arg tp "$TRANSCRIPT_DIR/session.jsonl" \
  '{tool_name:"Write", tool_input:{file_path:$f}, transcript_path:$tp}')"
code_m2="$(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
    "$BASH_BIN" "$HOOK" <<<"$payload_m2" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_m2" = "0" ] && pass "no bridge env, no session_id, transcript_path dir used as fallback token → allowed" \
                      || fail "expected exit 0, got $code_m2"
key17b="$(enc "$(container_dir_of "$REPO17")")--$(enc "$WT17B")"
owner_m2="$(cat "$CFG/state/worktree-owner/$key17b/token" 2>/dev/null || true)"
[ "$owner_m2" = "$TRANSCRIPT_DIR" ] && pass "claim recorded under dirname(transcript_path) (\"$TRANSCRIPT_DIR\")" \
                                      || fail "expected owner \"$TRANSCRIPT_DIR\", got \"$owner_m2\""

# M3: none of bridge env / session_id / transcript_path present → always
# allow, and — since there is no stable identity to claim with — NO state
# is written for this worktree at all.
payload_m3="$(jq -cn --arg f "$WT17C/new.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
code_m3="$(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" ATELIER_CONFIG_DIR="$CFG" \
    "$BASH_BIN" "$HOOK" <<<"$payload_m3" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_m3" = "0" ] && pass "no stable token available anywhere → allowed" \
                      || fail "expected exit 0, got $code_m3"
key17c="$(enc "$(container_dir_of "$REPO17")")--$(enc "$WT17C")"
if [ -d "$CFG/state/worktree-owner/$key17c" ]; then
  fail "no-stable-token path must not write any claim state, but $key17c exists"
else
  pass "no-stable-token path wrote no claim state at all for WT17C"
fi

# =============================================================================
# SECTION N — $ATELIER_CONFIG_DIR unset: default path resolves and works
# normally; when that DEFAULT path is itself unwritable, degrades to allow
# =============================================================================
echo
echo "-- section N: unset \$ATELIER_CONFIG_DIR (default \$HOME/.claude-work) --"

REPO18="$TMP/repo18"
mk_repo "$REPO18"
WT18A="$TMP/repo18-wt-a"
mk_worktree "$REPO18" "task/18-a" "$WT18A"

FAKE_HOME_OK="$TMP/fake-home-ok"
mkdir -p "$FAKE_HOME_OK"
payload_n1="$(jq -cn --arg f "$WT18A/new.txt" --arg sid "sess-n1" '{tool_name:"Write", tool_input:{file_path:$f}, session_id:$sid}')"
code_n1="$(
  unset ATELIER_CONFIG_DIR
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" HOME="$FAKE_HOME_OK" \
    "$BASH_BIN" "$HOOK" <<<"$payload_n1" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_n1" = "0" ] && pass "unset \$ATELIER_CONFIG_DIR + writable \$HOME → claims normally under \$HOME/.claude-work" \
                      || fail "expected exit 0, got $code_n1"
if [ ! -s "$TMP/last_stderr" ]; then
  pass "unset \$ATELIER_CONFIG_DIR with a writable default is NOT a degraded path (no warning printed)"
else
  fail "unexpected stderr for the normal default-path case: $(cat "$TMP/last_stderr")"
fi
[ -d "$FAKE_HOME_OK/.claude-work/state/worktree-owner" ] && pass "claim state written under the default \$HOME/.claude-work" \
                                                           || fail "expected claim state under \$FAKE_HOME_OK/.claude-work"

WT18B="$TMP/repo18-wt-b"
mk_worktree "$REPO18" "task/18-b" "$WT18B"
FAKE_HOME_BAD="$TMP/fake-home-bad"
mkdir -p "$FAKE_HOME_BAD"
: > "$FAKE_HOME_BAD/.claude-work" # regular file where the default state dir needs to be a directory

payload_n2="$(jq -cn --arg f "$WT18B/new.txt" '{tool_name:"Write", tool_input:{file_path:$f}}')"
code_n2="$(
  unset ATELIER_CONFIG_DIR
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" HOME="$FAKE_HOME_BAD" \
    "$BASH_BIN" "$HOOK" <<<"$payload_n2" >/dev/null 2>"$TMP/last_stderr"
  echo $?
)"
[ "$code_n2" = "0" ] && pass "unset \$ATELIER_CONFIG_DIR + unwritable default \$HOME/.claude-work → degrades to allow" \
                      || fail "expected exit 0, got $code_n2"
assert_stderr_contains "unwritable default-path degrade warns on stderr" "unwritable"

# =============================================================================
# SECTION O — explicit unblocker Step 5 / task-orchestrator Step 8
# main-checkout scenarios, including the "owns MULTIPLE task worktrees at
# once" shape a babysit-prs fan-out pass produces
# =============================================================================
echo
echo "-- section O: unblocker Step 5 / task-orchestrator Step 8 main-checkout edits, multi-worktree owner --"

REPO19="$TMP/repo19"
mk_repo "$REPO19"
WT19_TASK1="$TMP/repo19-wt-task1"
WT19_TASK2="$TMP/repo19-wt-task2"
mk_worktree "$REPO19" "task/19-one" "$WT19_TASK1"
mk_worktree "$REPO19" "task/19-two" "$WT19_TASK2"

# A single babysit-prs pass owning TWO task worktrees at once (per the
# hook's own header comment: ownership is per-worktree, not per-session).
assert_allow "babysit token owns task worktree 1" "Write" "$WT19_TASK1/f.txt" "token-BABYSIT"
assert_allow "babysit token owns task worktree 2" "Write" "$WT19_TASK2/f.txt" "token-BABYSIT"

# unblocker Step 5: edit IN_PROGRESS.md on the MAIN worktree (REPO19
# itself) to add the [BLOCKED] marker, while the same session still owns
# both task worktrees above.
assert_allow "unblocker Step 5 — IN_PROGRESS.md edit on the main checkout, while owning 2 task worktrees" \
  "Edit" "$REPO19/IN_PROGRESS.md" "token-BABYSIT"

# task-orchestrator Step 8: the [OVERSIZE] marker edit also lands directly
# on the main checkout's ROADMAP.md — same shape, different file.
assert_allow "task-orchestrator Step 8 — ROADMAP.md [OVERSIZE] marker edit on the main checkout" \
  "Edit" "$REPO19/ROADMAP.md" "token-BABYSIT"

echo
if [ "$fails" -eq 0 ]; then
  echo "All #196a block-cross-worktree-edit regression checks passed."
  exit 0
else
  echo "$fails #196a block-cross-worktree-edit regression check(s) FAILED."
  exit 1
fi
